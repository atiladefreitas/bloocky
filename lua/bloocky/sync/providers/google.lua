-- Google Calendar, via the REST v3 API.
--
-- Not via Google's CalDAV bridge, which would have let us reuse caldav.lua
-- almost entirely. That was tested against a live account and rejected: with a
-- token carrying only `calendar.events` + `calendar.calendarlist.readonly`,
-- every CalDAV request returns 403 insufficientPermissions, while the same
-- token drives REST fine. The bridge wants the broad `auth/calendar` scope —
-- the one that can permanently delete calendars — so it is out. See
-- docs/two-way-sync.md.
--
-- Events are translated into iCalendar text on the way in, so everything
-- downstream (recurrence modelling, lossiness detection, timezone handling in
-- mapper.lua) stays on one code path rather than growing a second, subtly
-- different implementation for JSON.

local async = require("bloocky.sync.async")
local http = require("bloocky.sync.http")
local ical = require("bloocky.sync.ical")
local oauth = require("bloocky.sync.oauth")
local rrule = require("bloocky.sync.rrule")
local tz = require("bloocky.sync.tz")

local M = {}

M.API = "https://www.googleapis.com/calendar/v3"

--------------------------------------------------------------------------
-- Transport
--------------------------------------------------------------------------

M.transport = nil

-- Awaitable; must run inside async.run.
local function call(account, opts)
	local token, token_err = oauth.access_token(account)
	if not token then
		return nil, token_err
	end
	opts.bearer = token
	opts.headers = opts.headers or {}
	opts.headers["User-Agent"] = "bloocky.nvim"
	if opts.body then
		opts.headers["Content-Type"] = "application/json"
	end

	local err, res = async.await(function(cb)
		(M.transport or http.request)(opts, function(request_err, response)
			cb(request_err, response)
		end)
	end)
	if err then
		return nil, err
	end

	local decoded = nil
	if res.body and res.body ~= "" then
		local ok, value = pcall(vim.json.decode, res.body)
		decoded = ok and value or nil
	end
	-- Google reports failures in the body; surface its own wording, which is
	-- far more useful than the status code alone.
	if res.status >= 400 then
		local message = decoded and decoded.error and (decoded.error.message or decoded.error) or ("HTTP " .. res.status)
		return { status = res.status, error = http.redact(tostring(message)) }, nil
	end
	return { status = res.status, json = decoded, etag = res.headers and res.headers.etag }, nil
end

local function query(params)
	local parts, keys = {}, vim.tbl_keys(params)
	table.sort(keys)
	for _, key in ipairs(keys) do
		table.insert(parts, oauth.encode(key) .. "=" .. oauth.encode(params[key]))
	end
	return #parts > 0 and ("?" .. table.concat(parts, "&")) or ""
end

local function events_url(calendar_id, suffix, params)
	return M.API
		.. "/calendars/"
		.. oauth.encode(calendar_id)
		.. "/events"
		.. (suffix and ("/" .. oauth.encode(suffix)) or "")
		.. (params and query(params) or "")
end

--------------------------------------------------------------------------
-- JSON <-> iCalendar
--------------------------------------------------------------------------

-- "2026-08-13T09:00:00-03:00" -> a DTSTART value plus its parameters.
-- Google always sends an offset, so the instant is unambiguous; we hand it on
-- as UTC and let mapper.lua put it on the local wall clock.
local function datetime_property(slot)
	if not slot then
		return nil
	end
	if slot.date then
		return { params = ";VALUE=DATE", value = (slot.date:gsub("%-", "")) }
	end
	local stamp = slot.dateTime
	if not stamp then
		return nil
	end

	local year, month, day, hour, min, sec = stamp:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	if not year then
		return nil
	end
	local sign, oh, om = stamp:match("([%+%-])(%d%d):(%d%d)$")

	local dt = {
		year = tonumber(year),
		month = tonumber(month),
		day = tonumber(day),
		hour = tonumber(hour),
		min = tonumber(min),
		sec = tonumber(sec),
	}
	if sign then
		-- Shift to UTC by the offset Google gave us.
		local offset = (tonumber(oh) * 60 + tonumber(om)) * (sign == "-" and -1 or 1)
		local instant = tz.timegm(dt) - offset * 60
		local utc = os.date("!*t", instant)
		dt = { year = utc.year, month = utc.month, day = utc.day, hour = utc.hour, min = utc.min, sec = utc.sec }
	end
	return { params = "", value = ical.format_datetime(dt, { utc = sign ~= nil }) }
end

