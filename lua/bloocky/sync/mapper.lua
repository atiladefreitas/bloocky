-- Translating between a bloocky block and a VEVENT.
--
-- On the way out we write *floating* local times — no Z, no TZID. That is not
-- a shortcut, it is the block model: docs/block-structure.md says a 09:00
-- block is 09:00 everywhere, and a floating DATE-TIME means exactly that in
-- RFC 5545. Pinning blocks to a UTC instant instead would make the calendar
-- and bloocky disagree the moment you changed timezone, and would put a DST
-- conversion in the path of every write.
--
-- On the way in we accept whatever the server sends — UTC, zoned, or floating
-- — and land it on the local wall clock, because that is the only thing a
-- block can express.

local config = require("bloocky.config")
local ical = require("bloocky.sync.ical")
local rrule = require("bloocky.sync.rrule")
local tz = require("bloocky.sync.tz")
local utils = require("bloocky.utils")

local M = {}

--------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------

-- A date-time as an absolute instant, whatever form it arrived in.
local function to_instant(dt, tzid)
	if dt.utc then
		return tz.timegm(dt)
	end
	if tzid and tz.zone_exists(tzid) then
		local utc = tz.zoned_to_utc(dt, tzid)
		if utc then
			return tz.timegm(utc)
		end
	end
	-- Floating, or a TZID the system does not know: read the wall clock at
	-- face value, which is what a block means anyway.
	return os.time({ year = dt.year, month = dt.month, day = dt.day, hour = dt.hour, min = dt.min, sec = dt.sec })
end

-- Parse one calendar object into something the sync engine can act on.
--
-- Returns { uid, block, lossy, skip, ... }. `skip` means bloocky has no way to
-- show it at all and it should be counted and ignored, never half-imported.
function M.from_ical(text)
	local doc = ical.parse(text)
	local range = ical.master(doc)
	if not range then
		return nil, "no VEVENT"
	end

	local uid = ical.text(ical.get(doc, range, "UID"))
	if not uid then
		return nil, "event has no UID"
	end

	local event = { uid = uid, raw = text }

	local status = ical.text(ical.get(doc, range, "STATUS"))
	event.cancelled = status ~= nil and status:upper() == "CANCELLED"

	local transp = ical.text(ical.get(doc, range, "TRANSP"))
	event.transparent = transp ~= nil and transp:upper() == "TRANSPARENT"

	local dtstart_prop = ical.get(doc, range, "DTSTART")
	local dtstart = ical.parse_datetime(dtstart_prop)
	if not dtstart then
		return nil, "event has no usable DTSTART"
	end
	event.tzid = dtstart.tzid

	-- All-day events have no place on an hour grid yet. Counted and skipped,
	-- rather than shown at a time nobody chose.
	if dtstart.date_only then
		event.skip = "all-day"
		event.all_day = true
		return event
	end

	local start_instant = to_instant(dtstart, dtstart.tzid)

	local duration_min
	local dtend = ical.parse_datetime(ical.get(doc, range, "DTEND"))
	if dtend then
		duration_min = math.floor((to_instant(dtend, dtend.tzid or dtstart.tzid) - start_instant) / 60)
	else
		duration_min = ical.parse_duration(ical.text(ical.get(doc, range, "DURATION")))
	end
	if not duration_min or duration_min <= 0 then
		duration_min = config.options.granularity
	end

	local starts = os.date("*t", start_instant)

	local rrule_value = ical.text(ical.get(doc, range, "RRULE"))
	local recurrence = rrule_value and rrule.from_rrule(rrule_value) or nil

	event.lossy = rrule.unsupported({
		rrule = rrule_value,
		exdate = #ical.get_all(doc, range, "EXDATE") > 0,
		rdate = #ical.get_all(doc, range, "RDATE") > 0,
		overrides = #ical.events(doc) > 1,
	})

	event.block = {
		title = ical.text(ical.get(doc, range, "SUMMARY")) or "(untitled)",
		date = string.format("%04d-%02d-%02d", starts.year, starts.month, starts.day),
		start_min = utils.snap(starts.hour * 60 + starts.min, config.options.granularity),
		duration_min = math.max(
			config.options.granularity,
			utils.snap(duration_min, config.options.granularity)
		),
		notes = ical.text(ical.get(doc, range, "DESCRIPTION")) or "",
		-- A rule we could not model is kept on the server untouched; the block
		-- just shows as a one-off so we never imply we own the series.
		recurrence = recurrence,
	}

	return event
