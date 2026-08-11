local M = {}

--------------------------------------------------------------------------
-- Date helpers — a date is a table { year, month, day }
--------------------------------------------------------------------------

M.MONTHS = {
	"January",
	"February",
	"March",
	"April",
	"May",
	"June",
	"July",
	"August",
	"September",
	"October",
	"November",
	"December",
}

M.MONTHS_SHORT = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- Indexed by os.date wday: 1 = Sunday .. 7 = Saturday
M.WDAYS_SHORT = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
M.WDAYS_LONG = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }

M.DAY_TOKENS = { sun = 1, mon = 2, tue = 3, wed = 4, thu = 5, fri = 6, sat = 7 }

function M.days_in_month(year, month)
	local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
	if month == 2 and (year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)) then
		return 29
	end
	return days[month]
end

function M.date_to_str(d)
	return string.format("%04d-%02d-%02d", d.year, d.month, d.day)
end

-- Accepts "YYYY-MM-DD" and "MM/DD/YYYY"
function M.str_to_date(s)
	if type(s) ~= "string" then
		return nil
	end
	local y, m, d = s:match("^(%d%d%d%d)-(%d%d?)-(%d%d?)$")
	if not y then
		m, d, y = s:match("^(%d%d?)/(%d%d?)/(%d%d%d%d)$")
	end
	if not y then
		return nil
	end
	y, m, d = tonumber(y), tonumber(m), tonumber(d)
	if m < 1 or m > 12 or d < 1 or d > M.days_in_month(y, m) then
		return nil
	end
	return { year = y, month = m, day = d }
end

-- Noon avoids DST edge cases when adding whole days
function M.date_to_time(d)
	return os.time({ year = d.year, month = d.month, day = d.day, hour = 12 })
end

function M.time_to_date(t)
	local dt = os.date("*t", t)
	return { year = dt.year, month = dt.month, day = dt.day }
end

function M.today()
	return M.time_to_date(os.time())
end

function M.add_days(d, n)
	return M.time_to_date(M.date_to_time(d) + n * 86400)
end

function M.add_months(d, n)
	local m = d.month + n
	local y = d.year + math.floor((m - 1) / 12)
	m = ((m - 1) % 12) + 1
	return { year = y, month = m, day = math.min(d.day, M.days_in_month(y, m)) }
end

function M.same_day(a, b)
	return a.year == b.year and a.month == b.month and a.day == b.day
end

-- os.date convention: 1 = Sunday .. 7 = Saturday
function M.wday(d)
	return os.date("*t", M.date_to_time(d)).wday
end

function M.week_start_of(d, week_start)
	local first = (week_start == "monday") and 2 or 1
	local offset = (M.wday(d) - first) % 7
	return M.add_days(d, -offset)
end

--------------------------------------------------------------------------
-- Time helpers — times are minutes from midnight
--------------------------------------------------------------------------

-- "9", "09:30", "14:00" -> minutes
function M.parse_hhmm(s)
	if type(s) ~= "string" then
		return nil
	end
	local h, mi = s:match("^(%d%d?):(%d%d)$")
	if not h then
		h, mi = s:match("^(%d%d?)$"), "0"
	end
	if not h then
		return nil
	end
	h, mi = tonumber(h), tonumber(mi)
	if h > 23 or mi > 59 then
		return nil
	end
	return h * 60 + mi
end

function M.format_hhmm(min)
	return string.format("%02d:%02d", math.floor(min / 60), min % 60)
end

-- "1h30m", "1.5h", "45m", "90" (minutes) -> minutes
function M.parse_duration(s)
	if type(s) ~= "string" or s == "" then
		return nil
	end
	s = s:lower():gsub("%s", "")
	local total, matched = 0, false
	local h = s:match("(%d+%.?%d*)h")
	local mi = s:match("(%d+)m")
	if h then
		total = total + tonumber(h) * 60
		matched = true
	end
	if mi then
		total = total + tonumber(mi)
		matched = true
	end
	if not matched then
		total = tonumber(s)
		if not total then
			return nil
		end
	end
	total = math.floor(total + 0.5)
	if total <= 0 then
		return nil
	end
	return total
