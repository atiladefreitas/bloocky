-- End-to-end sync against an in-memory CalDAV server.
--
-- The protocol pieces are unit-tested elsewhere; what needs proving here is
-- the *engine*: that pushing happens before pulling, that a 412 becomes a
-- recorded conflict rather than silent data loss, and that a deletion on
-- either side does not come back.

local caldav = require("bloocky.sync.providers.caldav")
local config = require("bloocky.config")
local state = require("bloocky.state")
local store = require("bloocky.sync.store")
local sync = require("bloocky.sync")

--------------------------------------------------------------------------
-- A fake server
--------------------------------------------------------------------------

local Server = {}
Server.__index = Server

local function new_server()
	return setmetatable({ resources = {}, deleted = {}, seq = 0, requests = {} }, Server)
end

function Server:put(href, data, etag)
	self.seq = self.seq + 1
	self.resources[href] = { data = data, etag = etag or ('"v%d"'):format(self.seq), seq = self.seq }
	self.deleted[href] = nil
	return self.resources[href]
end

function Server:remove(href)
	self.seq = self.seq + 1
	self.resources[href] = nil
	self.deleted[href] = self.seq
end

local function ms(inner)
	return '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" '
		.. 'xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/">'
		.. inner
		.. "</d:multistatus>"
end