end

--------------------------------------------------------------------------
-- Writing
--------------------------------------------------------------------------

local function wall_clock(block, minutes)
	local date = utils.str_to_date(block.date)
	if not date then
		return nil
	end
	local instant = os.time({
		year = date.year,
		month = date.month,
		day = date.day,
		hour = math.floor(minutes / 60),
		min = minutes % 60,
		sec = 0,
	})
	local parts = os.date("*t", instant)
	return { year = parts.year, month = parts.month, day = parts.day, hour = parts.hour, min = parts.min, sec = 0 }
end

-- DTSTART/DTEND for a block. When the event already lives in a named zone on
-- the server, we keep that zone and convert into it, rather than quietly
-- rewriting someone's event to floating time.
function M.time_props(block, tzid)
	local starts = wall_clock(block, block.start_min)
	local ends = wall_clock(block, block.start_min + block.duration_min)
	if not starts or not ends then
		return nil
	end

	if tzid and tz.zone_exists(tzid) then
		local function into_zone(dt)
			local utc = tz.local_to_utc(dt)
			return tz.utc_to_zoned(utc, tzid)
		end
		local params = ";TZID=" .. tzid
		return {
			dtstart = { value = ical.format_datetime(into_zone(starts)), params = params, raw = true },
			dtend = { value = ical.format_datetime(into_zone(ends)), params = params, raw = true },
		}
	end

	return {
		dtstart = { value = ical.format_datetime(starts), params = "", raw = true },
		dtend = { value = ical.format_datetime(ends), params = "", raw = true },
	}
end

function M.uid_for(block)
	return block.id .. "@bloocky.nvim"
end

function M.href_for(block)
	return M.uid_for(block) .. ".ics"
end

-- A brand new event. Only for blocks bloocky is creating: there is no server
-- payload to preserve, so building from scratch loses nothing.
function M.to_ical(block)
	local times = M.time_props(block, nil)
	if not times then
		return nil, "block has an unusable date: " .. tostring(block.date)
	end
	return ical.build({
		uid = M.uid_for(block),
		dtstamp = tz.now_utc_stamp(),
		dtstart = times.dtstart.value,
		dtstart_params = times.dtstart.params,
		dtend = times.dtend.value,
		dtend_params = times.dtend.params,
		summary = block.title,
		description = block.notes,
		rrule = rrule.to_rrule(block.recurrence),
	})
end

-- The properties to overwrite on an event that already exists remotely.
--
-- When `lossy` is set the event carries recurrence bloocky cannot model, so
-- only the text is editable. Writing DTSTART or RRULE in that case would
-- flatten a rule we never understood.
function M.patch_changes(block, opts)
	opts = opts or {}
	local changes = {
		SUMMARY = block.title,
		DESCRIPTION = (block.notes ~= nil and block.notes ~= "") and block.notes or false,
	}
	if opts.lossy then
		return changes
	end

	local times = M.time_props(block, opts.tzid)
	if times then
		changes.DTSTART = times.dtstart
		changes.DTEND = times.dtend
		-- DURATION and DTEND are mutually exclusive; we always write DTEND.
		changes.DURATION = false
	end
	changes.RRULE = rrule.to_rrule(block.recurrence) and { value = rrule.to_rrule(block.recurrence), raw = true }
		or false
	return changes
end

return M
