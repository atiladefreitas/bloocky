local google = require("bloocky.sync.providers.google")
local mapper = require("bloocky.sync.mapper")
local oauth = require("bloocky.sync.oauth")

describe("sync.providers.google", function()
	describe("JSON -> iCalendar", function()
		it("converts a timed event", function()
			local text = google.to_ical({
				id = "abc123",
				iCalUID = "abc123@google.com",
				summary = "Sprint planning",
				description = "Bring the roadmap",
				start = { dateTime = "2026-08-13T09:00:00-03:00" },
				["end"] = { dateTime = "2026-08-13T10:00:00-03:00" },
			})
			local event = mapper.from_ical(text)
			eq(event.uid, "abc123@google.com")
			eq(event.block.title, "Sprint planning")
			eq(event.block.notes, "Bring the roadmap")
			eq(event.block.duration_min, 60)
		end)

		-- Google always sends an offset; the instant it denotes must survive.
		it("honours the UTC offset rather than reading the clock face", function()
			local original = os.getenv("TZ")
			vim.fn.setenv("TZ", "UTC")
			os.time()
			local event = mapper.from_ical(google.to_ical({
				id = "x",
				start = { dateTime = "2026-08-13T09:00:00-03:00" },
				["end"] = { dateTime = "2026-08-13T10:00:00-03:00" },
			}))
			-- 09:00 at UTC-3 is 12:00 UTC.
			eq(event.block.start_min, 12 * 60)
			vim.fn.setenv("TZ", original)
			os.time()
		end)

		it("carries a recurrence rule through untouched", function()
			local event = mapper.from_ical(google.to_ical({
				id = "x",
				start = { dateTime = "2026-08-13T09:00:00Z" },
				["end"] = { dateTime = "2026-08-13T10:00:00Z" },
				recurrence = { "RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR" },
			}))
			eq(event.block.recurrence, { type = "weekdays" })
			eq(event.lossy, nil)
		end)

		-- The whole reason for going through iCalendar: lossiness detection
		-- stays on one code path.
		it("flags a rule bloocky cannot model", function()
			local event = mapper.from_ical(google.to_ical({
				id = "x",
				start = { dateTime = "2026-08-13T09:00:00Z" },
				["end"] = { dateTime = "2026-08-13T10:00:00Z" },
				recurrence = { "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU" },
			}))
			truthy(event.lossy)
			eq(event.block.recurrence, nil)
		end)

		it("flags excluded dates", function()
			local event = mapper.from_ical(google.to_ical({
				id = "x",
				start = { dateTime = "2026-08-13T09:00:00Z" },
				["end"] = { dateTime = "2026-08-13T10:00:00Z" },
				recurrence = { "RRULE:FREQ=DAILY", "EXDATE;TZID=UTC:20260815T090000" },
			}))
			truthy(event.lossy)
		end)

		it("marks an all-day event so it is skipped, not mistimed", function()
			local event = mapper.from_ical(google.to_ical({
				id = "x",
				summary = "Holiday",
				start = { date = "2026-08-13" },
				["end"] = { date = "2026-08-14" },
			}))
			eq(event.skip, "all-day")
		end)

		it("passes a cancellation through", function()
			local event = mapper.from_ical(google.to_ical({
				id = "x",
				status = "cancelled",
				start = { dateTime = "2026-08-13T09:00:00Z" },
				["end"] = { dateTime = "2026-08-13T10:00:00Z" },
			}))
			truthy(event.cancelled)
		end)

		it("returns nothing for an event with no start", function()
			eq(google.to_ical({ id = "x", summary = "Broken" }), nil)
		end)
	end)

	describe("block -> JSON", function()
		local block = {
			id = "b1",
			title = "Deep work",
			date = "2026-08-13",
			start_min = 540,
			duration_min = 90,
			notes = "focus",
		}

		it("builds start and end", function()
			local body = google.event_body(block, { timezone = "America/Sao_Paulo" })
			eq(body.summary, "Deep work")
			eq(body.description, "focus")
			eq(body.start.dateTime, "2026-08-13T09:00:00")
			eq(body.start.timeZone, "America/Sao_Paulo")
			eq(body["end"].dateTime, "2026-08-13T10:30:00")
		end)

		it("omits an empty description rather than sending a blank one", function()
			eq(google.event_body(vim.tbl_extend("force", block, { notes = "" }), { timezone = "UTC" }).description, nil)
		end)

		it("includes a recurrence rule", function()
			local body = google.event_body(
				vim.tbl_extend("force", block, { recurrence = { type = "daily" } }),
				{ timezone = "UTC" }
			)
			eq(body.recurrence, { "RRULE:FREQ=DAILY" })
		end)

		-- An omitted key leaves the old rule in place on a PATCH; an empty
		-- list is what clears it.
		it("sends an empty list when the block no longer recurs", function()
			eq(google.event_body(block, { timezone = "UTC" }).recurrence, {})
			truthy(google.encode(google.event_body(block, { timezone = "UTC" })):find('"recurrence":[]', 1, true))
		end)

		it("falls back to an explicit offset when no zone is known", function()
			local body = google.event_body(block, { timezone = false })
			truthy(body.start.dateTime:match("[%+%-]%d%d:%d%d$"), "got " .. body.start.dateTime)
		end)

		it("reports an unusable date", function()
			local body, err = google.event_body(vim.tbl_extend("force", block, { date = "nope" }))
			eq(body, nil)
			truthy(err)
		end)
	end)

	-- Everything below drives the provider against a fake Google, so the
	-- request shapes and error handling are exercised without a network.
	describe("against a fake API", function()
		local account = { id = "g", provider = "google", client_id = "x" }
		local requests

		local function serve(routes)
			requests = {}
			oauth.store_tokens("g", { access_token = "fake", expires_at = os.time() + 3600 })
			google.transport = function(opts, cb)
				table.insert(requests, opts)
				for pattern, response in pairs(routes) do
					if opts.url:find(pattern) then
						return cb(nil, {
							status = response.status or 200,
							headers = {},
							body = response.body and vim.json.encode(response.body) or "",
						})
					end
				end
				cb(nil, { status = 404, headers = {}, body = "" })
			end
		end

		local function run(fn)
			local result, err, done
			require("bloocky.sync.async").run(function()
				result, err = fn()
				done = true
			end, function()
				done = true
			end)
			vim.wait(2000, function()
				return done
			end)
			return result, err
		end

		it("lists calendars and reads their access role", function()
			serve({
				["calendarList"] = {
					body = {
						items = {
							{ id = "primary", summary = "Personal", accessRole = "owner" },
							{ id = "team@g.com", summary = "Team", accessRole = "reader" },
							{ id = "old@g.com", summary = "Old", accessRole = "owner", deleted = true },
						},
					},
				},
			})
			local calendars = run(function()
				return google.discover(account)
			end)
			eq(#calendars, 2, "a deleted calendar should be dropped")
			eq(calendars[1].name, "Personal")
			falsy(calendars[1].readonly)
			truthy(calendars[2].readonly, "reader access cannot be written to")
		end)

		it("surfaces Google's own error wording", function()
			serve({ ["calendarList"] = { status = 403, body = { error = { message = "Insufficient Permission" } } } })
			local _, err = run(function()
				return google.discover(account)
			end)
			truthy(err:find("Insufficient Permission", 1, true), "got " .. tostring(err))
		end)

		it("turns cancelled events into removals", function()
			serve({
				["/events"] = {
					body = {
						items = {
							{
								id = "a",
								etag = '"1"',
								summary = "Live",
								start = { dateTime = "2026-08-13T09:00:00Z" },
								["end"] = { dateTime = "2026-08-13T10:00:00Z" },
							},
							{ id = "b", status = "cancelled" },
						},
						nextSyncToken = "tok-1",
					},
				},
			})
			local result = run(function()
				return google.fetch(account, { href = "primary" }, nil, { start = "20260714T120000Z" })
			end)
			eq(#result.changed, 1)
			eq(#result.removed, 1)
			eq(result.removed[1], "b")
			eq(result.cursor.token, "tok-1")
		end)

		-- Google ties a syncToken to the exact query it came from, so timeMin
		-- must not drift between runs.
		it("keeps timeMin stable across incremental fetches", function()
			serve({ ["/events"] = { body = { items = {}, nextSyncToken = "tok-2" } } })
			local first = run(function()
				return google.fetch(account, { href = "primary" }, nil, { start = "20260714T120000Z" })
			end)
			eq(first.cursor.time_min, "2026-07-14T12:00:00Z")

			run(function()
				return google.fetch(account, { href = "primary" }, first.cursor, { start = "20260801T000000Z" })
			end)
			local last = requests[#requests].url
			truthy(last:find("syncToken=tok-2", 1, true), "the stored token should be reused")
			falsy(last:find("timeMin", 1, true), "an incremental call must not re-send a drifting timeMin")
		end)

		it("falls back to a full fetch when the token has expired", function()
			local calls = 0
			requests = {}
			oauth.store_tokens("g", { access_token = "fake", expires_at = os.time() + 3600 })
			google.transport = function(opts, cb)
				calls = calls + 1
				table.insert(requests, opts)
				if calls == 1 then
					return cb(nil, { status = 410, headers = {}, body = vim.json.encode({ error = { message = "gone" } }) })
				end
				cb(nil, { status = 200, headers = {}, body = vim.json.encode({ items = {}, nextSyncToken = "fresh" }) })
			end

			local result = run(function()
				return google.fetch(account, { href = "primary" }, { token = "stale" }, { start = "20260714T120000Z" })
			end)
			eq(result.cursor.token, "fresh", "a 410 should trigger a full resync, not an error")
			truthy(requests[#requests].url:find("timeMin", 1, true))
		end)

		it("creates with POST and returns the new identity", function()
			serve({
				["/events"] = {
					body = {
						id = "new-id",
						iCalUID = "new-id@google.com",
						etag = '"e1"',
						summary = "Deep work",
						start = { dateTime = "2026-08-13T09:00:00Z" },
						["end"] = { dateTime = "2026-08-13T10:30:00Z" },
					},
				},
			})
			local result = run(function()
				return google.create_event(
					account,
					{ href = "primary" },
					{ id = "b1", title = "Deep work", date = "2026-08-13", start_min = 540, duration_min = 90 }
				)
			end)
			eq(requests[1].method, "POST")
			eq(result.href, "new-id")
			eq(result.etag, '"e1"')
			truthy(result.raw:find("SUMMARY:Deep work", 1, true))
		end)

		-- PATCH, not PUT: Google merges server-side, so attendees and
		-- conferencing data bloocky knows nothing about survive.
		it("updates with PATCH and an If-Match", function()
			serve({
				["/events/"] = {
					body = {
						id = "e1",
						etag = '"e2"',
						summary = "Renamed",
						start = { dateTime = "2026-08-13T09:00:00Z" },
						["end"] = { dateTime = "2026-08-13T10:00:00Z" },
					},
				},
			})
			run(function()
				return google.update_event(
					account,
					{ href = "e1", calendar = "primary", etag = '"e1"' },
					{ id = "b1", title = "Renamed", date = "2026-08-13", start_min = 540, duration_min = 60 }
				)
			end)
			eq(requests[1].method, "PATCH")
			eq(requests[1].headers["If-Match"], '"e1"')
		end)

		it("sends only text for an event whose recurrence it cannot model", function()
			serve({
				["/events/"] = {
					body = {
						id = "e1",
						etag = '"e2"',
						start = { dateTime = "2026-08-13T09:00:00Z" },
						["end"] = { dateTime = "2026-08-13T10:00:00Z" },
					},
				},
			})
			run(function()
				return google.update_event(
					account,
					{ href = "e1", calendar = "primary", etag = '"e1"', lossy = true },
					{ id = "b1", title = "Renamed", date = "2026-08-13", start_min = 660, duration_min = 60 }
				)
			end)
			local sent = vim.json.decode(requests[1].body)
			eq(sent.summary, "Renamed")
			eq(sent.start, nil, "timing must not be sent for a rule we do not understand")
			eq(sent.recurrence, nil, "the rule must be left alone")
		end)

		it("reports a 412 as a conflict rather than an error", function()
			serve({ ["/events/"] = { status = 412 } })
			local result, err = run(function()
				return google.update_event(account, { href = "e1", calendar = "primary", etag = '"old"' }, {
					id = "b1",
					title = "x",
					date = "2026-08-13",
					start_min = 540,
					duration_min = 60,
				})
			end)
			eq(err, nil)
			truthy(result.conflict)
		end)

		it("treats an already-deleted event as success", function()
			serve({ ["/events/"] = { status = 404 } })
			local result, err = run(function()
				return google.delete_event(account, { href = "e1", calendar = "primary" })
			end)
			eq(err, nil)
			truthy(result.missing, "the desired state is 'not there', and it is not there")
		end)
	end)
end)
