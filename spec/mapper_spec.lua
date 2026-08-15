local ical = require("bloocky.sync.ical")
local mapper = require("bloocky.sync.mapper")

-- Build the list explicitly: `...` anywhere but the last position in a table
-- constructor is truncated to a single value.
local function wrap(...)
	local lines = {
		"BEGIN:VCALENDAR",
		"VERSION:2.0",
		"BEGIN:VEVENT",
		"UID:test@example.com",
		"DTSTAMP:20260801T090000Z",
	}
	for _, line in ipairs({ ... }) do
		table.insert(lines, line)
	end
	table.insert(lines, "END:VEVENT")
	table.insert(lines, "END:VCALENDAR")
	return table.concat(lines, "\r\n")
end

describe("sync.mapper", function()
	describe("reading events", function()
		it("reads a floating event at face value", function()
			local event = mapper.from_ical(wrap("DTSTART:20260813T090000", "DTEND:20260813T103000", "SUMMARY:Deep work"))
			eq(event.uid, "test@example.com")
			eq(event.block.title, "Deep work")
			eq(event.block.date, "2026-08-13")
			eq(event.block.start_min, 540)
			eq(event.block.duration_min, 90)
		end)

		it("reads a description into notes", function()
			local event = mapper.from_ical(wrap("DTSTART:20260813T090000", "DTEND:20260813T100000", "DESCRIPTION:Bring the roadmap"))
			eq(event.block.notes, "Bring the roadmap")
		end)

		it("falls back to a placeholder title", function()
			eq(mapper.from_ical(wrap("DTSTART:20260813T090000", "DTEND:20260813T100000")).block.title, "(untitled)")
		end)

		it("accepts DURATION instead of DTEND", function()
			local event = mapper.from_ical(wrap("DTSTART:20260813T090000", "DURATION:PT1H30M"))
			eq(event.block.duration_min, 90)
		end)

		it("gives a zero-length event a usable duration", function()
			local event = mapper.from_ical(wrap("DTSTART:20260813T090000", "DTEND:20260813T090000"))
			truthy(event.block.duration_min > 0)
		end)

		it("converts a UTC event to local time", function()
			local original = os.getenv("TZ")
			vim.fn.setenv("TZ", "Asia/Tokyo") -- UTC+9
			os.time()
			local event = mapper.from_ical(wrap("DTSTART:20260813T000000Z", "DTEND:20260813T010000Z"))
			eq(event.block.date, "2026-08-13")
			eq(event.block.start_min, 9 * 60, "midnight UTC is 09:00 in Tokyo")
			vim.fn.setenv("TZ", original)
			os.time()
		end)

		-- An invitation in someone else's zone must land at the right local hour.
		it("converts an event in another zone", function()
			local original = os.getenv("TZ")
			vim.fn.setenv("TZ", "Europe/Lisbon")
			os.time()
			local event = mapper.from_ical(
				wrap("DTSTART;TZID=America/New_York:20260813T090000", "DTEND;TZID=America/New_York:20260813T100000")
			)
			-- New York is UTC-4 in August, Lisbon UTC+1: 09:00 there is 14:00 here.
			eq(event.block.start_min, 14 * 60)
			vim.fn.setenv("TZ", original)
			os.time()
		end)

		it("keeps the original TZID for writing back", function()
			local event = mapper.from_ical(wrap("DTSTART;TZID=America/New_York:20260813T090000", "DTEND;TZID=America/New_York:20260813T100000"))
			eq(event.tzid, "America/New_York")
		end)

		it("treats an unknown TZID as floating rather than guessing", function()
			local event = mapper.from_ical(wrap("DTSTART;TZID=Mars/Olympus:20260813T090000", "DTEND;TZID=Mars/Olympus:20260813T100000"))
			eq(event.block.start_min, 540)
		end)

		it("skips an all-day event instead of inventing a time", function()
			local event = mapper.from_ical(wrap("DTSTART;VALUE=DATE:20260813", "DTEND;VALUE=DATE:20260814"))
			eq(event.skip, "all-day")
			eq(event.block, nil, "no half-imported block")
		end)

		it("flags a cancelled event", function()
			local event = mapper.from_ical(wrap("DTSTART:20260813T090000", "DTEND:20260813T100000", "STATUS:CANCELLED"))
			truthy(event.cancelled)
		end)

		it("refuses an event with no UID", function()
			local text = table.concat({
				"BEGIN:VCALENDAR",
				"BEGIN:VEVENT",
				"DTSTART:20260813T090000",
				"END:VEVENT",
				"END:VCALENDAR",
			}, "\r\n")
			local event, err = mapper.from_ical(text)
			eq(event, nil)
			truthy(err)
		end)
	end)

	describe("recurrence", function()
		it("reads a rule it can model", function()
			local event = mapper.from_ical(wrap("DTSTART:20260813T090000", "DTEND:20260813T100000", "RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"))
			eq(event.block.recurrence, { type = "weekdays" })
			eq(event.lossy, nil)
		end)

		it("flags a rule it cannot model, and imports no recurrence", function()
			local event = mapper.from_ical(wrap("DTSTART:20260813T090000", "DTEND:20260813T100000", "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU"))
			truthy(event.lossy, "should be flagged")
			eq(event.block.recurrence, nil, "never pretend to own a rule we did not understand")
		end)

		it("flags excluded dates", function()
			local event = mapper.from_ical(wrap("DTSTART:20260813T090000", "DTEND:20260813T100000", "RRULE:FREQ=DAILY", "EXDATE:20260815T090000"))
			truthy(event.lossy)
		end)

		it("flags a series with per-occurrence overrides", function()
			local text = table.concat({
				"BEGIN:VCALENDAR",
				"BEGIN:VEVENT",
				"UID:test@example.com",
				"DTSTART:20260813T090000",
				"DTEND:20260813T100000",
				"RRULE:FREQ=DAILY",
				"END:VEVENT",
				"BEGIN:VEVENT",
				"UID:test@example.com",
				"RECURRENCE-ID:20260815T090000",
				"DTSTART:20260815T110000",
				"DTEND:20260815T120000",
				"END:VEVENT",
				"END:VCALENDAR",
			}, "\r\n")
			truthy(mapper.from_ical(text).lossy)
		end)
	end)

	describe("writing", function()
		local block = {
			id = "1755043200_4821",
			title = "Deep work",
			date = "2026-08-13",
			start_min = 540,
			duration_min = 90,
			notes = "focus",
		}

		it("builds an event that reads back identically", function()
			local event = mapper.from_ical(mapper.to_ical(block))
			eq(event.block.title, "Deep work")
			eq(event.block.date, "2026-08-13")
			eq(event.block.start_min, 540)
			eq(event.block.duration_min, 90)
			eq(event.block.notes, "focus")
		end)

		it("round-trips in any timezone, because it writes floating time", function()
			local original = os.getenv("TZ")
			for _, zone in ipairs({ "UTC", "Asia/Tokyo", "America/Sao_Paulo", "Pacific/Auckland" }) do
				vim.fn.setenv("TZ", zone)
				os.time()
				local event = mapper.from_ical(mapper.to_ical(block))
				eq({ event.block.date, event.block.start_min }, { "2026-08-13", 540 }, "drifted in " .. zone)
			end
			vim.fn.setenv("TZ", original)
			os.time()
		end)

		it("derives a stable uid from the block id", function()
			eq(mapper.uid_for(block), "1755043200_4821@bloocky.nvim")
			eq(mapper.href_for(block), "1755043200_4821@bloocky.nvim.ics")
		end)

		it("writes a recurrence rule", function()
			local text = mapper.to_ical(vim.tbl_extend("force", block, { recurrence = { type = "daily" } }))
			truthy(text:find("RRULE:FREQ=DAILY", 1, true))
		end)

		it("reports a block with an unusable date", function()
			local text, err = mapper.to_ical(vim.tbl_extend("force", block, { date = "not-a-date" }))
			eq(text, nil)
			truthy(err)
		end)
	end)

	describe("patch changes", function()
		local block = {
			id = "b1",
			title = "Renamed",
			date = "2026-08-13",
			start_min = 600,
			duration_min = 60,
			notes = "",
		}

		it("changes text and timing on an ordinary event", function()
			local changes = mapper.patch_changes(block, {})
			eq(changes.SUMMARY, "Renamed")
			truthy(changes.DTSTART)
			truthy(changes.DTEND)
		end)

		it("removes the description when notes are empty", function()
			eq(mapper.patch_changes(block, {}).DESCRIPTION, false)
		end)

		-- The guarantee that stops bloocky flattening other people's rules.
		it("touches only text on an event whose recurrence it cannot model", function()
			local changes = mapper.patch_changes(block, { lossy = true })
			eq(changes.SUMMARY, "Renamed")
			eq(changes.DTSTART, nil, "timing must be left alone")
			eq(changes.DTEND, nil)
			eq(changes.RRULE, nil, "the rule must survive untouched")
		end)

		it("clears a rule when the block stopped recurring", function()
			eq(mapper.patch_changes(block, {}).RRULE, false)
		end)

		it("writes back into the event's own timezone", function()
			local original = os.getenv("TZ")
			vim.fn.setenv("TZ", "Europe/Lisbon")
			os.time()
			local changes = mapper.patch_changes(block, { tzid = "America/New_York" })
			truthy(changes.DTSTART.params:find("TZID=America/New_York", 1, true))
			-- 10:00 in Lisbon (UTC+1) is 05:00 in New York (UTC-4).
			truthy(changes.DTSTART.value:find("T050000", 1, true), "got " .. changes.DTSTART.value)
			vim.fn.setenv("TZ", original)
			os.time()
		end)

		it("applies cleanly onto a real invitation", function()
			local invite = table.concat({
				"BEGIN:VCALENDAR",
				"BEGIN:VEVENT",
				"UID:test@example.com",
				"DTSTART:20260813T090000",
				"DTEND:20260813T100000",
				"SUMMARY:Old name",
				"ATTENDEE;CN=Sam:mailto:sam@example.com",
				"END:VEVENT",
				"END:VCALENDAR",
			}, "\r\n")
			local patched = ical.patch(invite, mapper.patch_changes(block, {}))
			truthy(patched:find("SUMMARY:Renamed", 1, true))
			truthy(patched:find("ATTENDEE;CN=Sam", 1, true), "the attendee must survive")
			eq(mapper.from_ical(patched).block.start_min, 600)
		end)
	end)
end)
