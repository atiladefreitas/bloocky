-- RFC 5545 (iCalendar) reading and — the part that matters — patching.
--
-- The patching bias is deliberate. A bloocky block is a deliberate subset of
-- what a calendar event can hold: no attendees, no alarms, no per-occurrence
-- overrides, no INTERVAL. Serializing a block into a fresh VEVENT would
-- therefore silently delete everything it cannot represent — on a shared
-- invitation, that is other people's data. So we keep the server's own bytes
-- and replace only the properties the user actually edited.

local M = {}

--------------------------------------------------------------------------
-- Folding — RFC 5545 §3.1
--------------------------------------------------------------------------

-- A continuation line is any line beginning with a space or tab; the leading
-- whitespace character is part of the fold, not of the value.
function M.unfold(text)
	return (text:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n[ \t]", ""))
end

-- A UTF-8 continuation byte is 10xxxxxx. Folding mid-character would corrupt
-- the value, so back off to the start of the character.
local function is_char_start(byte)
	return byte < 0x80 or byte >= 0xC0
end

-- Lines SHOULD NOT exceed 75 octets excluding the line break.
function M.fold(line)
	if #line <= 75 then
		return line
	end
	local out, i, limit = {}, 1, 75
	while i <= #line do
		local stop = math.min(i + limit, #line + 1)
		if stop <= #line then
			while stop > i + 1 and not is_char_start(line:byte(stop)) do
				stop = stop - 1
			end
		end
		table.insert(out, line:sub(i, stop - 1))
		i = stop
		limit = 74 -- continuation lines spend one octet on the leading space
	end
	return table.concat(out, "\r\n ")
end

--------------------------------------------------------------------------
-- TEXT escaping — RFC 5545 §3.3.11
--------------------------------------------------------------------------

local UNESCAPE = { ["\\"] = "\\", [";"] = ";", [","] = ",", n = "\n", N = "\n" }

function M.unescape(value)
	return (value:gsub("\\(.)", function(char)
		return UNESCAPE[char] or ("\\" .. char)
	end))
end

local ESCAPE = { ["\\"] = "\\\\", [";"] = "\\;", [","] = "\\,", ["\n"] = "\\n" }

function M.escape(value)
	-- One pass over a character class, so an escaped backslash is not then
	-- re-escaped by a later substitution.
	return (value:gsub("\r\n", "\n"):gsub("[\\;,\n]", ESCAPE))
end

--------------------------------------------------------------------------
-- Content lines — RFC 5545 §3.1
--------------------------------------------------------------------------

-- NAME;PARAM=value;OTHER="quoted:value":VALUE
--
-- `params_raw` is kept verbatim so a patched property can be re-emitted with
-- its parameters byte for byte.
function M.parse_line(line)
	local colon, quoted = nil, false
	for i = 1, #line do
		local char = line:sub(i, i)
		if char == '"' then
			quoted = not quoted
		elseif char == ":" and not quoted then
			colon = i
			break
		end
	end
	if not colon then
		return nil
	end

	local head = line:sub(1, colon - 1)
	local semi = head:find(";", 1, true)
	local name = (semi and head:sub(1, semi - 1) or head):upper()
	local params_raw = semi and head:sub(semi) or ""

	local params = {}
	for key, value in params_raw:gmatch(";([^=;]+)=([^;]*)") do
		params[key:upper()] = (value:gsub('^"(.*)"$', "%1"))
	end

	return { name = name, params = params, params_raw = params_raw, value = line:sub(colon + 1) }
end

local function render_line(name, change, existing)
	if type(change) == "table" then
		local params = change.params or (existing and existing.params_raw) or ""
		local value = change.raw and change.value or M.escape(change.value)
		return name .. params .. ":" .. value
	end
	return name .. (existing and existing.params_raw or "") .. ":" .. M.escape(change)
end

--------------------------------------------------------------------------
-- Documents
--------------------------------------------------------------------------

function M.parse(text)
	local lines = {}
	for line in M.unfold(text):gmatch("[^\n]+") do
		if line:match("%S") then
			table.insert(lines, line)
		end
	end
	return { lines = lines }
end

function M.serialize(doc)
	local out = {}
	for _, line in ipairs(doc.lines) do
		table.insert(out, M.fold(line))
	end
	return table.concat(out, "\r\n") .. "\r\n"
end

-- Every VEVENT in the document, as inclusive { s, e } line ranges. Nested
-- components (a VALARM inside the event) are stepped over, not returned.
function M.events(doc)
	local out, i = {}, 1
	while i <= #doc.lines do
		if doc.lines[i]:upper():match("^BEGIN:VEVENT%s*$") then
			local depth, j = 1, i + 1
			while j <= #doc.lines and depth > 0 do
				local line = doc.lines[j]:upper()
				if line:match("^BEGIN:") then
					depth = depth + 1
				elseif line:match("^END:") then
					depth = depth - 1
				end
				j = j + 1
			end
			table.insert(out, { s = i, e = j - 1 })
			i = j
		else
			i = i + 1
		end
	end
	return out
end

-- Walk only this component's own properties. Without the depth check a VALARM's
-- DESCRIPTION would masquerade as the event's.
local function each_prop(doc, range, fn)
	local depth = 0
	for i = range.s + 1, range.e - 1 do
		local line = doc.lines[i]
		local upper = line:upper()
		if upper:match("^BEGIN:") then
			depth = depth + 1
		elseif upper:match("^END:") then
			depth = depth - 1
		elseif depth == 0 then
			fn(line, i)
		end
	end
end

function M.get(doc, range, name)
	local want, found = name:upper(), nil
	each_prop(doc, range, function(line, i)
		if not found then
			local prop = M.parse_line(line)
			if prop and prop.name == want then
				prop.index = i
				found = prop
			end
		end
	end)
	return found
end

function M.get_all(doc, range, name)
	local want, out = name:upper(), {}
	each_prop(doc, range, function(line, i)
		local prop = M.parse_line(line)
		if prop and prop.name == want then
			prop.index = i
			table.insert(out, prop)
		end
	end)
	return out
end

-- The master of a recurring series is the VEVENT without a RECURRENCE-ID;
-- the others are per-occurrence overrides.
function M.master(doc)
	local events = M.events(doc)
	for _, range in ipairs(events) do
		if not M.get(doc, range, "RECURRENCE-ID") then
			return range
		end
	end
	return events[1]
end

function M.text(prop)
	return prop and M.unescape(prop.value) or nil
end

--------------------------------------------------------------------------
-- Patching
--------------------------------------------------------------------------

-- Replace named properties on the master VEVENT and return the new document
-- text. Everything else — unknown properties, VALARMs, ATTENDEEs, the
-- VTIMEZONE, per-occurrence overrides — is carried through untouched.
--
-- A change is either a string (escaped as TEXT, existing parameters kept),
-- `false` (remove the property), or a table:
--     { value = "20260813T120000Z", params = ";TZID=Europe/Lisbon", raw = true }
-- `raw` skips TEXT escaping, which DATE-TIME and RRULE values require.
function M.patch(text, changes)
	local doc = M.parse(text)
	local range = M.master(doc)
	if not range then
		return nil, "no VEVENT found"
	end

	local wanted = {}
	for name, change in pairs(changes) do
		wanted[name:upper()] = change
	end

	local out, seen, depth = {}, {}, 0
	for i = 1, range.s do
		table.insert(out, doc.lines[i])
	end

	for i = range.s + 1, range.e - 1 do
		local line = doc.lines[i]
		local upper = line:upper()
		if upper:match("^BEGIN:") then
			depth = depth + 1
			table.insert(out, line)
		elseif upper:match("^END:") then
			depth = depth - 1
			table.insert(out, line)
		elseif depth > 0 then
			table.insert(out, line)
		else
			local prop = M.parse_line(line)
			local change = prop and wanted[prop.name]
			if change == nil then
				table.insert(out, line)
			elseif not seen[prop.name] then
				-- Repeats of a replaced property are dropped, so patching a
				-- value can never leave a stale second copy behind.
				seen[prop.name] = true
				if change ~= false then
					table.insert(out, render_line(prop.name, change, prop))
				end
			end
		end
	end

	-- Properties the event did not already carry go in before END:VEVENT.
	local added = {}
	for name, change in pairs(wanted) do
		if not seen[name] and change ~= false then
			table.insert(added, name)
		end
	end
	table.sort(added) -- deterministic output, so tests and diffs are stable
	for _, name in ipairs(added) do
		table.insert(out, render_line(name, wanted[name]))
	end

	for i = range.e, #doc.lines do
		table.insert(out, doc.lines[i])
	end

	doc.lines = out
	return M.serialize(doc)
end

--------------------------------------------------------------------------
-- DATE-TIME and DURATION values
--------------------------------------------------------------------------

-- "20260813T120000Z" | "20260813T120000" | "20260813"
function M.parse_datetime(prop)
	if not prop then
		return nil
	end
	local value = prop.value
	local year, month, day = value:match("^(%d%d%d%d)(%d%d)(%d%d)")
	if not year then
		return nil
	end
	local hour, min, sec = value:match("T(%d%d)(%d%d)(%d%d)")
	return {
		year = tonumber(year),
		month = tonumber(month),
		day = tonumber(day),
		hour = tonumber(hour) or 0,
		min = tonumber(min) or 0,
		sec = tonumber(sec) or 0,
		utc = value:sub(-1) == "Z",
		date_only = hour == nil, -- VALUE=DATE, an all-day event
		tzid = prop.params and prop.params.TZID or nil,
	}
end

function M.format_datetime(dt, opts)
	opts = opts or {}
	if opts.date_only then
		return string.format("%04d%02d%02d", dt.year, dt.month, dt.day)
	end
	return string.format(
		"%04d%02d%02dT%02d%02d%02d%s",
		dt.year,
		dt.month,
		dt.day,
		dt.hour or 0,
		dt.min or 0,
		dt.sec or 0,
		opts.utc and "Z" or ""
	)
end

-- "PT1H30M", "P1D", "P2W" -> minutes. Used when an event carries DURATION
-- instead of DTEND.
function M.parse_duration(value)
	if type(value) ~= "string" then
		return nil
	end
	local sign, rest = value:match("^([+-]?)P(.+)$")
	if not rest then
		return nil
	end

	local weeks = rest:match("^(%d+)W$")
	local minutes
	if weeks then
		minutes = tonumber(weeks) * 7 * 24 * 60
	else
		local date_part, time_part = rest:match("^([^T]*)T?(.*)$")
		local days = date_part:match("(%d+)D")
		local hours = time_part:match("(%d+)H")
		local mins = time_part:match("(%d+)M")
		local secs = time_part:match("(%d+)S")
		if not (days or hours or mins or secs) then
			return nil
		end
		minutes = (tonumber(days) or 0) * 24 * 60
			+ (tonumber(hours) or 0) * 60
			+ (tonumber(mins) or 0)
			+ math.floor((tonumber(secs) or 0) / 60)
	end
	return sign == "-" and -minutes or minutes
end

--------------------------------------------------------------------------
-- Building a new event
--------------------------------------------------------------------------

-- Only for blocks bloocky is creating from scratch, where there is no server
-- payload to preserve. Never use this to rewrite an event that came from a
-- calendar — that is what patch() is for.
function M.build(event)
	local lines = {
		"BEGIN:VCALENDAR",
		"VERSION:2.0",
		"PRODID:-//bloocky.nvim//EN",
		"CALSCALE:GREGORIAN",
		"BEGIN:VEVENT",
		"UID:" .. event.uid,
		"DTSTAMP:" .. event.dtstamp,
	}

	local function add(name, value, raw)
		if value and value ~= "" then
			table.insert(lines, name .. ":" .. (raw and value or M.escape(value)))
		end
	end

	table.insert(lines, "DTSTART" .. (event.dtstart_params or "") .. ":" .. event.dtstart)
	table.insert(lines, "DTEND" .. (event.dtend_params or "") .. ":" .. event.dtend)
	add("SUMMARY", event.summary)
	add("DESCRIPTION", event.description)
	add("RRULE", event.rrule, true)
	if event.exdate and event.exdate ~= "" then
		table.insert(lines, "EXDATE;VALUE=DATE:" .. event.exdate)
	end

	table.insert(lines, "END:VEVENT")
	table.insert(lines, "END:VCALENDAR")
	return M.serialize({ lines = lines })
end

return M
