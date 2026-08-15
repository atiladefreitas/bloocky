-- The sync orchestrator.
--
-- The ordering rule this whole design rests on: **push before pull**. Remote
-- wins on a genuine conflict, but a local edit that has not reached the server
-- yet is not a conflict — it is just unsent. Pulling first would revert it and
-- make "your blocks are editable" a lie. So every local change goes up first,
-- and only a 412 from the server (someone else changed the same event) counts
-- as a conflict.

local account_config = require("bloocky.sync.account")
local async = require("bloocky.sync.async")
local providers = require("bloocky.sync.providers")
local config = require("bloocky.config")
local hash = require("bloocky.sync.hash")
local mapper = require("bloocky.sync.mapper")
local state = require("bloocky.state")
local store = require("bloocky.sync.store")
local utils = require("bloocky.utils")

local M = {}

local running = {}
-- What each account last complained about, so an automatic sync does not
-- repeat the same failure every interval while you are offline.
local last_errors = {}
-- Config warnings already shown this session.
local warned = {}

--------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------

local function new_report(account_id)
	return {
		account = account_id,
		pushed = { created = 0, updated = 0, deleted = 0 },
		pulled = { created = 0, updated = 0, deleted = 0 },
		conflicts = {},
		-- Blocks the push phase already found in conflict. The pull is about
		-- to see the same clash from the other side; without this it would be
		-- reported and trailed twice for one event.
		conflicted = {},
		-- Timing edits handed back because the event's recurrence is not ours
		-- to rewrite.
		reverted = {},
		skipped = {},
		errors = {},
	}
end

local function bump(counter, key)
	counter[key] = (counter[key] or 0) + 1
end

-- The window we ask the server for, as iCalendar UTC stamps.
local function sync_window()
	local sync = config.options.sync or {}
	local window = sync.window or {}
	local past = (window.past_days or 30) * 86400
	local future = (window.future_days or 180) * 86400
	local function stamp(offset)
		return os.date("!%Y%m%dT%H%M%SZ", os.time() + offset)
	end
	return { start = stamp(-past), ["end"] = stamp(future) }
end

-- Pair configured calendars with what the server actually has. A calendar the
-- user named but the server does not have is reported, not silently dropped.
local function resolve_calendars(account, discovered, report)
	local configured = account.calendars
	if not configured or #configured == 0 then
		local out = {}
		for i, calendar in ipairs(discovered) do
			table.insert(out, {
				href = calendar.href,
				name = calendar.name,
				mode = calendar.readonly and "ro" or "rw",
				default = i == 1,
			})
		end
		return out
	end

	local out = {}
	for _, wanted in ipairs(configured) do
		local match = nil
		for _, calendar in ipairs(discovered) do
			if
				(wanted.href and calendar.href == wanted.href)
				or (wanted.name and calendar.name:lower() == wanted.name:lower())
			then
				match = calendar
				break
			end
		end
		if match then
			-- The server's own view of permissions overrides the config: a
			-- calendar marked rw that we cannot actually write to is ro.
			local mode = wanted.mode or "rw"
			if match.readonly then
				mode = "ro"
			end
			table.insert(out, {
				href = match.href,
				name = match.name,
				mode = mode,
				default = wanted.default,
			})
		else
			table.insert(report.errors, ("calendar %q not found on the server"):format(wanted.name or wanted.href))
		end
	end
	return out
end

--------------------------------------------------------------------------
-- Push
--------------------------------------------------------------------------

local function push_deletions(account, calendars, report)
	local provider = providers.for_account(account)
	for _, tombstone in ipairs(vim.deepcopy(store.tombstones(account.id))) do
		local result, err = provider.delete_event(account, tombstone)

		if err then
			table.insert(report.errors, ("could not delete %q: %s"):format(tombstone.title or "?", err))
		elseif result.conflict then
			-- Changed remotely after we deleted it here. Remote wins, so the
			-- deletion is abandoned and the pull will bring the event back.
			table.insert(report.conflicts, {
				kind = "delete-vs-edit",
				title = tombstone.title,
				resolution = "kept the remote event; your deletion was undone",
			})
			store.record_conflict({
				block_id = tombstone.id,
				kind = "delete-vs-edit",
				title = tombstone.title,
				account = account.id,
			})
			store.clear_tombstone(tombstone.id)
		else
			store.clear_tombstone(tombstone.id)
			bump(report.pushed, "deleted")
		end
	end
end