-- A server field lands on a single iCalendar content line. The iCalUID is
-- chosen by whoever *created* the event — anyone who can invite you — so a
-- CR/LF smuggled into one must not become an injected property downstream.
local function oneline(value)
	return (tostring(value):gsub("[\r\n]+", " "))
end

-- Build a VEVENT so the rest of the engine sees the same shape it gets from a
-- CalDAV server. `recurrence` carries real RRULE/EXDATE/RDATE lines, so
-- rrule.unsupported works on it unchanged.
function M.to_ical(event)
	local lines = {
		"BEGIN:VCALENDAR",
		"VERSION:2.0",
		"PRODID:-//bloocky.nvim//google//EN",
		"BEGIN:VEVENT",
		"UID:" .. oneline(event.iCalUID or event.id or ""),
		"DTSTAMP:" .. (tz.now_utc_stamp()),
	}

	local starts = datetime_property(event.start)
	local ends = datetime_property(event["end"])
	if not starts then
		return nil
	end
	table.insert(lines, "DTSTART" .. starts.params .. ":" .. starts.value)
	if ends then
		table.insert(lines, "DTEND" .. ends.params .. ":" .. ends.value)
	end

	if event.summary then
		table.insert(lines, "SUMMARY:" .. ical.escape(event.summary))
	end
	if event.description then
		table.insert(lines, "DESCRIPTION:" .. ical.escape(event.description))
	end
	if event.status then
		table.insert(lines, "STATUS:" .. oneline(event.status:upper()))
	end
	if event.transparency then
		table.insert(lines, "TRANSP:" .. oneline(event.transparency:upper()))
	end
	if event.recurringEventId then
		-- An instance carrying its own overrides; treated as a per-occurrence
		-- exception, which bloocky cannot model.
		table.insert(lines, "RECURRENCE-ID:" .. (datetime_property(event.originalStartTime) or starts).value)
	end
	for _, rule in ipairs(event.recurrence or {}) do
		table.insert(lines, oneline(rule))
	end

	table.insert(lines, "END:VEVENT")
	table.insert(lines, "END:VCALENDAR")
	return ical.serialize({ lines = lines })
end

-- A block -> the JSON body Google wants. Times go up as floating wall clock
-- paired with an explicit IANA zone, which is the closest Google offers to
-- bloocky's model: the REST API has no floating time, so the local zone is
-- named rather than an offset baked in.
function M.event_body(block, opts)
	opts = opts or {}
	-- nil means "work it out", false means "there isn't one" — the two need to
	-- stay distinguishable or the offset fallback can never be reached.
	local zone = opts.timezone
	if zone == nil then
		zone = tz.local_zone()
	end
	local function slot(minutes)
		local date = require("bloocky.utils").str_to_date(block.date)
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
		local stamp = string.format(
			"%04d-%02d-%02dT%02d:%02d:00",
			parts.year,
			parts.month,
			parts.day,
			parts.hour,
			parts.min
		)
		-- Without a zone Google rejects a bare local time, so fall back to the
		-- UTC offset for this instant.
		if zone then
			return { dateTime = stamp, timeZone = zone }
		end
		local offset = tz.offset_at(instant)
		local sign = offset < 0 and "-" or "+"
		offset = math.abs(offset)
		return {
			dateTime = ("%s%s%02d:%02d"):format(stamp, sign, math.floor(offset / 3600), math.floor(offset % 3600 / 60)),
		}
	end

	local body = {
		summary = block.title,
		description = (block.notes ~= nil and block.notes ~= "") and block.notes or nil,
		start = slot(block.start_min),
		["end"] = slot(block.start_min + block.duration_min),
	}
	if not (body.start and body["end"]) then
		return nil, "block has an unusable date: " .. tostring(block.date)
	end

	-- An explicit empty list is how a recurrence is cleared; omitting the key
	-- would leave the old rule in place on a PATCH.
	local rule = rrule.to_rrule(block.recurrence)
	body.recurrence = rule and { "RRULE:" .. rule } or {}
	return body, nil
end

-- Neovim encodes an empty Lua table as `{}`, but Google needs `[]` to clear a
-- recurrence. `recurrence` is the only empty collection we ever send, so this
-- stays a targeted fix rather than a general encoder.
function M.encode(body)
	return (vim.json.encode(body):gsub('"recurrence":%s*{}', '"recurrence":[]'))
end

--------------------------------------------------------------------------
-- The provider interface
--------------------------------------------------------------------------

local WRITABLE = { owner = true, writer = true }