local function escape(text)
	return (tostring(text):gsub("[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }))
end

local CALENDAR = "/dav/home/work/"

function Server:handle(opts)
	table.insert(self.requests, { method = opts.method or "GET", url = opts.url })
	local path = opts.url:match("^https?://[^/]+(.*)$") or opts.url
	local body = opts.body or ""
	local method = opts.method or "GET"

	local function ok(text, headers)
		return nil, { status = 207, headers = headers or {}, body = text }
	end

	if method == "PROPFIND" then
		if body:find("current-user-principal", 1, true) then
			return ok(ms("<d:response><d:href>/dav/</d:href><d:propstat><d:prop>"
				.. "<d:current-user-principal><d:href>/dav/principal/</d:href></d:current-user-principal>"
				.. "</d:prop></d:propstat></d:response>"))
		end
		if body:find("calendar-home-set", 1, true) then
			return ok(ms("<d:response><d:href>/dav/principal/</d:href><d:propstat><d:prop>"
				.. "<c:calendar-home-set><d:href>/dav/home/</d:href></c:calendar-home-set>"
				.. "</d:prop></d:propstat></d:response>"))
		end
		if body:find("sync%-token") then
			return ok(ms("<d:sync-token>" .. self.seq .. "</d:sync-token>"))
		end
		-- The calendar listing
		return ok(ms("<d:response><d:href>" .. CALENDAR .. "</d:href><d:propstat><d:prop>"
			.. "<d:resourcetype><d:collection/><c:calendar/></d:resourcetype>"
			.. "<d:displayname>Work</d:displayname>"
			.. '<c:supported-calendar-component-set><c:comp name="VEVENT"/></c:supported-calendar-component-set>'
			.. "<d:current-user-privilege-set><d:privilege><d:write-content/></d:privilege></d:current-user-privilege-set>"
			.. "</d:prop></d:propstat></d:response>"))
	end

	if method == "REPORT" then
		local parts = {}
		if body:find("sync%-collection") then
			local token = tonumber(body:match("<d:sync%-token>(%d*)</d:sync%-token>") or "") or 0
			for href, resource in pairs(self.resources) do
				if resource.seq > token then
					parts[#parts + 1] = ("<d:response><d:href>%s</d:href><d:propstat><d:prop>"):format(href)
						.. ("<d:getetag>%s</d:getetag>"):format(resource.etag)
						.. "</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
				end
			end
			for href, seq in pairs(self.deleted) do
				if seq > token then
					parts[#parts + 1] = ("<d:response><d:href>%s</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>"):format(
						href
					)
				end
			end
			return ok(ms(table.concat(parts) .. "<d:sync-token>" .. self.seq .. "</d:sync-token>"))
		end

		-- calendar-query and calendar-multiget both return data
		local wanted = nil
		if body:find("multiget") then
			wanted = {}
			for href in body:gmatch("<d:href>([^<]+)</d:href>") do
				wanted[href] = true
			end
		end
		for href, resource in pairs(self.resources) do
			if not wanted or wanted[href] then
				parts[#parts + 1] = ("<d:response><d:href>%s</d:href><d:propstat><d:prop>"):format(href)
					.. ("<d:getetag>%s</d:getetag>"):format(resource.etag)
					.. ("<c:calendar-data>%s</c:calendar-data>"):format(escape(resource.data))
					.. "</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
			end
		end
		return ok(ms(table.concat(parts)))
	end

	if method == "PUT" then
		local existing = self.resources[path]
		local if_match = opts.headers and opts.headers["If-Match"]
		local if_none = opts.headers and opts.headers["If-None-Match"]
		if if_match and (not existing or existing.etag ~= if_match) then
			return nil, { status = 412, headers = {}, body = "" }
		end
		if if_none == "*" and existing then
			return nil, { status = 412, headers = {}, body = "" }
		end
		local resource = self:put(path, body)
		return nil, { status = existing and 204 or 201, headers = { etag = resource.etag }, body = "" }
	end

	if method == "DELETE" then
		local existing = self.resources[path]
		if not existing then
			return nil, { status = 404, headers = {}, body = "" }
		end
		local if_match = opts.headers and opts.headers["If-Match"]
		if if_match and existing.etag ~= if_match then
			return nil, { status = 412, headers = {}, body = "" }
		end
		self:remove(path)
		return nil, { status = 204, headers = {}, body = "" }
	end

	if method == "GET" then
		local existing = self.resources[path]
		if not existing then
			return nil, { status = 404, headers = {}, body = "" }
		end
		return nil, { status = 200, headers = { etag = existing.etag }, body = existing.data }
	end

	return nil, { status = 405, headers = {}, body = "" }
end

--------------------------------------------------------------------------
-- Harness
--------------------------------------------------------------------------

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")
local counter = 0

local server
local notifications

local function setup()
	counter = counter + 1
	server = new_server()
	notifications = {}

	config.options.save_path = ("%s/blocks_%d.json"):format(tmpdir, counter)
	config.options.sync = {
		enabled = true,
		store_path = ("%s/sync_%d.json"):format(tmpdir, counter),
		window = { past_days = 30, future_days = 180 },
		conflict = { trail_limit = 50 },
		accounts = {
			{
				id = "work",
				provider = "caldav",
				url = "https://dav.example.com/dav/",
				username = "me@example.com",
				password = "secret",
			},
		},
	}

	state.blocks = {}
	state.save_blocks()
	state.load_blocks()
	store.load()
	require("bloocky.sync.account").forget_secrets()

	caldav.transport = function(opts, callback)
		callback(server:handle(opts))
	end
	return server
end

local function run_sync()
	local report
	sync.run("work", function(result)
		report = result
	end)
	vim.wait(2000, function()
		return report ~= nil
	end)
	return report
end

local function ievent(uid, summary, extra)
	local lines = {
		"BEGIN:VCALENDAR",
		"VERSION:2.0",
		"BEGIN:VEVENT",
		"UID:" .. uid,
		"DTSTAMP:20260801T090000Z",
		"DTSTART:20260813T090000",
		"DTEND:20260813T100000",
		"SUMMARY:" .. summary,
	}
	for _, line in ipairs(extra or {}) do
		table.insert(lines, line)
	end
	table.insert(lines, "END:VEVENT")
	table.insert(lines, "END:VCALENDAR")
	return table.concat(lines, "\r\n")
end

local function find_block(title)
	for _, block in ipairs(state.blocks) do
		if block.title == title then
			return block
		end
	end
end

-- Silence notifications for the duration of the suite.
local real_notify = vim.notify
vim.notify = function(msg, level)
	table.insert(notifications or {}, { msg = msg, level = level })
end

describe("sync engine", function()
	describe("pulling", function()
		it("imports a remote event as a block", function()
			setup()
			server:put(CALENDAR .. "a.ics", ievent("a@example.com", "Sprint planning"))

			local report = run_sync()
			eq(report.pulled.created, 1)

			local block = find_block("Sprint planning")
			truthy(block, "the event should have become a block")
			eq(block.date, "2026-08-13")
			eq(block.start_min, 540)
			eq(block.source, "work")
		end)

		it("is idempotent", function()
			setup()
			server:put(CALENDAR .. "a.ics", ievent("a@example.com", "Sprint planning"))
			run_sync()
			local second = run_sync()
			eq(second.pulled.created, 0, "a second sync must not duplicate anything")
			eq(#state.blocks, 1)
		end)

		it("applies a remote edit", function()
			setup()
			server:put(CALENDAR .. "a.ics", ievent("a@example.com", "Old name"))
			run_sync()
			server:put(CALENDAR .. "a.ics", ievent("a@example.com", "New name"))

			local report = run_sync()
			eq(report.pulled.updated, 1)
			truthy(find_block("New name"))
			falsy(find_block("Old name"))
		end)

		it("removes a block when the event is deleted remotely", function()
			setup()
			server:put(CALENDAR .. "a.ics", ievent("a@example.com", "Sprint planning"))
			run_sync()
			server:remove(CALENDAR .. "a.ics")

			local report = run_sync()
			eq(report.pulled.deleted, 1)
			eq(#state.blocks, 0)
		end)

		it("treats a cancelled event as a deletion", function()
			setup()
			server:put(CALENDAR .. "a.ics", ievent("a@example.com", "Sprint planning"))
			run_sync()
			server:put(CALENDAR .. "a.ics", ievent("a@example.com", "Sprint planning", { "STATUS:CANCELLED" }))

			run_sync()
			eq(#state.blocks, 0)
		end)

		it("counts an all-day event as skipped rather than importing it", function()
			setup()
			local allday = table.concat({
				"BEGIN:VCALENDAR",
				"BEGIN:VEVENT",
				"UID:allday@example.com",
				"DTSTART;VALUE=DATE:20260813",
				"DTEND;VALUE=DATE:20260814",
				"SUMMARY:Public holiday",
				"END:VEVENT",
				"END:VCALENDAR",
			}, "\r\n")
			server:put(CALENDAR .. "allday.ics", allday)

			local report = run_sync()
			eq(#state.blocks, 0)
			eq(report.skipped["all-day"], 1)
		end)
	end)

	describe("pushing", function()
		it("creates a remote event for a new block", function()
			setup()
			local block = state.add_block({
				title = "Deep work",
				date = "2026-08-13",
				start_min = 540,
				duration_min = 90,
			})

			local report = run_sync()
			eq(report.pushed.created, 1)

			local mapping = store.get_mapping(block.id)
			truthy(mapping, "the block should now be mapped")
			truthy(server.resources[mapping.href], "the server should hold the event")
			truthy(server.resources[mapping.href].data:find("SUMMARY:Deep work", 1, true))
			eq(state.get_block(block.id).source, "work")
		end)

		it("pushes an edit", function()
			setup()
			local block = state.add_block({
				title = "Deep work",
				date = "2026-08-13",
				start_min = 540,
				duration_min = 90,
			})
			run_sync()

			state.update_block(block.id, {
				title = "Deeper work",
				date = "2026-08-13",
				start_min = 600,
				duration_min = 90,
			})
			local report = run_sync()
			eq(report.pushed.updated, 1)

			local mapping = store.get_mapping(block.id)
			truthy(server.resources[mapping.href].data:find("SUMMARY:Deeper work", 1, true))
			truthy(server.resources[mapping.href].data:find("T100000", 1, true), "the new start time")
		end)

		-- The guarantee from docs/two-way-sync.md.
		it("preserves parts of the event it does not understand", function()
			setup()
			server:put(
				CALENDAR .. "a.ics",
				ievent("a@example.com", "Sprint planning", {
					"ATTENDEE;CN=Sam:mailto:sam@example.com",
					"X-CUSTOM:keep-me",
				})
			)
			run_sync()

			local block = find_block("Sprint planning")
			state.update_block(block.id, {
				title = "Renamed",
				date = block.date,
				start_min = block.start_min,
				duration_min = block.duration_min,
			})
			run_sync()

			local data = server.resources[CALENDAR .. "a.ics"].data
			truthy(data:find("SUMMARY:Renamed", 1, true))
			truthy(data:find("ATTENDEE;CN=Sam", 1, true), "the attendee was dropped")
			truthy(data:find("X-CUSTOM:keep-me", 1, true), "an unknown property was dropped")
		end)

		it("deletes the remote event when a block is deleted", function()
			setup()
			local block = state.add_block({
				title = "Deep work",
				date = "2026-08-13",
				start_min = 540,
				duration_min = 90,
			})
			run_sync()
			local href = store.get_mapping(block.id).href

			state.delete_block(block.id)
			eq(#store.tombstones("work"), 1, "a tombstone should be waiting")

			local report = run_sync()
			eq(report.pushed.deleted, 1)
			eq(server.resources[href], nil, "the event should be gone from the server")
			eq(#store.tombstones("work"), 0, "the tombstone should be cleared")
		end)

		it("does not resurrect a deleted block on the next sync", function()
			setup()
			local block = state.add_block({
				title = "Deep work",
				date = "2026-08-13",
				start_min = 540,
				duration_min = 90,
			})
			run_sync()
			state.delete_block(block.id)
			run_sync()
			run_sync()
			eq(#state.blocks, 0, "the block came back from the dead")
		end)
	end)

	-- The ordering rule the whole design rests on.
	describe("push before pull", function()
		it("does not revert an unsent local edit", function()
			setup()
			server:put(CALENDAR .. "a.ics", ievent("a@example.com", "Original"))
			run_sync()

			local block = find_block("Original")
			state.update_block(block.id, {
				title = "My edit",
				date = block.date,
				start_min = block.start_min,
				duration_min = block.duration_min,
			})

			local report = run_sync()
			eq(report.pushed.updated, 1)
			truthy(find_block("My edit"), "the local edit was reverted by the pull")
			eq(#report.conflicts, 0, "an unsent edit is not a conflict")
			truthy(server.resources[CALENDAR .. "a.ics"].data:find("SUMMARY:My edit", 1, true))
		end)
	end)

	describe("conflicts", function()
		it("keeps the remote version and records the local one", function()
			setup()
			server:put(CALENDAR .. "a.ics", ievent("a@example.com", "Original"))
			run_sync()

			local block = find_block("Original")
			-- Both sides change before the next sync.
			state.update_block(block.id, {
				title = "My version",
				date = block.date,
				start_min = block.start_min,
				duration_min = block.duration_min,
			})
			server:put(CALENDAR .. "a.ics", ievent("a@example.com", "Their version"))

			local report = run_sync()

			eq(#report.conflicts, 1, "the clash should have been reported")
			truthy(find_block("Their version"), "remote should win")
			falsy(find_block("My version"))

			local trail = store.conflicts()
			eq(#trail, 1)
			eq(trail[1].local_version.title, "My version", "the losing version must be recoverable")
		end)

		it("restores a losing version as a new block", function()
			setup()
			server:put(CALENDAR .. "a.ics", ievent("a@example.com", "Original"))
			run_sync()
			local block = find_block("Original")
			state.update_block(block.id, {
				title = "My version",
				date = block.date,
				start_min = block.start_min,
				duration_min = block.duration_min,
			})
			server:put(CALENDAR .. "a.ics", ievent("a@example.com", "Their version"))
			run_sync()

			sync.restore(1)
			truthy(find_block("My version (restored)"), "the local version should be recoverable")
			truthy(find_block("Their version"), "and the remote one should still be there")
		end)

		it("abandons a local delete when the event changed remotely", function()
			setup()
			server:put(CALENDAR .. "a.ics", ievent("a@example.com", "Original"))
			run_sync()

			local block = find_block("Original")
			state.delete_block(block.id)
			server:put(CALENDAR .. "a.ics", ievent("a@example.com", "Edited elsewhere"))

			local report = run_sync()
			eq(#report.conflicts, 1)
			truthy(server.resources[CALENDAR .. "a.ics"], "the remote event should survive")
			truthy(find_block("Edited elsewhere"), "and come back locally")
		end)
	end)

	describe("recurrence it cannot model", function()
		it("imports the event but never rewrites the rule", function()
			setup()
			server:put(
				CALENDAR .. "a.ics",
				ievent("a@example.com", "Fortnightly", { "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU" })
			)
			run_sync()

			local block = find_block("Fortnightly")
			truthy(block)
			eq(block.recurrence, nil, "bloocky must not claim to own the series")
			truthy(store.get_mapping(block.id).lossy)

			state.update_block(block.id, {
				title = "Renamed",
				date = block.date,
				start_min = 660, -- also try to move it
				duration_min = block.duration_min,
			})
			run_sync()

			local data = server.resources[CALENDAR .. "a.ics"].data
			truthy(data:find("SUMMARY:Renamed", 1, true), "the title edit should go up")
			truthy(data:find("RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU", 1, true), "the rule was flattened")
			truthy(data:find("DTSTART:20260813T090000", 1, true), "timing must be left alone")
		end)

		-- Refusing to send the timing is only half the job. If the block kept
		-- the rejected time it would display an hour the calendar has never
		-- heard of, and nothing would ever correct it.
		it("hands back a timing edit it would not send", function()
			setup()
			server:put(
				CALENDAR .. "a.ics",
				ievent("a@example.com", "Fortnightly", { "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU" })
			)
			run_sync()

			local block = find_block("Fortnightly")
			eq(block.start_min, 540)
			state.update_block(block.id, {
				title = "Fortnightly",
				date = block.date,
				start_min = 660,
				duration_min = block.duration_min,
			})

			local report = run_sync()
			eq(#report.reverted, 1, "the user should be told the edit was undone")
			eq(state.get_block(block.id).start_min, 540, "the block still shows a time the server does not have")

			run_sync()
			eq(state.get_block(block.id).start_min, 540, "and it must stay agreed")
		end)
	end)

	describe("read-only calendars", function()
		it("never writes to one", function()
			setup()
			config.options.sync.accounts[1].calendars = { { name = "Work", mode = "ro" } }
			server:put(CALENDAR .. "a.ics", ievent("a@example.com", "Sprint planning"))
			run_sync()

			local block = find_block("Sprint planning")
			state.update_block(block.id, {
				title = "Should not reach the server",
				date = block.date,
				start_min = block.start_min,
				duration_min = block.duration_min,
			})
			run_sync()

			truthy(
				server.resources[CALENDAR .. "a.ics"].data:find("SUMMARY:Sprint planning", 1, true),
				"a read-only calendar was written to"
			)
			for _, request in ipairs(server.requests) do
				neq(request.method, "PUT", "no PUT should ever be sent to a read-only calendar")
			end
		end)

		-- Refusing to send the edit is right; letting it vanish without a word
		-- is not. Same reasoning as the lossy-timing case.
		it("hands the edit back instead of dropping it silently", function()
			setup()
			config.options.sync.accounts[1].calendars = { { name = "Work", mode = "ro" } }
			server:put(CALENDAR .. "a.ics", ievent("a@example.com", "Sprint planning"))
			run_sync()

			local block = find_block("Sprint planning")
			state.update_block(block.id, {
				title = "Should not stick",
				date = block.date,
				start_min = 660,
				duration_min = block.duration_min,
			})

			local report = run_sync()
			eq(state.get_block(block.id).title, "Sprint planning", "the block should show what the calendar has")
			eq(state.get_block(block.id).start_min, 540)
			eq(#report.reverted, 1, "the user should be told the edit was undone")
		end)
	end)
end)

vim.notify = real_notify
