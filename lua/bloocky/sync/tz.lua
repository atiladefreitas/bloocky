-- Bridging bloocky's floating local time and a calendar's absolute instants.
--
-- A block is wall-clock: `date` + `start_min`, read in whatever zone the
-- device is in. A calendar event is a point on the timeline. Every conversion
-- between the two lives here, because getting it wrong shifts someone's
-- meeting by an hour twice a year and nowhere else shows the seam.

local M = {}

--------------------------------------------------------------------------
-- Offsets
--------------------------------------------------------------------------

-- Never set `isdst`. Lua passes an absent field to mktime as -1, meaning
-- "work out whether DST applies"; passing false asserts standard time, which
-- is an hour wrong for any date inside DST — and an hour wrong at 23:59
-- moves the date. Leaving it out is what makes these conversions correct.
local function fields_of(dt)
	return {
		year = dt.year,
		month = dt.month,
		day = dt.day,
		hour = dt.hour or 0,
		min = dt.min or 0,
		sec = dt.sec or 0,
	}
end

-- Seconds that local time is ahead of UTC at a given instant. Derived rather
-- than looked up: Lua has no tzdata access, but rendering the instant as a UTC
-- wall clock and then reading that clock back as local time gives the gap.
function M.offset_at(timestamp)
	local utc = os.date("!*t", timestamp)
	return os.difftime(timestamp, os.time(fields_of(utc)))
end

-- os.time() reads its fields as local time; this reads them as UTC.
-- The offset depends on the instant being solved for, so we take one
-- correction step from the local-interpretation guess.
function M.timegm(dt)
	local guess = os.time(fields_of(dt))
	return guess + M.offset_at(guess)
end

--------------------------------------------------------------------------
-- Conversions
--------------------------------------------------------------------------

local function to_parts(t)
	return { year = t.year, month = t.month, day = t.day, hour = t.hour, min = t.min, sec = t.sec }
end

function M.utc_to_local(dt)
	return to_parts(os.date("*t", M.timegm(dt)))
end

function M.local_to_utc(dt)
	return to_parts(os.date("!*t", os.time(fields_of(dt))))
end

--------------------------------------------------------------------------
-- Blocks <-> instants
--------------------------------------------------------------------------

-- "2026-08-13" + 540 -> a UTC date-time table
function M.block_to_utc(date_str, start_min)
	local year, month, day = date_str:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
	if not year then
		return nil
	end
	return M.local_to_utc({
		year = tonumber(year),
		month = tonumber(month),
		day = tonumber(day),
		hour = math.floor(start_min / 60),
		min = start_min % 60,
		sec = 0,
	})
end

-- A UTC date-time table -> "2026-08-13", 540
function M.utc_to_block(dt)
	local loc = M.utc_to_local(dt)
	return string.format("%04d-%02d-%02d", loc.year, loc.month, loc.day), loc.hour * 60 + loc.min
end

-- A wall-clock date-time table -> "2026-08-13", 540. Used for events that
-- carry a TZID we cannot resolve: the wall-clock reading is taken at face
-- value, which is exactly bloocky's own model.
function M.floating_to_block(dt)
	return string.format("%04d-%02d-%02d", dt.year, dt.month, dt.day), (dt.hour or 0) * 60 + (dt.min or 0)
end

function M.now_utc_stamp()
	local now = os.date("!*t")
	return string.format(
		"%04d%02d%02dT%02d%02d%02dZ",
		now.year,
		now.month,
		now.day,
		now.hour,
		now.min,
		now.sec
	)
end

--------------------------------------------------------------------------
-- Other people's zones
--------------------------------------------------------------------------

-- An invitation carries TZID=America/New_York, and we are not in New York.
-- Rather than parse the VTIMEZONE component's DST rules out of the payload,
-- borrow the system tzdata: libc already knows every zone and every historical
-- rule, and honours $TZ.
--
-- This does mutate a process-global for the duration of `fn`. That is safe
-- here — Lua is single threaded, the window is a few arithmetic operations,
-- and TZ is restored even if `fn` throws.
local ZONEINFO = "/usr/share/zoneinfo/"

local zone_cache = {}

function M.zone_exists(zone)
	if type(zone) ~= "string" or zone == "" or zone:find("%.%.") then
		return false
	end
	if zone_cache[zone] == nil then
		local stat = vim.uv.fs_stat(ZONEINFO .. zone)
		zone_cache[zone] = stat ~= nil and stat.type == "file"
	end
	return zone_cache[zone]
end

-- Returns nil if the zone is unknown to the system. That matters: setting TZ
-- to a name libc cannot resolve silently yields UTC, which would put a meeting
-- at the wrong hour with no error to notice.
function M.with_zone(zone, fn)
	if not M.zone_exists(zone) then
		return nil, "unknown timezone: " .. tostring(zone)
	end
	local previous = vim.uv.os_getenv("TZ")
	vim.uv.os_setenv("TZ", zone)
	os.time() -- force libc to re-read TZ

	local ok, result = pcall(fn)

	if previous then
		vim.uv.os_setenv("TZ", previous)
	else
		vim.uv.os_unsetenv("TZ")
	end
	os.time()

	if not ok then
		error(result, 0)
	end
	return result, nil
end

-- A wall clock in `zone` -> the same instant as a UTC wall clock.
function M.zoned_to_utc(dt, zone)
	return M.with_zone(zone, function()
		return M.local_to_utc(dt)
	end)
end

-- A UTC wall clock -> the same instant as a wall clock in `zone`.
function M.utc_to_zoned(dt, zone)
	return M.with_zone(zone, function()
		return M.utc_to_local(dt)
	end)
end

--------------------------------------------------------------------------
-- Which zone are we in
--------------------------------------------------------------------------

local detected = nil

-- The IANA name, needed when pushing a recurring event: a weekly 09:00 block
-- emitted as a UTC instant would drift an hour across a DST boundary, so the
-- rule has to be anchored to a named zone instead.
function M.local_zone()
	if detected ~= nil then
		return detected or nil
	end

	local env = os.getenv("TZ")
	if env and env ~= "" and env:match("^[%w_]+/[%w_+%-/]+$") then
		detected = env
		return detected
	end

	local file = io.open("/etc/timezone", "r")
	if file then
		local name = file:read("*l")
		file:close()
		if name and name:match("^[%w_]+/") then
			detected = name
			return detected
		end
	end

	-- /etc/localtime is usually a symlink into the zoneinfo tree, so the zone
	-- name is the tail of the link target.
	local link = vim.uv.fs_readlink("/etc/localtime")
	if link then
		local name = link:match("zoneinfo/(.+)$")
		if name then
			detected = name
			return detected
		end
	end

	detected = false -- cache the failure; the filesystem will not change mid-session
	return nil
end

-- Test seam, and the escape hatch for `sync.timezone`.
function M.set_local_zone(name)
	detected = name or false
end

return M