end

function M.format_duration(min)
	local h = math.floor(min / 60)
	local mi = min % 60
	if h > 0 and mi > 0 then
		return h .. "h" .. mi .. "m"
	end
	if h > 0 then
		return h .. "h"
	end
	return mi .. "m"
end

function M.snap(min, granularity)
	return math.floor(min / granularity + 0.5) * granularity
end

-- Fit the hours [h0, h1) into `avail` lines so the whole day is always visible.
-- Roomy: one line per hour plus a divider between them. Tighter: drop the
-- dividers. Tighter still: group several hours onto one line.
-- With `fill`, the rows left over are handed back to the slots so the grid
-- spans exactly `avail` lines instead of stopping short.
-- Returns rows of { s, e, label, lines, div } — minutes covered, gutter label,
-- how many lines the slot takes, and whether a divider line follows.
function M.hour_layout(h0, h1, avail, fill)
	local hours = math.max(1, h1 - h0)
	avail = math.max(1, avail)
	local step = math.max(1, math.ceil(hours / avail))
	local rows = math.ceil(hours / step)
	local dividers = rows * 2 - 1 <= avail

	local heights
	if fill then
		local spare = avail - (dividers and (rows * 2 - 1) or rows)
		heights = M.share(rows + math.max(0, spare), rows)
	end

	local out, h, i = {}, h0, 0
	while h < h1 do
		local e = math.min(h + step, h1)
		i = i + 1
		table.insert(out, {
			s = h * 60,
			e = e * 60,
			label = (e - h == 1) and string.format(" %02d:00 ", h) or string.format(" %02d-%02d ", h, e),
			lines = heights and heights[i] or 1,
			div = dividers and e < h1,
		})
		h = e
	end
	return out
end

--------------------------------------------------------------------------
-- Text helpers — widths are display cells, positions are byte offsets
--------------------------------------------------------------------------

function M.dw(s)
	return vim.fn.strdisplaywidth(s)
end

-- Split `total` cells over `n` parts. What does not divide evenly is spread
-- across the parts instead of piling up at the end, so a grid built from them
-- covers `total` exactly while staying visually regular.
function M.share(total, n)
	local base = math.floor(total / n)
	local rem = total - base * n
	local out = {}
	for i = 1, n do
		out[i] = base + (math.floor(i * rem / n) - math.floor((i - 1) * rem / n))
	end
	return out
end

function M.truncate(s, width)
	if width <= 0 then
		return ""
	end
	if M.dw(s) <= width then
		return s
	end
	local out, w = {}, 0
	for _, ch in ipairs(vim.fn.split(s, "\\zs")) do
		local cw = M.dw(ch)
		if w + cw > width - 1 then
			break
		end
		table.insert(out, ch)
		w = w + cw
	end
	return table.concat(out) .. "…"
end

-- Truncate and right-pad to exactly `width` display cells
function M.fit(s, width)
	s = M.truncate(s, width)
	return s .. string.rep(" ", width - M.dw(s))
end

function M.center(s, width)
	s = M.truncate(s, width)
	local w = M.dw(s)
	local left = math.floor((width - w) / 2)
	return string.rep(" ", left) .. s .. string.rep(" ", width - w - left)
end

-- Build a line from { text, hl_group?, priority? } chunks.
-- Returns the line, its highlight ranges and the byte span of each chunk.
function M.compose(chunks)
	local parts, hls, spans = {}, {}, {}
	local byte = 0
	for i, chunk in ipairs(chunks) do
		local text = chunk[1] or ""
		table.insert(parts, text)
		spans[i] = { s = byte, e = byte + #text }
		if chunk[2] then
			table.insert(hls, { s = byte, e = byte + #text, group = chunk[2], prio = chunk[3] })
		end
		byte = byte + #text
	end
	return table.concat(parts), hls, spans
end

return M