-- Put the server's version of some fields back onto a block whose edit we
-- refused to send, and say so. Without this the block goes on showing a time
-- or title the calendar has never had, and an incremental pull will never
-- correct it because nothing changed upstream.
local TIMING_FIELDS = { "date", "start_min", "duration_min", "recurrence" }
local ALL_FIELDS = { "title", "date", "start_min", "duration_min", "notes", "recurrence" }

local function revert_from(block, payload, fields, report)
	local event = mapper.from_ical(payload)
	if not (event and event.block) then
		return false
	end
	for _, field in ipairs(fields) do
		block[field] = event.block[field]
	end
	table.insert(report.reverted, block.title)
	return true
end

local function push_updates(account, report)
	local provider = providers.for_account(account)
	local changes = store.local_changes(state.blocks)

	-- Edits to blocks on a read-only calendar: nothing to send, so hand them
	-- straight back.
	for _, block in ipairs(changes.blocked) do
		local mapping = store.get_mapping(block.id)
		if mapping and mapping.account == account.id and mapping.raw then
			if revert_from(block, mapping.raw, ALL_FIELDS, report) then
				store.mark_synced(block, {})
			end
		end
	end

	for _, block in ipairs(changes.updated) do
		local mapping = store.get_mapping(block.id)
		if mapping and mapping.account == account.id then
			do
				local result, err = provider.update_event(account, mapping, block)

				if err then
					table.insert(report.errors, ("could not update %q: %s"):format(block.title, err))
				elseif result.conflict then
					-- Someone edited it upstream. Keep our version in the
					-- trail; the pull overwrites the block with theirs.
					table.insert(report.conflicts, {
						kind = "edit-vs-edit",
						title = block.title,
						resolution = "the remote version was kept",
					})
					store.record_conflict({
						block_id = block.id,
						kind = "edit-vs-edit",
						title = block.title,
						account = account.id,
						local_version = vim.deepcopy(block),
					})
					report.conflicted[block.id] = true
				else
					-- We refused to send the timing of an event whose
					-- recurrence we cannot model, so the block must stop
					-- showing a time the calendar does not have. Put the
					-- server's own timing back and say so.
					if mapping.lossy then
						revert_from(block, result.raw, TIMING_FIELDS, report)
					end
					store.mark_synced(block, { etag = result.etag, raw = result.raw })
					bump(report.pushed, "updated")
				end
			end
		end
	end

	state.save_blocks()
	return changes
end

local function push_creations(account, calendars, changes, report)
	local provider = providers.for_account(account)
	local target = nil
	for _, calendar in ipairs(calendars) do
		if calendar.mode == "rw" and (calendar.default or not target) then
			target = calendar
			if calendar.default then
				break
			end
		end
	end
	if not target then
		return
	end

	for _, block in ipairs(changes.created) do
		-- Only blocks belonging to this account. A block already owned by
		-- another account must not be duplicated into this one.
		local source = block.source or "local"
		if source == account.id or (source == "local" and account.is_default) then
			do
				local result, err = provider.create_event(account, target, block)

				if err then
					table.insert(report.errors, ("could not create %q: %s"):format(block.title, err))
				elseif result.conflict then
					table.insert(report.errors, ("%q already exists on the server"):format(block.title))
				else
					block.source = account.id
					store.mark_synced(block, {
						account = account.id,
						calendar = target.href,
						uid = result.uid,
						href = result.href,
						etag = result.etag,
						raw = result.raw,
					})
					bump(report.pushed, "created")
				end
			end
		end
	end
	state.save_blocks()
end

--------------------------------------------------------------------------
-- Pull
--------------------------------------------------------------------------

local function find_block(block_id)
	for _, block in ipairs(state.blocks) do
		if block.id == block_id then
			return block
		end
	end
end