function M.discover(account)
	local res, err = call(account, { url = M.API .. "/users/me/calendarList", method = "GET" })
	if not res then
		return nil, err
	end
	if res.error then
		return nil, "could not list calendars: " .. res.error
	end

	local out = {}
	for _, item in ipairs((res.json or {}).items or {}) do
		if not item.deleted then
			table.insert(out, {
				href = item.id,
				name = item.summary or item.id,
				-- reader and freeBusyReader cannot be written to; saying so up
				-- front beats a confusing 403 mid-sync.
				readonly = not WRITABLE[item.accessRole or ""],
			})
		end
	end
	return out, nil
end

-- Google ties a syncToken to the exact query it came from, so timeMin has to
-- stay byte-identical across incremental calls. It is therefore stored with
-- the cursor rather than recomputed from the clock each run.
local function window_start(window)
	-- "20260714T120000Z" -> "2026-07-14T12:00:00Z"
	local y, mo, d, h, mi, s = tostring(window.start):match("(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)")
	if not y then
		return nil
	end
	return ("%s-%s-%sT%s:%s:%sZ"):format(y, mo, d, h, mi, s)
end

local function collect(account, calendar_id, params, cursor_time_min)
	local changed, removed = {}, {}
	local page, token = nil, nil

	repeat
		local request = vim.tbl_extend("force", params, page and { pageToken = page } or {})
		local res, err = call(account, { url = events_url(calendar_id, nil, request), method = "GET" })
		if not res then
			return nil, err
		end
		if res.status == 410 then
			-- The syncToken expired. Starting over is correct and self-healing.
			return nil, "resync"
		end
		if res.error then
			return nil, res.error
		end

		local body = res.json or {}
		for _, item in ipairs(body.items or {}) do
			if item.status == "cancelled" then
				table.insert(removed, item.id)
			else
				local text = M.to_ical(item)
				if text then
					table.insert(changed, { href = item.id, etag = item.etag, data = text })
				end
			end
		end
		page = body.nextPageToken
		token = body.nextSyncToken or token
	until not page

	return { changed = changed, removed = removed, cursor = { token = token, time_min = cursor_time_min } }, nil
end

function M.fetch(account, calendar, cursor, window)
	local calendar_id = calendar.href

	if type(cursor) == "table" and cursor.token then
		local result, err = collect(account, calendar_id, {
			syncToken = cursor.token,
			singleEvents = "false",
			maxResults = "250",
		}, cursor.time_min)
		if err ~= "resync" then
			return result, err
		end
	end

	local time_min = window_start(window)
	return collect(account, calendar_id, {
		timeMin = time_min,
		singleEvents = "false",
		maxResults = "250",
	}, time_min)
end

function M.create_event(account, calendar, block)
	local body, build_err = M.event_body(block)
	if not body then
		return nil, build_err
	end

	local res, err = call(account, {
		url = events_url(calendar.href),
		method = "POST",
		body = M.encode(body),
	})
	if not res then
		return nil, err
	end
	if res.error then
		return nil, res.error
	end

	local created = res.json or {}
	return {
		href = created.id,
		uid = created.iCalUID or created.id,
		etag = created.etag,
		raw = M.to_ical(created),
	}, nil
end

function M.update_event(account, mapping, block)
	local changes
	if mapping.lossy or mapping.all_day then
		-- Only the text is ours to change: the recurrence is something we
		-- could not model, so its timing must be left exactly as it is.
		changes = { summary = block.title }
		if block.notes and block.notes ~= "" then
			changes.description = block.notes
		end
	else
		local body, build_err = M.event_body(block)
		if not body then
			return nil, build_err
		end
		changes = body
	end

	-- PATCH, not PUT: Google merges server-side, so attendees, conferencing
	-- data and anything else bloocky knows nothing about survive untouched.
	local res, err = call(account, {
		url = events_url(mapping.calendar or "primary", mapping.href),
		method = "PATCH",
		body = M.encode(changes),
		headers = mapping.etag and { ["If-Match"] = mapping.etag } or nil,
	})
	if not res then
		return nil, err
	end
	if res.status == 412 then
		return { conflict = true }, nil
	end
	if res.error then
		return nil, res.error
	end

	local updated = res.json or {}
	return { etag = updated.etag, raw = M.to_ical(updated) }, nil
end

function M.delete_event(account, tombstone)
	local res, err = call(account, {
		url = events_url(tombstone.calendar or "primary", tombstone.href),
		method = "DELETE",
		headers = tombstone.etag and { ["If-Match"] = tombstone.etag } or nil,
	})
	if not res then
		return nil, err
	end
	if res.status == 412 then
		return { conflict = true }, nil
	end
	-- Already gone is the desired state.
	if res.status == 404 or res.status == 410 then
		return { missing = true }, nil
	end
	if res.error then
		return nil, res.error
	end
	return { status = res.status }, nil
end

return M
