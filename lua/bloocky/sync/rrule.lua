-- RRULE <-> bloocky recurrence.
--
-- bloocky models four repeat patterns; RFC 5545 models an open-ended grammar.
-- The translation is therefore partial by design, and the important half of
-- this module is the half that says "no": an event whose rule we cannot
-- represent must be reported as such, so the sync engine keeps the server's
-- own RRULE instead of overwriting it with an approximation.

local tz = require("bloocky.sync.tz")

local M = {}

-- 1 = Sunday .. 7 = Saturday, the C convention bloocky uses everywhere.
-- Not ISO 8601. See docs/block-structure.md.
local TO_ICAL = { "SU", "MO", "TU", "WE", "TH", "FR", "SA" }
local FROM_ICAL = { SU = 1, MO = 2, TU = 3, WE = 4, TH = 5, FR = 6, SA = 7 }

local WEEKDAY_SET = "MO,TU,WE,TH,FR"

-- Parts we understand well enough to round-trip. Anything else in the rule
-- means we must not rewrite it.
local SUPPORTED_PARTS = { FREQ = true, BYDAY = true, UNTIL = true, INTERVAL = true, WKST = true }

--------------------------------------------------------------------------
-- UNTIL
--------------------------------------------------------------------------

-- bloocky's `until_date` is an inclusive local calendar day, so the instant
-- the series stops is the last second of that day *locally*. Emitting a bare
-- 23:59:59Z would cut the series a day short east of UTC and a day long west
-- of it.
local function until_to_ical(until_date)
	local year, month, day = until_date:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
	if not year then
		return nil
	end
	local utc = tz.local_to_utc({
		year = tonumber(year),
		month = tonumber(month),
		day = tonumber(day),
		hour = 23,
		min = 59,
		sec = 59,
	})
	return string.format(
		"%04d%02d%02dT%02d%02d%02dZ",
		utc.year,
		utc.month,
		utc.day,
		utc.hour,
		utc.min,
		utc.sec
	)
end

local function until_from_ical(value)
	local year, month, day = value:match("^(%d%d%d%d)(%d%d)(%d%d)")
	if not year then
		return nil
	end
	local hour, min, sec = value:match("T(%d%d)(%d%d)(%d%d)")
	if hour and value:sub(-1) == "Z" then
		local loc = tz.utc_to_local({
			year = tonumber(year),
			month = tonumber(month),
			day = tonumber(day),
			hour = tonumber(hour),
			min = tonumber(min),
			sec = tonumber(sec),
		})
		return string.format("%04d-%02d-%02d", loc.year, loc.month, loc.day)
	end
	return string.format("%s-%s-%s", year, month, day)
end

--------------------------------------------------------------------------
-- Bloocky -> RRULE
--------------------------------------------------------------------------

-- The EXDATE property value for a block, or nil when nothing is excluded.
-- Emitted as dates: bloocky excludes whole days, never single occurrences of a
-- day, so a date value says exactly what is meant.
function M.to_exdate(recurrence)
	if type(recurrence) ~= "table" or recurrence == vim.NIL then
		return nil
	end
	local dates = {}
	for _, date in ipairs(recurrence.exdates or {}) do
		local year, month, day = tostring(date):match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
		if year then
			table.insert(dates, year .. month .. day)
		end
	end
	if #dates == 0 then
		return nil
	end
	table.sort(dates)
	return table.concat(dates, ",")
end

-- Returns the RRULE property value, or nil for a non-recurring block.
function M.to_rrule(recurrence)
	if type(recurrence) ~= "table" or recurrence == vim.NIL then
		return nil
	end

	local parts
	if recurrence.type == "daily" then
		parts = { "FREQ=DAILY" }
	elseif recurrence.type == "weekly" then
		-- No BYDAY: the weekday comes from DTSTART, which is exactly how
		-- bloocky's `weekly` derives it from `date`.
		parts = { "FREQ=WEEKLY" }
	elseif recurrence.type == "weekdays" then
		parts = { "FREQ=WEEKLY", "BYDAY=" .. WEEKDAY_SET }
	elseif recurrence.type == "custom" then
		local days = {}
		for _, day in ipairs(recurrence.days or {}) do
			if TO_ICAL[day] then
				table.insert(days, day)
			end
		end
		if #days == 0 then
			return nil
		end
		table.sort(days)
		local tokens = {}
		for _, day in ipairs(days) do
			table.insert(tokens, TO_ICAL[day])
		end
		parts = { "FREQ=WEEKLY", "BYDAY=" .. table.concat(tokens, ",") }
	else
		return nil
	end

	if recurrence.until_date and recurrence.until_date ~= "" then
		local stamp = until_to_ical(recurrence.until_date)
		if stamp then
			table.insert(parts, "UNTIL=" .. stamp)
		end
	end
	return table.concat(parts, ";")