local function apply_remote(account, calendar, response, report)
	local event, parse_err = mapper.from_ical(response.data)
	if not event then
		table.insert(report.errors, ("could not read %s: %s"):format(response.href, parse_err))
		return
	end

	local by_uid = store.index_by("uid")
	local block_id = by_uid[event.uid]
	local existing = block_id and find_block(block_id)

	if event.skip then
		report.skipped[event.skip] = (report.skipped[event.skip] or 0) + 1
		return
	end

	-- A cancelled event is a deletion wearing a different hat.
	if event.cancelled then
		if existing then
			store.remove_mapping(existing.id)
			state.delete_block(existing.id)
			bump(report.pulled, "deleted")
		end
		return
	end

	if existing then
		local mapping = store.get_mapping(existing.id) or {}
		local local_changed = mapping.base_hash ~= hash.block(existing)
		local remote_changed = mapping.etag ~= response.etag

		-- Already counted if the push hit a 412 on this same block.
		if local_changed and remote_changed and not report.conflicted[existing.id] then
			table.insert(report.conflicts, {
				kind = "overwritten",
				title = existing.title,
				resolution = "the remote version was kept",
			})
			store.record_conflict({
				block_id = existing.id,
				kind = "overwritten",
				title = existing.title,
				account = account.id,
				local_version = vim.deepcopy(existing),
			})
			report.conflicted[existing.id] = true
		end

		if local_changed or remote_changed then
			for key, value in pairs(event.block) do
				existing[key] = value
			end
			existing.updated_at = os.time()
			bump(report.pulled, "updated")
		end

		store.mark_synced(existing, {
			account = account.id,
			calendar = calendar.href,
			uid = event.uid,
			href = response.href,
			etag = response.etag,
			raw = response.data,
			tz = event.tzid,
			lossy = event.lossy ~= nil,
			readonly = calendar.mode == "ro",
		})
		if event.lossy then
			report.skipped.lossy = (report.skipped.lossy or 0) + 1
		end
		return
	end

	local block = state.add_block(vim.tbl_extend("force", event.block, { source = account.id }))
	store.mark_synced(block, {
		account = account.id,
		calendar = calendar.href,
		uid = event.uid,
		href = response.href,
		etag = response.etag,
		raw = response.data,
		tz = event.tzid,
		lossy = event.lossy ~= nil,
		readonly = calendar.mode == "ro",
	})
	bump(report.pulled, "created")
	if event.lossy then
		report.skipped.lossy = (report.skipped.lossy or 0) + 1
	end
end

local function pull_calendar(account, calendar, report)
	local provider = providers.for_account(account)
	local cursor = store.calendar_cursor(account.id, calendar.href)
	local result, err = provider.fetch(account, calendar, cursor, sync_window())

	if err then
		table.insert(report.errors, ("%s: %s"):format(calendar.name, err))
		return
	end

	for _, response in ipairs(result.changed) do
		if response.data then
			apply_remote(account, calendar, response, report)
		end
	end

	local by_href = store.index_by("href")
	for _, href in ipairs(result.removed) do
		local block_id = by_href[href]
		local block = block_id and find_block(block_id)
		if block then
			-- Drop the mapping first: state.delete_block writes a tombstone
			-- when a mapping exists, and we must not ask the server to delete
			-- something it has already deleted.
			store.remove_mapping(block.id)
			state.delete_block(block.id)
			bump(report.pulled, "deleted")
		end
	end

	-- Opaque to us: a CalDAV sync-token, or Google's syncToken paired with the
	-- timeMin it was issued for.
	if result.cursor then
		store.set_calendar_cursor(account.id, calendar.href, result.cursor)
	end
	state.save_blocks()
end

--------------------------------------------------------------------------
-- Reporting
--------------------------------------------------------------------------

local function total(counter)
	return (counter.created or 0) + (counter.updated or 0) + (counter.deleted or 0)
end

local function describe(counter)
	local parts = {}
    for _, key in ipairs({ "created", "updated", "deleted" }) do
		if (counter[key] or 0) > 0 then
			table.insert(parts, counter[key] .. " " .. key)
		end
	end
	return #parts > 0 and table.concat(parts, ", ") or "nothing"
end

