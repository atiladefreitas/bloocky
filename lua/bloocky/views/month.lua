local utils = require("bloocky.utils")
local state = require("bloocky.state")
local dooing = require("bloocky.dooing")
local highlights = require("bloocky.highlights")

local M = {}

function M.render(ctx)
	local cfg = ctx.config
	-- 6 "│" separators between the 7 day cells
	local mw = math.floor((ctx.width - 6) / 7)
	local width = mw * 7 + 6

	local lines, hls = {}, {}
	local meta = { width = width }

	local function push(chunks)
		local line, line_hls, spans = utils.compose(chunks)
		table.insert(lines, line)
		local lnum = #lines - 1
		for _, h in ipairs(line_hls) do
			h.line = lnum
			table.insert(hls, h)
		end
		return lnum, spans
	end

	local cur = ctx.cursor.date
	local first = { year = cur.year, month = cur.month, day = 1 }
	local grid_start = utils.week_start_of(first, cfg.week_start)
	local last = { year = cur.year, month = cur.month, day = utils.days_in_month(cur.year, cur.month) }
	local span_days = math.floor((utils.date_to_time(last) - utils.date_to_time(grid_start)) / 86400) + 1
	local weeks = math.ceil(span_days / 7)

	-- header (2 lines) + week separators between rows
	local avail = ctx.height - 2 - (weeks - 1)
	local cell_h = math.max(2, math.min(6, math.floor(avail / weeks)))

	-- Weekday header
	local first_wd = (cfg.week_start == "monday") and 2 or 1
	local header = {}
	for i = 0, 6 do
		local wd = ((first_wd - 1 + i) % 7) + 1
		if i > 0 then
			table.insert(header, { "│", "BloockyGrid" })
		end
		table.insert(header, { utils.center(utils.WDAYS_SHORT[wd], mw), "BloockyHeader" })
	end
	push(header)

	-- Horizontal rule with junctions at every column separator
	local function week_rule()
		local rule = {}
		for c = 1, 7 do
			if c > 1 then
				table.insert(rule, { "┼", "BloockyGrid" })
			end
			table.insert(rule, { string.rep("─", mw), "BloockyGrid" })
		end
		push(rule)
	end
	week_rule()

	local today_str = utils.date_to_str(ctx.today)

	for w = 0, weeks - 1 do
		-- Build every cell of this week row
		local cells = {}
		for c = 1, 7 do
			local d = utils.add_days(grid_start, w * 7 + c - 1)
			local d_str = utils.date_to_str(d)
			local in_month = d.month == cur.month
			local cell_lines = {}

			-- Day number line
			local is_today = utils.same_day(d, ctx.today)
			local num = " " .. string.format("%2d", d.day) .. (is_today and " ●" or "")
			local num_grp = nil
			if is_today then
				num_grp = "BloockyToday"
			elseif not in_month then
				num_grp = "BloockyOtherMonth"
			end
			table.insert(cell_lines, { utils.fit(num, mw), num_grp })

			-- Entries: native blocks first, then dooing deadlines
			local entries = {}
			for _, block in ipairs(state.blocks_for_date(d)) do
				table.insert(entries, {
					text = cfg.icons.block .. utils.format_hhmm(block.start_min) .. " " .. block.title,
					grp = highlights.block_group(block),
					prio = 100,
				})
			end
			for _, todo in ipairs(dooing.tasks_for_date(d_str)) do
				local grp = "BloockyDooing"
				if todo.done then
					grp = "BloockyDooingDone"
				elseif d_str < today_str then
					grp = "BloockyDooingOverdue"
				end
				table.insert(entries, { text = cfg.icons.dooing .. " " .. todo.text, grp = grp, prio = 100 })
			end

			local max_items = cell_h - 1
			for i = 1, math.min(#entries, max_items) do
				if i == max_items and #entries > max_items then
					local more = #entries - max_items + 1
					table.insert(cell_lines, { utils.fit(" +" .. more .. " more", mw), "BloockyMore" })
				else
					local e = entries[i]
					table.insert(cell_lines, { utils.fit(" " .. e.text, mw - 1) .. " ", e.grp, e.prio })
				end
			end
			while #cell_lines < cell_h do
				table.insert(cell_lines, { string.rep(" ", mw) })
			end
			cells[c] = { lines = cell_lines, date = d }
		end

		-- Emit the row, painting the cursor cell
		for r = 1, cell_h do
			local chunks = {}
			for c = 1, 7 do
				if c > 1 then
					table.insert(chunks, { "│", "BloockyGrid" })
				end
				table.insert(chunks, cells[c].lines[r])
			end
			local lnum, spans = push(chunks)
			for c = 1, 7 do
				if utils.same_day(cells[c].date, cur) then
					local span = spans[2 * c - 1]
					table.insert(hls, { line = lnum, s = span.s, e = span.e, group = "BloockyCursor", prio = 60 })
					if r == 1 then
						meta.cursor_line = lnum + 1
					end
				end
			end
		end
		if w < weeks - 1 then
			week_rule()
		end
	end

	meta.title = string.format(" 󰃭 %s %d — Month ", utils.MONTHS[cur.month], cur.year)
	return lines, hls, meta
end

return M
