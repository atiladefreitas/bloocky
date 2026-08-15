local rrule = require("bloocky.sync.rrule")
local tz = require("bloocky.sync.tz")

describe("sync.rrule", function()
	describe("bloocky -> RRULE", function()
		it("maps the four types", function()
			eq(rrule.to_rrule({ type = "daily" }), "FREQ=DAILY")
			eq(rrule.to_rrule({ type = "weekly" }), "FREQ=WEEKLY")
			eq(rrule.to_rrule({ type = "weekdays" }), "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR")
			eq(rrule.to_rrule({ type = "custom", days = { 2, 4, 6 } }), "FREQ=WEEKLY;BYDAY=MO,WE,FR")
		end)

		it("sorts custom days into week order", function()
			eq(rrule.to_rrule({ type = "custom", days = { 6, 2, 4 } }), "FREQ=WEEKLY;BYDAY=MO,WE,FR")
		end)

		it("returns nil for no recurrence", function()
			eq(rrule.to_rrule(nil), nil)
			eq(rrule.to_rrule(vim.NIL), nil)
			eq(rrule.to_rrule({ type = "monthly" }), nil, "an unknown type produces no rule")
			eq(rrule.to_rrule({ type = "custom", days = {} }), nil, "custom with no days is not a rule")
		end)

		it("appends UNTIL", function()
			local value = rrule.to_rrule({ type = "daily", until_date = "2026-12-31" })
			truthy(value:find("^FREQ=DAILY;UNTIL=%d+T%d+Z$"), "got " .. value)
		end)

		it("ignores an empty until_date", function()
			eq(rrule.to_rrule({ type = "daily", until_date = "" }), "FREQ=DAILY")
		end)
	end)

	describe("RRULE -> bloocky", function()
		it("maps the four types back", function()
			eq(rrule.from_rrule("FREQ=DAILY"), { type = "daily" })
			eq(rrule.from_rrule("FREQ=WEEKLY"), { type = "weekly" })
			eq(rrule.from_rrule("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"), { type = "weekdays" })
			eq(rrule.from_rrule("FREQ=WEEKLY;BYDAY=MO,WE,FR"), { type = "custom", days = { 2, 4, 6 } })
		end)

		it("recognises the weekday set in any order", function()
			eq(rrule.from_rrule("FREQ=WEEKLY;BYDAY=FR,MO,WE,TU,TH"), { type = "weekdays" })
		end)

		it("is case-insensitive about keys and values", function()
			eq(rrule.from_rrule("freq=weekly;byday=mo,we"), { type = "custom", days = { 2, 4 } })
		end)

		it("reads UNTIL back to a local date", function()
			local recurrence = rrule.from_rrule("FREQ=DAILY;UNTIL=20261231T235959Z")
			truthy(recurrence.until_date:match("^%d%d%d%d%-%d%d%-%d%d$"))
		end)

		it("returns nothing for an empty rule", function()
			eq(rrule.from_rrule(nil), nil)
			eq(rrule.from_rrule(""), nil)
		end)
	end)

	-- The half that protects other people's calendars.
	describe("refusing what it cannot represent", function()
		local cases = {
			["FREQ=WEEKLY;INTERVAL=2;BYDAY=TU"] = "INTERVAL",
			["FREQ=DAILY;COUNT=10"] = "COUNT",
			["FREQ=MONTHLY;BYMONTHDAY=15"] = "FREQ=MONTHLY",
			["FREQ=YEARLY"] = "FREQ=YEARLY",
			["FREQ=WEEKLY;BYDAY=2MO"] = "ordinal",
			["FREQ=MONTHLY;BYDAY=-1FR"] = "FREQ=MONTHLY",
			["FREQ=WEEKLY;BYSETPOS=1"] = "BYSETPOS",
			["FREQ=DAILY;BYHOUR=9"] = "BYHOUR",
			["FREQ=DAILY;BYDAY=MO"] = "BYDAY",
		}
		for rule, expected in pairs(cases) do
			it("refuses " .. rule, function()
				local recurrence, reason = rrule.from_rrule(rule)
				eq(recurrence, nil)
				truthy(reason, "no reason given")
				truthy(reason:find(expected, 1, true), ("reason %q should mention %q"):format(reason, expected))
			end)
		end

		it("accepts an explicit INTERVAL=1", function()
			eq(rrule.from_rrule("FREQ=DAILY;INTERVAL=1"), { type = "daily" })
		end)
	end)

	describe("round trips", function()
		local recurrences = {
			{ type = "daily" },
			{ type = "weekly" },
			{ type = "weekdays" },
			{ type = "custom", days = { 2, 4, 6 } },
			{ type = "custom", days = { 1, 7 } },
			{ type = "daily", until_date = "2026-12-31" },
			{ type = "weekdays", until_date = "2027-01-15" },
		}
		for _, recurrence in ipairs(recurrences) do
			it(vim.inspect(recurrence):gsub("%s+", " "), function()
				local back = rrule.from_rrule(rrule.to_rrule(recurrence))
				eq(back, recurrence)
			end)
		end

		-- UNTIL crosses to UTC and back, so a zone east of UTC is where an
		-- off-by-one-day bug would show up.
		it("keeps until_date stable across timezones", function()
			local original = os.getenv("TZ")
			for _, zone in ipairs({ "UTC", "Asia/Tokyo", "America/Sao_Paulo", "Pacific/Auckland" }) do
				vim.fn.setenv("TZ", zone)
				os.time() -- force libc to re-read TZ
				local back = rrule.from_rrule(rrule.to_rrule({ type = "daily", until_date = "2026-12-31" }))
				eq(back.until_date, "2026-12-31", "drifted in " .. zone)
			end
			vim.fn.setenv("TZ", original)
		end)
	end)

	describe("unsupported", function()
		it("passes a plain event", function()
			eq(rrule.unsupported({}), nil)
			eq(rrule.unsupported({ rrule = "FREQ=WEEKLY" }), nil)
		end)

		it("flags per-occurrence overrides", function()
			truthy(rrule.unsupported({ overrides = true }))
		end)

		it("flags excluded and extra dates", function()
			truthy(rrule.unsupported({ exdate = true }):find("EXDATE", 1, true))
			truthy(rrule.unsupported({ rdate = true }):find("RDATE", 1, true))
		end)

		it("flags a rule it cannot model", function()
			truthy(rrule.unsupported({ rrule = "FREQ=WEEKLY;INTERVAL=2" }))
		end)
	end)
end)