-- `quiet` is for syncs the user did not ask for by hand (on open, after an
-- edit): stay silent when there is genuinely nothing to say, but never
-- suppress an error or a conflict.
function M.notify_report(report, opts)
	opts = opts or {}
	local uneventful = total(report.pushed) == 0
		and total(report.pulled) == 0
		and #report.errors == 0
		and #report.conflicts == 0
		and #report.reverted == 0
	if opts.quiet and uneventful then
		return
	end

	-- An unreachable server is one piece of news, not one every interval. Say
	-- it once, then stay quiet until it changes or clears. Anything else worth
	-- reporting (a conflict, an actual change) still gets through.
	local signature = table.concat(report.errors, "|")
	local nothing_but_the_same_errors = opts.quiet
		and #report.errors > 0
		and #report.conflicts == 0
		and #report.reverted == 0
		and total(report.pushed) == 0
		and total(report.pulled) == 0
	if nothing_but_the_same_errors and last_errors[report.account] == signature then
		return
	end
	last_errors[report.account] = #report.errors > 0 and signature or nil

	local lines = {}
	if total(report.pushed) > 0 then
		table.insert(lines, "sent: " .. describe(report.pushed))
	end
	if total(report.pulled) > 0 then
		table.insert(lines, "received: " .. describe(report.pulled))
	end
	-- Only claim to be up to date when nothing went wrong. Reporting "already
	-- up to date" next to an error reads as if the error were harmless.
	if #lines == 0 and #report.errors == 0 then
		table.insert(lines, "already up to date")
	end

	local skipped = {}
	for reason, count in pairs(report.skipped) do
		table.insert(skipped, count .. " " .. reason)
	end
	if #skipped > 0 then
		table.insert(lines, "skipped: " .. table.concat(skipped, ", "))
	end

	if #report.reverted > 0 then
		table.insert(
			lines,
			("%d timing edit%s undone (that event's repeat rule is not bloocky's to change)"):format(
				#report.reverted,
				#report.reverted == 1 and "" or "s"
			)
		)
	end

	local level = vim.log.levels.INFO
	if #report.errors > 0 then
		level = vim.log.levels.ERROR
		for _, err in ipairs(report.errors) do
			table.insert(lines, "error: " .. err)
		end
	end

	-- Conflicts are never folded into a quiet summary line.
	if #report.conflicts > 0 then
		level = vim.log.levels.WARN
		table.insert(
			lines,
			("%d conflict%s resolved in favour of the remote calendar - run :BloockySyncReport"):format(
				#report.conflicts,
				#report.conflicts == 1 and "" or "s"
			)
		)
	end

	vim.notify(("Bloocky sync (%s): "):format(report.account) .. table.concat(lines, "; "), level)
end

--------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------

function M.sync_account(account, done)
	local report = new_report(account.id)

	async.run(function()
		local provider = providers.for_account(account)
		local discovered, err = provider.discover(account)
		if not discovered then
			table.insert(report.errors, err or "discovery failed")
			return
		end

		local calendars = resolve_calendars(account, discovered, report)
		if #calendars == 0 then
			table.insert(report.errors, "no usable calendars")
			return
		end

		-- Push first. See the note at the top of this file.
		push_deletions(account, calendars, report)
		local changes = push_updates(account, report)
		push_creations(account, calendars, changes, report)

		for _, calendar in ipairs(calendars) do
			pull_calendar(account, calendar, report)
		end
	end, function(err)
		if err then
			table.insert(report.errors, tostring(err))
		end
		done(report)
	end)
end

-- Sync one account, or every configured account.
function M.run(account_id, done, opts)
	done = done or function() end
	opts = opts or {}

	local sync = config.options.sync or {}
	if not sync.enabled then
		if not opts.quiet then
			vim.notify("Bloocky: sync is not enabled (set sync.enabled = true)", vim.log.levels.WARN)
		end
		return done(nil)
	end

	local accounts = {}
	if account_id then
		local account = account_config.get(account_id)
		if not account then
			vim.notify("Bloocky: no sync account called " .. account_id, vim.log.levels.ERROR)
			return done(nil)
		end
		accounts = { account }
	else
		accounts = account_config.accounts()
	end

	if #accounts == 0 then
		if not opts.quiet then
			vim.notify("Bloocky: no sync accounts configured", vim.log.levels.WARN)
		end
		return done(nil)
	end

	local all = account_config.accounts()
	local pending = #accounts
	for _, account in ipairs(accounts) do
		account.is_default = all[1] and all[1].id == account.id

		local problems = account_config.validate(account)
		local fatal = vim.tbl_filter(function(problem)
			return not problem:match("^WARN ")
		end, problems)
		for _, problem in ipairs(problems) do
			-- Config warnings describe something static. Repeating them on
			-- every sync would mean a popup every interval, forever, for a
			-- fact that has not changed — so say each one once a session.
			if problem:match("^WARN ") and not warned[problem] then
				warned[problem] = true
				vim.notify("Bloocky: " .. problem:sub(6), vim.log.levels.WARN)
			end
		end

		if #fatal > 0 then
			-- A misconfigured account fails identically every interval; on a
			-- background sync, say so once rather than on every tick.
			local signature = table.concat(fatal, "; ")
			if not (opts.quiet and last_errors[account.id] == signature) then
				vim.notify("Bloocky sync: " .. signature, vim.log.levels.ERROR)
				last_errors[account.id] = signature
			end
			pending = pending - 1
			if pending == 0 then
				done(nil)
			end
		elseif running[account.id] then
			if not opts.quiet then
				vim.notify("Bloocky: a sync is already running for " .. account.id, vim.log.levels.INFO)
			end
			pending = pending - 1
			if pending == 0 then
				done(nil)
			end
		else
			running[account.id] = true
			M.sync_account(account, function(report)
				running[account.id] = false
				M.notify_report(report, opts)
				pcall(function()
					require("bloocky.ui").render()
				end)
				pending = pending - 1
				if pending == 0 then
					done(report)
				end
			end)
		end
	end
