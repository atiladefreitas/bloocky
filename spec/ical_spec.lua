local ical = require("bloocky.sync.ical")

-- A realistic invitation: a VALARM, an ATTENDEE, an X- property and a
-- recurrence rule bloocky cannot model. Nothing here may be lost by a patch.
local INVITE = table.concat({
	"BEGIN:VCALENDAR",
	"VERSION:2.0",
	"PRODID:-//Example Corp//EN",
	"BEGIN:VEVENT",
	"UID:3f9a@example.com",
	"DTSTAMP:20260801T090000Z",
	"DTSTART;TZID=Europe/Lisbon:20260813T090000",
	"DTEND;TZID=Europe/Lisbon:20260813T100000",
	"SUMMARY:Sprint planning",
	"DESCRIPTION:Bring the roadmap",
	"RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU",
	"ATTENDEE;CN=Sam:mailto:sam@example.com",
	"X-CUSTOM-FLAG:keep-me",
	"BEGIN:VALARM",
	"ACTION:DISPLAY",
	"DESCRIPTION:Reminder",
	"TRIGGER:-PT15M",
	"END:VALARM",
	"END:VEVENT",
	"END:VCALENDAR",
}, "\r\n")

describe("sync.ical", function()
	describe("folding", function()
		-- §3.1: unfolding removes the CRLF *and* the whitespace character that
		-- follows it. That character is the fold marker, not part of the
		-- value — so a real space has to be carried on the continuation line.
		it("unfolds continuation lines, dropping the fold character", function()
			eq(ical.unfold("SUMMARY:Hello\r\n world"), "SUMMARY:Helloworld")
			eq(ical.unfold("SUMMARY:Hello\r\n  world"), "SUMMARY:Hello world")
		end)

		it("unfolds tab continuations and bare LF", function()
			eq(ical.unfold("SUMMARY:Hello\n\tworld"), "SUMMARY:Helloworld")
		end)

		it("leaves short lines alone", function()
			eq(ical.fold("SUMMARY:short"), "SUMMARY:short")
		end)

		it("folds long lines at 75 octets", function()
			local folded = ical.fold("SUMMARY:" .. string.rep("a", 200))
			for _, line in ipairs(vim.split(folded, "\r\n")) do
				truthy(#line <= 75, "line of " .. #line .. " octets exceeds the limit")
			end
		end)

		it("round-trips through fold and unfold", function()
			local line = "DESCRIPTION:" .. string.rep("content ", 40)
			eq(ical.unfold(ical.fold(line)), line)
		end)

		-- Splitting mid-character would corrupt the value on the wire.
		it("never folds inside a multi-byte character", function()
			local line = "SUMMARY:" .. string.rep("é", 80)
			eq(ical.unfold(ical.fold(line)), line)
			for _, part in ipairs(vim.split(ical.fold(line), "\r\n")) do
				truthy(vim.fn.strchars(part) > 0, "produced an invalid UTF-8 fragment")
			end
		end)
	end)

	describe("escaping", function()
		it("escapes the reserved characters", function()
			eq(ical.escape("a;b,c\\d\ne"), "a\\;b\\,c\\\\d\\ne")
		end)

		it("round-trips", function()
			local raw = "Meeting; with, commas\\backslash\nand a newline"
			eq(ical.unescape(ical.escape(raw)), raw)
		end)

		it("does not double-escape a backslash", function()
			eq(ical.unescape(ical.escape("\\n")), "\\n", "a literal backslash-n is not a newline")
		end)

		it("accepts \\N as a newline", function()
			eq(ical.unescape("line\\Nbreak"), "line\nbreak")
		end)
	end)

	describe("parse_line", function()
		it("splits name, parameters and value", function()
			local prop = ical.parse_line("DTSTART;TZID=Europe/Lisbon:20260813T090000")
			eq(prop.name, "DTSTART")
			eq(prop.params.TZID, "Europe/Lisbon")
			eq(prop.value, "20260813T090000")
		end)

		-- A quoted parameter may contain the colon that would otherwise end
		-- the parameter section.
		it("ignores a colon inside a quoted parameter", function()
			local prop = ical.parse_line('ATTENDEE;CN="Doe: Jane":mailto:jane@example.com')
			eq(prop.name, "ATTENDEE")
			eq(prop.params.CN, "Doe: Jane")
			eq(prop.value, "mailto:jane@example.com")
		end)

		it("handles a property with no parameters", function()
			local prop = ical.parse_line("SUMMARY:Hello")
			eq(prop.params_raw, "")
			eq(prop.value, "Hello")
		end)

		it("returns nil for a line with no colon", function()
			eq(ical.parse_line("NOT A PROPERTY"), nil)
		end)
	end)

	describe("reading", function()
		it("finds the VEVENT", function()
			local doc = ical.parse(INVITE)
			eq(#ical.events(doc), 1)
		end)

		it("reads properties", function()
			local doc = ical.parse(INVITE)
			local range = ical.master(doc)
			eq(ical.text(ical.get(doc, range, "SUMMARY")), "Sprint planning")
			eq(ical.text(ical.get(doc, range, "UID")), "3f9a@example.com")
		end)

		-- The VALARM also has a DESCRIPTION; the event's must win.
		it("does not read properties out of a nested VALARM", function()
			local doc = ical.parse(INVITE)
			eq(ical.text(ical.get(doc, ical.master(doc), "DESCRIPTION")), "Bring the roadmap")
		end)

		it("picks the master of a series over its overrides", function()
			local series = INVITE:gsub(
				"END:VCALENDAR",
				table.concat({
					"BEGIN:VEVENT",
					"UID:3f9a@example.com",
					"RECURRENCE-ID;TZID=Europe/Lisbon:20260827T090000",
					"SUMMARY:Sprint planning (moved)",
					"END:VEVENT",
					"END:VCALENDAR",
				}, "\r\n")
			)
			local doc = ical.parse(series)
			eq(#ical.events(doc), 2)
			eq(ical.text(ical.get(doc, ical.master(doc), "SUMMARY")), "Sprint planning")
		end)
	end)

	describe("patch", function()
		it("replaces a value", function()
			local out = ical.patch(INVITE, { SUMMARY = "Renamed" })
			local doc = ical.parse(out)
			eq(ical.text(ical.get(doc, ical.master(doc), "SUMMARY")), "Renamed")
		end)

		-- This is the whole reason patch() exists.
		it("preserves everything it was not asked to change", function()
			local out = ical.patch(INVITE, { SUMMARY = "Renamed" })
			for _, needle in ipairs({
				"RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU",
				"ATTENDEE;CN=Sam:mailto:sam@example.com",
				"X-CUSTOM-FLAG:keep-me",
				"BEGIN:VALARM",
				"TRIGGER:-PT15M",
				"UID:3f9a@example.com",
			}) do
				truthy(out:find(needle, 1, true), "patch dropped: " .. needle)
			end
		end)

		it("keeps existing parameters on a replaced property", function()
			local out = ical.patch(INVITE, { SUMMARY = "Renamed" })
			truthy(out:find("DTSTART;TZID=Europe/Lisbon:20260813T090000", 1, true))
		end)

		it("escapes text values", function()
			local out = ical.patch(INVITE, { SUMMARY = "a; b, c" })
			truthy(out:find("SUMMARY:a\\; b\\, c", 1, true))
		end)

		it("writes raw values unescaped, for DATE-TIME", function()
			local out = ical.patch(INVITE, {
				DTSTART = { value = "20260813T120000Z", params = "", raw = true },
			})
			truthy(out:find("DTSTART:20260813T120000Z", 1, true))
			falsy(out:find("DTSTART;TZID", 1, true), "the old TZID parameter should be gone")
		end)

		it("adds a property the event did not have", function()
			local out = ical.patch(INVITE, { LOCATION = "Room 3" })
			truthy(out:find("LOCATION:Room 3", 1, true))
			truthy(out:find("LOCATION"), "inserted inside the VEVENT")
			local doc = ical.parse(out)
			eq(ical.text(ical.get(doc, ical.master(doc), "LOCATION")), "Room 3")
		end)

		it("removes a property when given false", function()
			local out = ical.patch(INVITE, { DESCRIPTION = false })
			local doc = ical.parse(out)
			eq(ical.get(doc, ical.master(doc), "DESCRIPTION"), nil)
			truthy(out:find("DESCRIPTION:Reminder", 1, true), "the VALARM's own DESCRIPTION stays")
		end)

		it("leaves the document untouched when nothing changes", function()
			eq(ical.patch(INVITE, {}), ical.serialize(ical.parse(INVITE)))
		end)

		it("patches only the master of a series", function()
			local series = INVITE:gsub(
				"END:VCALENDAR",
				table.concat({
					"BEGIN:VEVENT",
					"UID:3f9a@example.com",
					"RECURRENCE-ID;TZID=Europe/Lisbon:20260827T090000",
					"SUMMARY:Do not touch",
					"END:VEVENT",
					"END:VCALENDAR",
				}, "\r\n")
			)
			local out = ical.patch(series, { SUMMARY = "Renamed" })
			truthy(out:find("SUMMARY:Do not touch", 1, true), "the override was rewritten")
			truthy(out:find("SUMMARY:Renamed", 1, true))
		end)

		it("reports a document with no event", function()
			local out, err = ical.patch("BEGIN:VCALENDAR\r\nEND:VCALENDAR", { SUMMARY = "x" })
			eq(out, nil)
			truthy(err)
		end)
	end)

	describe("date-times", function()
		it("parses a UTC stamp", function()
			local dt = ical.parse_datetime(ical.parse_line("DTSTART:20260813T120000Z"))
			eq({ dt.year, dt.month, dt.day, dt.hour, dt.min }, { 2026, 8, 13, 12, 0 })
			truthy(dt.utc)
			falsy(dt.date_only)
		end)

		it("parses a zoned local stamp", function()
			local dt = ical.parse_datetime(ical.parse_line("DTSTART;TZID=Europe/Lisbon:20260813T090000"))
			eq(dt.tzid, "Europe/Lisbon")
			falsy(dt.utc)
		end)

		it("flags an all-day date", function()
			local dt = ical.parse_datetime(ical.parse_line("DTSTART;VALUE=DATE:20260813"))
			truthy(dt.date_only)
			eq(dt.hour, 0)
		end)

		it("formats back", function()
			local dt = { year = 2026, month = 8, day = 13, hour = 12, min = 0, sec = 0 }
			eq(ical.format_datetime(dt, { utc = true }), "20260813T120000Z")
			eq(ical.format_datetime(dt, { date_only = true }), "20260813")
		end)
	end)

	describe("durations", function()
		it("parses the common forms", function()
			eq(ical.parse_duration("PT1H30M"), 90)
			eq(ical.parse_duration("PT45M"), 45)
			eq(ical.parse_duration("P1D"), 1440)
			eq(ical.parse_duration("P2W"), 20160)
			eq(ical.parse_duration("P1DT2H"), 1560)
		end)

		it("rejects nonsense", function()
			eq(ical.parse_duration("nope"), nil)
			eq(ical.parse_duration("P"), nil)
			eq(ical.parse_duration(nil), nil)
		end)
	end)

	describe("build", function()
		it("produces a parseable event", function()
			local text = ical.build({
				uid = "new@bloocky",
				dtstamp = "20260813T090000Z",
				dtstart = "20260813T120000Z",
				dtend = "20260813T133000Z",
				summary = "Deep work",
				description = "",
			})
			local doc = ical.parse(text)
			local range = ical.master(doc)
			eq(ical.text(ical.get(doc, range, "SUMMARY")), "Deep work")
			eq(ical.text(ical.get(doc, range, "UID")), "new@bloocky")
			eq(ical.get(doc, range, "DESCRIPTION"), nil, "an empty description is omitted, not sent blank")
		end)

		it("emits CRLF line endings", function()
			local text = ical.build({
				uid = "u",
				dtstamp = "20260813T090000Z",
				dtstart = "20260813T120000Z",
				dtend = "20260813T130000Z",
				summary = "x",
			})
			truthy(text:find("\r\n"), "iCalendar requires CRLF")
		end)
	end)
end)