end

--------------------------------------------------------------------------
-- RRULE -> bloocky
--------------------------------------------------------------------------

function M.parse_parts(rrule)
	local parts = {}
	for chunk in tostring(rrule):gmatch("[^;]+") do
		local key, value = chunk:match("^%s*([%w%-]+)%s*=%s*(.*)$")
		if key then
			parts[key:upper()] = value
		end
	end
	return parts
end

-- Returns (recurrence, nil) when the rule maps cleanly, or (nil, reason) when
-- it does not. A reason is not an error — it means "display this, but never
-- rewrite its timing".
function M.from_rrule(rrule)
	if type(rrule) ~= "string" or rrule == "" then
		return nil, nil
	end
	local parts = M.parse_parts(rrule)

	-- FREQ first: it is the rule's shape, so "FREQ=MONTHLY is not supported"
	-- explains a monthly rule better than naming whichever BY- part happened
	-- to be iterated first.
	local freq = (parts.FREQ or ""):upper()
	if freq ~= "DAILY" and freq ~= "WEEKLY" then
		return nil, "FREQ=" .. (freq ~= "" and freq or "?") .. " is not supported"
	end

	for key in pairs(parts) do
		if not SUPPORTED_PARTS[key] then
			return nil, "unsupported rule part " .. key
		end
	end

	if parts.COUNT then
		return nil, "COUNT is not supported"
	end
	if parts.INTERVAL and parts.INTERVAL ~= "1" then
		return nil, "INTERVAL=" .. parts.INTERVAL .. " is not supported"
	end

	local recurrence = {}
	if parts.UNTIL then
		local date = until_from_ical(parts.UNTIL)
		if not date then
			return nil, "malformed UNTIL"
		end
		recurrence.until_date = date
	end

	if freq == "DAILY" then
		if parts.BYDAY then
			return nil, "FREQ=DAILY with BYDAY is not supported"
		end
		recurrence.type = "daily"
		return recurrence, nil
	end

	if not parts.BYDAY then
		recurrence.type = "weekly"
		return recurrence, nil
	end

	-- An ordinal prefix ("2MO" = the second Monday) is a monthly-shaped rule
	-- wearing weekly clothes.
	if parts.BYDAY:match("%-?%d") then
		return nil, "ordinal BYDAY (" .. parts.BYDAY .. ") is not supported"
	end

	local days, seen = {}, {}
	for token in parts.BYDAY:upper():gmatch("[A-Z][A-Z]") do
		local day = FROM_ICAL[token]
		if not day then
			return nil, "unknown weekday " .. token
		end
		if not seen[day] then
			seen[day] = true
			table.insert(days, day)
		end
	end
	if #days == 0 then
		return nil, "empty BYDAY"
	end
	table.sort(days)

	if #days == 5 and seen[2] and seen[3] and seen[4] and seen[5] and seen[6] then
		recurrence.type = "weekdays"
	else
		recurrence.type = "custom"
		recurrence.days = days
	end
	return recurrence, nil
end

--------------------------------------------------------------------------
-- Whether an event can be edited at all
--------------------------------------------------------------------------

-- `event` describes what the VEVENT carries:
--   { rrule = string|nil, exdate = bool, rdate = bool, overrides = bool }
--
-- Returns nil when bloocky can safely own the event's timing, or a reason
-- string when it can only be displayed and have its text edited.
function M.unsupported(event)
	if event.overrides then
		return "the series has per-occurrence changes bloocky cannot represent"
	end
	if event.exdate then
		return "the series has excluded dates (EXDATE) bloocky cannot represent"
	end
	if event.rdate then
		return "the series has extra dates (RDATE) bloocky cannot represent"
	end
	if event.rrule then
		local _, reason = M.from_rrule(event.rrule)
		return reason
	end
	return nil
end

return M