end

--------------------------------------------------------------------------
-- Status and the conflict report
--------------------------------------------------------------------------

local function open_scratch(title, lines)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].filetype = "markdown"

	local width = math.min(90, math.floor(vim.o.columns * 0.8))
	local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.8))
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = config.options.window.border,
		title = " " .. title .. " ",
	})
	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(win, true)
	end, { buffer = buf, nowait = true })
end

function M.status()
	local lines = { "# Bloocky sync status", "" }
	local accounts = account_config.accounts()
	if #accounts == 0 then
		table.insert(lines, "No accounts configured.")
	end
	for _, account in ipairs(accounts) do
		local info = store.account(account.id)
		table.insert(lines, ("## %s (%s)"):format(account.id, account.provider))
		table.insert(
			lines,
			"- last sync: " .. (info.last_sync and os.date("%Y-%m-%d %H:%M", info.last_sync) or "never")
		)
		local pending = store.local_changes(state.blocks)
		table.insert(
			lines,
			("- pending: %d to create, %d to update, %d to delete"):format(
				#pending.created,
				#pending.updated,
				#store.tombstones(account.id)
			)
		)
		for _, problem in ipairs(account_config.validate(account)) do
			table.insert(lines, "- " .. problem)
		end
		local unseen = store.unacknowledged_count()
		if unseen > 0 then
			table.insert(lines, ("- %d unread conflict%s - :BloockySyncReport"):format(unseen, unseen == 1 and "" or "s"))
		end
		table.insert(lines, "")
	end
	open_scratch("Sync status", lines)
end

function M.report()
	local conflicts = store.conflicts()
	local unseen = store.unacknowledged_count()
	local lines = { "# Conflicts", "" }
	if #conflicts == 0 then
		table.insert(lines, "None. Every sync so far applied cleanly.")
	else
		table.insert(lines, ("The remote calendar won %d time%s%s."):format(
			#conflicts,
			#conflicts == 1 and "" or "s",
			unseen > 0 and (", %d of them new"):format(unseen) or ""
		))
		table.insert(lines, "Restore a local version with `:BloockySyncRestore <n>`.")
		table.insert(lines, "Affected blocks are flagged on the grid until you read this.")
		table.insert(lines, "")
	end
	for i, conflict in ipairs(conflicts) do
		table.insert(lines, ("## %d. %s"):format(i, conflict.title or conflict.block_id or "?"))
		table.insert(lines, "- when: " .. os.date("%Y-%m-%d %H:%M", conflict.at))
		table.insert(lines, "- kind: " .. (conflict.kind or "?"))
		local version = conflict.local_version
		if version then
			table.insert(
				lines,
				("- your version: %s, %s %s for %s"):format(
					version.title,
					version.date,
					utils.format_hhmm(version.start_min or 0),
					utils.format_duration(version.duration_min or 0)
				)
			)
		end
		table.insert(lines, "")
	end
	open_scratch("Sync conflicts", lines)

	-- Reading the report *is* the acknowledgement: the grid stops flagging
	-- these blocks now that you have actually seen them.
	if unseen > 0 and store.acknowledge_conflicts() then
		pcall(function()
			require("bloocky.ui").render()
		end)
	end
end

-- Bring a losing local version back as a new block, leaving the remote one
-- alone. This is what makes remote-wins recoverable rather than destructive.
function M.restore(index)
	local conflicts = store.conflicts()
	local conflict = conflicts[tonumber(index) or 0]
	if not conflict or not conflict.local_version then
		vim.notify("Bloocky: no restorable conflict at " .. tostring(index), vim.log.levels.ERROR)
		return
	end
	local version = conflict.local_version
	local block = state.add_block({
		title = version.title .. " (restored)",
		date = version.date,
		start_min = version.start_min,
		duration_min = version.duration_min,
		notes = version.notes,
		recurrence = version.recurrence,
	})
	vim.notify(("Bloocky: restored %q to %s"):format(block.title, block.date), vim.log.levels.INFO)
	pcall(function()
		require("bloocky.ui").render()
	end)
end

return M
