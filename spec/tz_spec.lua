local tz = require("bloocky.sync.tz")

-- Zones chosen to cover the ways this goes wrong: no offset, a half-hour
-- offset, southern-hemisphere DST (in DST during December), northern DST, and
-- a far-eastern offset where a late-evening local time is the previous day in
-- UTC.
local ZONES = { "UTC", "Europe/Lisbon", "America/Sao_Paulo", "Asia/Tokyo", "Asia/Kolkata", "Pacific/Auckland" }

local function in_zone(zone, fn)
	local previous = os.getenv("TZ")
	vim.fn.setenv("TZ", zone)
	os.time() -- force libc to re-read TZ
	local ok, err = pcall(fn)
	vim.fn.setenv("TZ", previous)
	os.time()
	if not ok then
		error(err, 0)
	end
end

describe("sync.tz", function()
	describe("conversions", function()
		for _, zone in ipairs(ZONES) do
			it("round-trips local -> UTC -> local in " .. zone, function()
				in_zone(zone, function()
					-- Both sides of a DST boundary in either hemisphere.
					for _, dt in ipairs({
						{ year = 2026, month = 1, day = 15, hour = 9, min = 30, sec = 0 },
						{ year = 2026, month = 6, day = 15, hour = 9, min = 30, sec = 0 },
						{ year = 2026, month = 12, day = 31, hour = 23, min = 59, sec = 59 },
						{ year = 2026, month = 7, day = 1, hour = 0, min = 0, sec = 0 },
					}) do
						eq(tz.utc_to_local(tz.local_to_utc(dt)), dt, vim.inspect(dt))
					end
				end)
			end)
		end

		it("agrees with os.date on a known instant", function()
			in_zone("UTC", function()
				local dt = { year = 2026, month = 8, day = 13, hour = 12, min = 0, sec = 0 }
				eq(tz.local_to_utc(dt), dt, "UTC is its own local time")
			end)
		end)

		it("computes the offset with the right sign", function()
			-- Tokyo is UTC+9 year round, so local noon is 03:00 UTC.
			in_zone("Asia/Tokyo", function()
				local utc = tz.local_to_utc({ year = 2026, month = 8, day = 13, hour = 12, min = 0, sec = 0 })
				eq({ utc.hour, utc.day }, { 3, 13 })
			end)
			-- São Paulo is UTC-3, so local noon is 15:00 UTC.
			in_zone("America/Sao_Paulo", function()
				local utc = tz.local_to_utc({ year = 2026, month = 8, day = 13, hour = 12, min = 0, sec = 0 })
				eq({ utc.hour, utc.day }, { 15, 13 })
			end)
		end)

		it("handles a half-hour offset", function()
			in_zone("Asia/Kolkata", function() -- UTC+5:30
				local utc = tz.local_to_utc({ year = 2026, month = 8, day = 13, hour = 12, min = 0, sec = 0 })
				eq({ utc.hour, utc.min }, { 6, 30 })
			end)
		end)

		it("carries the date across a day boundary", function()
			in_zone("Pacific/Auckland", function() -- UTC+13 in December
				local utc = tz.local_to_utc({ year = 2026, month = 12, day = 31, hour = 23, min = 59, sec = 59 })
				eq(utc.day, 31, "still the 31st in UTC")
				eq(utc.hour, 10)
			end)
			in_zone("Asia/Tokyo", function()
				local utc = tz.local_to_utc({ year = 2026, month = 8, day = 13, hour = 6, min = 0, sec = 0 })
				eq(utc.day, 12, "early morning in Tokyo is the previous day in UTC")
			end)
		end)

		-- The regression that motivated these specs: forcing isdst=false made
		-- a DST date an hour early, and an hour early at 23:59 is a day early.
		it("does not shift a date that falls inside DST", function()
			in_zone("Pacific/Auckland", function()
				local dt = { year = 2026, month = 12, day = 31, hour = 23, min = 59, sec = 59 }
				eq(tz.utc_to_local(tz.local_to_utc(dt)).day, 31)
			end)
			in_zone("Europe/Lisbon", function()
				local dt = { year = 2026, month = 7, day = 15, hour = 23, min = 30, sec = 0 }
				eq(tz.utc_to_local(tz.local_to_utc(dt)).day, 15)
			end)
		end)
	end)

	describe("blocks", function()
		it("converts a block to UTC and back", function()
			for _, zone in ipairs(ZONES) do
				in_zone(zone, function()
					local date, start_min = tz.utc_to_block(tz.block_to_utc("2026-08-13", 540))
					eq({ date, start_min }, { "2026-08-13", 540 }, "drifted in " .. zone)
				end)
			end
		end)

		it("survives a block at either end of the day", function()
			for _, zone in ipairs(ZONES) do
				in_zone(zone, function()
					for _, minutes in ipairs({ 0, 30, 1410 }) do
						local date, start_min = tz.utc_to_block(tz.block_to_utc("2026-12-31", minutes))
						eq({ date, start_min }, { "2026-12-31", minutes }, ("%s at %d"):format(zone, minutes))
					end
				end)
			end
		end)

		it("rejects a malformed date", function()
			eq(tz.block_to_utc("13/08/2026", 540), nil)
		end)

		it("reads a floating wall clock at face value", function()
			local date, start_min = tz.floating_to_block({ year = 2026, month = 8, day = 13, hour = 9, min = 30 })
			eq({ date, start_min }, { "2026-08-13", 570 })
		end)

		it("stamps the current time in UTC", function()
			truthy(tz.now_utc_stamp():match("^%d%d%d%d%d%d%d%dT%d%d%d%d%d%dZ$"))
		end)
	end)

	describe("zone detection", function()
		it("can be overridden", function()
			local before = tz.local_zone()
			tz.set_local_zone("Europe/Lisbon")
			eq(tz.local_zone(), "Europe/Lisbon")
			tz.set_local_zone(before)
		end)

		it("reports nil rather than guessing when it cannot tell", function()
			local before = tz.local_zone()
			tz.set_local_zone(nil)
			eq(tz.local_zone(), nil)
			tz.set_local_zone(before)
		end)
	end)
end)
