local config = require("bloocky.config")
local state = require("bloocky.state")

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")
local counter = 0

local function fresh(blocks)
	counter = counter + 1
	config.options.save_path = ("%s/allday_%d.json"):format(tmpdir, counter)
	config.options.sync = { enabled = false, accounts = {} }
	state.blocks = blocks or {}
	state.save_blocks()
	state.load_blocks()
end

local function date(y, m, d)
	return { year = y, month = m, day = d }
end

local function titles(list)
	return vim.tbl_map(function(b)
		return b.title
	end, list)
end

describe("all-day blocks", function()
	describe("spanning days", function()
		it("shows a one-day block only on its day", function()
			fresh({
				{ id = "a", title = "Holiday", date = "2026-08-13", start_min = 0, duration_min = 1440, all_day = true },
			})
			eq(titles(state.blocks_for_date(date(2026, 8, 12))), {})
			eq(titles(state.blocks_for_date(date(2026, 8, 13))), { "Holiday" })
			eq(titles(state.blocks_for_date(date(2026, 8, 14))), {})
		end)

		-- A week away should appear on every day of that week, not just the
		-- day it started.
		it("shows a multi-day block on every day it covers", function()
			fresh({
				{ id = "a", title = "Trip", date = "2026-08-13", start_min = 0, duration_min = 3 * 1440, all_day = true },
			})
			eq(titles(state.blocks_for_date(date(2026, 8, 12))), {})
			for day = 13, 15 do
				eq(titles(state.blocks_for_date(date(2026, 8, day))), { "Trip" }, "day " .. day)
			end
			eq(titles(state.blocks_for_date(date(2026, 8, 16))), {}, "DTEND is exclusive")
		end)

		it("spans across a month boundary", function()
			fresh({
				{ id = "a", title = "Trip", date = "2026-08-30", start_min = 0, duration_min = 4 * 1440, all_day = true },
			})
			eq(titles(state.blocks_for_date(date(2026, 9, 2))), { "Trip" })
			eq(titles(state.blocks_for_date(date(2026, 9, 3))), {})
		end)

		-- A timed block that runs long is still one day; only all-day blocks
		-- span, or a late meeting would smear across the week.
		it("does not span a timed block", function()
			fresh({
				{ id = "a", title = "Long", date = "2026-08-13", start_min = 540, duration_min = 5 * 1440 },
			})
			eq(titles(state.blocks_for_date(date(2026, 8, 14))), {})
		end)

		it("does not loop forever on an absurd duration", function()
			fresh({
				{ id = "a", title = "Bad", date = "2026-08-13", start_min = 0, duration_min = 99999999, all_day = true },
			})
			-- Just has to return, and quickly.
			eq(#state.blocks_for_date(date(2030, 1, 1)), 0)
		end)
	end)

	describe("ordering", function()
		it("puts all-day blocks first", function()
			fresh({
				{ id = "t", title = "Timed", date = "2026-08-13", start_min = 540, duration_min = 60 },
				{ id = "a", title = "Holiday", date = "2026-08-13", start_min = 0, duration_min = 1440, all_day = true },
			})
			eq(titles(state.blocks_for_date(date(2026, 8, 13))), { "Holiday", "Timed" })
		end)

		it("splits them for the views", function()
			fresh({
				{ id = "t", title = "Timed", date = "2026-08-13", start_min = 540, duration_min = 60 },
				{ id = "a", title = "Holiday", date = "2026-08-13", start_min = 0, duration_min = 1440, all_day = true },
			})
			local all_day, timed = state.split_for_date(date(2026, 8, 13))
			eq(titles(all_day), { "Holiday" })
			eq(titles(timed), { "Timed" })
		end)
	end)

	describe("recurring all-day blocks", function()
		it("spans from each occurrence", function()
			fresh({
				{
					id = "a",
					title = "Weekend",
					date = "2026-08-08", -- a Saturday
					start_min = 0,
					duration_min = 2 * 1440,
					all_day = true,
					recurrence = { type = "weekly" },
				},
			})
			eq(titles(state.blocks_for_date(date(2026, 8, 15))), { "Weekend" }, "the next Saturday")
			eq(titles(state.blocks_for_date(date(2026, 8, 16))), { "Weekend" }, "and the Sunday it runs into")
			eq(titles(state.blocks_for_date(date(2026, 8, 17))), {}, "but not the Monday")
		end)
	end)
end)

describe("excluded dates", function()
	local function daily(exdates)
		return {
			{
				id = "a",
				title = "Standup",
				date = "2026-08-10",
				start_min = 540,
				duration_min = 30,
				recurrence = { type = "daily", exdates = exdates },
			},
		}
	end

	it("skips an excluded day", function()
		fresh(daily({ "2026-08-12" }))
		eq(titles(state.blocks_for_date(date(2026, 8, 11))), { "Standup" })
		eq(titles(state.blocks_for_date(date(2026, 8, 12))), {}, "excluded")
		eq(titles(state.blocks_for_date(date(2026, 8, 13))), { "Standup" })
	end)

	it("handles several exclusions", function()
		fresh(daily({ "2026-08-12", "2026-08-14" }))
		eq(titles(state.blocks_for_date(date(2026, 8, 12))), {})
		eq(titles(state.blocks_for_date(date(2026, 8, 13))), { "Standup" })
		eq(titles(state.blocks_for_date(date(2026, 8, 14))), {})
	end)

	it("ignores an empty exclusion list", function()
		fresh(daily({}))
		eq(titles(state.blocks_for_date(date(2026, 8, 12))), { "Standup" })
	end)

	-- The exclusion removes the occurrence, so a multi-day one goes entirely.
	it("removes the whole span of an excluded all-day occurrence", function()
		fresh({
			{
				id = "a",
				title = "Trip",
				date = "2026-08-08",
				start_min = 0,
				duration_min = 2 * 1440,
				all_day = true,
				recurrence = { type = "weekly", exdates = { "2026-08-15" } },
			},
		})
		eq(titles(state.blocks_for_date(date(2026, 8, 15))), {})
		eq(titles(state.blocks_for_date(date(2026, 8, 16))), {}, "the second day goes with it")
		eq(titles(state.blocks_for_date(date(2026, 8, 22))), { "Trip" }, "the next occurrence is unaffected")
	end)
end)

describe("health check", function()
	it("runs without throwing", function()
		fresh()
		local ok, err = pcall(require("bloocky.health").check)
		truthy(ok, "checkhealth threw: " .. tostring(err))
	end)

	it("runs with sync enabled and a broken account", function()
		fresh()
		config.options.sync = {
			enabled = true,
			accounts = {
				{ id = "spec-health", provider = "caldav", url = "https://x/", username = "u", password_cmd = { "false" } },
			},
		}
		local ok, err = pcall(require("bloocky.health").check)
		truthy(ok, "checkhealth threw: " .. tostring(err))
		config.options.sync = { enabled = false, accounts = {} }
	end)
end)
