-- Read-only iCalendar feed provider.
--
-- Speaks the same contract the orchestrator and `mapper.lua` consume
-- (see `providers/init.lua`), but the wire format is a single flat `.ics`
-- document fetched over HTTPS rather than CalDAV. The whole feed is pulled
-- every sync; there is no server-side change detection and no per-object
-- ETag, so this provider synthesises one:
--
--   * events are grouped by UID (master + RECURRENCE-ID overrides together,
--     the way a CalDAV resource bundles a series) and each group is handed to
--     the orchestrator as one entry, keyed by UID;
--   * `etag` is a content hash over the group's raw VEVENT text, DTSTART and
--     DTEND included. When an event moves upstream its hash changes, which is
--     exactly what `apply_remote` compares (`mapping.etag ~= response.etag`),
--     so a time change is pulled through as an update.
--
-- The feed is read-only. There is nowhere to PUT changes back, so the write
-- half of the contract is stubbed; the orchestrator never reaches it for a
-- calendar it has marked `ro`.

local http = require("bloocky.sync.http")
local async = require("bloocky.sync.async")

local M = {}

local function get(url)
	return async.await(function(cb)
		http.request({
			url = url,
			method = "GET",
			headers = { ["User-Agent"] = "bloocky.nvim", Accept = "text/calendar" },
			follow = true,
		}, cb)
	end)
end

-- Split into physical lines, then unfold: a line beginning with a space or
-- tab is a continuation of the previous one (RFC 5545 3.1). Unfolding is only
-- used to read UIDs; the raw physical lines are what gets re-serialised, so
-- folding in the payload is preserved untouched.
local function physical_lines(text)
	local out = {}
	for line in (text .. "\n"):gmatch("(.-)\n") do
		out[#out + 1] = (line:gsub("\r$", ""))
	end
	return out
end

local function uid_of(event_lines)
	local unfolded = {}
	for _, line in ipairs(event_lines) do
		if line:match("^[ \t]") and #unfolded > 0 then
			unfolded[#unfolded] = unfolded[#unfolded] .. line:gsub("^[ \t]", "")
		else
			unfolded[#unfolded + 1] = line
		end
	end
	for _, line in ipairs(unfolded) do
		local uid = line:match("^[Uu][Ii][Dd][:;].-:(.*)$") or line:match("^[Uu][Ii][Dd]:(.*)$")
		if uid then
			return (uid:gsub("%s+$", ""))
		end
	end
	return nil
end

-- Carve the feed into VTIMEZONE blocks (kept once, prepended to every event so
-- TZID references resolve) and VEVENT blocks grouped by UID.
local function carve(text)
	local lines = physical_lines(text)
	local timezones, groups, order = {}, {}, {}
	local i, n = 1, #lines

	while i <= n do
		local upper = lines[i]:upper()
		if upper:match("^BEGIN:VTIMEZONE%s*$") then
			local block = {}
			while i <= n and not lines[i]:upper():match("^END:VTIMEZONE%s*$") do
				block[#block + 1] = lines[i]
				i = i + 1
			end
			if i <= n then
				block[#block + 1] = lines[i]
			end
			for _, l in ipairs(block) do
				timezones[#timezones + 1] = l
			end
			i = i + 1
		elseif upper:match("^BEGIN:VEVENT%s*$") then
			local block = {}
			while i <= n and not lines[i]:upper():match("^END:VEVENT%s*$") do
				block[#block + 1] = lines[i]
				i = i + 1
			end
			if i <= n then
				block[#block + 1] = lines[i]
			end
			local uid = uid_of(block)
			if uid then
				if not groups[uid] then
					groups[uid] = {}
					order[#order + 1] = uid
				end
				for _, l in ipairs(block) do
					groups[uid][#groups[uid] + 1] = l
				end
			end
			i = i + 1
		else
			i = i + 1
		end
	end

	return timezones, groups, order
end

local function envelope(timezones, event_lines)
	local out = { "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//bloocky.nvim//ics//EN" }
	for _, l in ipairs(timezones) do
		out[#out + 1] = l
	end
	for _, l in ipairs(event_lines) do
		out[#out + 1] = l
	end
	out[#out + 1] = "END:VCALENDAR"
	return table.concat(out, "\r\n")
end

-- One synthetic, read-only calendar per account: the feed itself. The href is
-- a stable non-secret id (the URL carries a private token and must not be
-- written into the on-disk sync store).
function M.discover(account)
	if type(account.url) ~= "string" or account.url == "" then
		return nil, "ics accounts need a `url`"
	end
	return { { href = "ics/" .. tostring(account.id), name = account.label or account.id or "Calendar", readonly = true } }, nil
end

function M.fetch(account, calendar, cursor, _window)
	local err, res = get(account.url)
	if err then
		return nil, err
	end
	if res.status >= 400 then
		return nil, ("fetch failed (HTTP %d)"):format(res.status)
	end

	local timezones, groups, order = carve(res.body or "")

	local changed, present = {}, {}
	for _, uid in ipairs(order) do
		local data = envelope(timezones, groups[uid])
		changed[#changed + 1] = {
			href = uid,
			etag = vim.fn.sha256(data),
			data = data,
		}
		present[uid] = true
	end

	-- Anything the previous sync saw but this one did not was removed upstream.
	local removed = {}
	if cursor then
		local ok, previous = pcall(vim.json.decode, cursor)
		if ok and type(previous) == "table" then
			for _, uid in ipairs(previous) do
				if not present[uid] then
					removed[#removed + 1] = uid
				end
			end
		end
	end

	return { changed = changed, removed = removed, cursor = vim.json.encode(order) }, nil
end

-- Read-only: the orchestrator only reaches these for a `rw` calendar, which a
-- feed never is. They exist so the provider satisfies the full contract.
local function readonly()
	return nil, "ics feeds are read-only"
end

M.create_event = readonly
M.update_event = readonly
M.delete_event = function()
	return { missing = true }, nil
end

return M
