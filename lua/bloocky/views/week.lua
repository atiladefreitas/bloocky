local utils = require("bloocky.utils")
local state = require("bloocky.state")
local dooing = require("bloocky.dooing")
local highlights = require("bloocky.highlights")
local marks = require("bloocky.marks")

local M = {}

-- First block covering [row_s, row_e) and how many overlap it
local function occ_at(blocks, row_s, row_e)
	local found, count = nil, 0
	for _, block in ipairs(blocks) do
		if block.start_min < row_e and (block.start_min + block.duration_min) > row_s then
			count = count + 1
			if not found then
				found = block
			end
		end
	end
	return found, count
end

-- Block still running at minute `min` (spans across it)
local function spanning(blocks, min)
	for _, block in ipairs(blocks) do
		if block.start_min < min and (block.start_min + block.duration_min) > min then
			return block
		end
	end
	return nil
end

function M.render(ctx)
	local cfg = ctx.config
	local gutter = 7
	-- Each day column is preceded by a "│" separator. Filling spends the cells
	-- that do not divide evenly on the columns instead of dropping them.
	local inner = math.max(7, ctx.width - gutter - 7)
	local cws = utils.share(ctx.fill and inner or (math.floor(inner / 7) * 7), 7)
	local width = gutter + 7
	for _, c in ipairs(cws) do
		width = width + c
	end

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

	local wstart = utils.week_start_of(ctx.cursor.date, cfg.week_start)
	local days = {}
	for i = 0, 6 do
		days[i + 1] = utils.add_days(wstart, i)
	end
	local wend = days[7]

	-- Day header
	local header = { { string.rep(" ", gutter) } }
	for i, d in ipairs(days) do
		local label = utils.WDAYS_SHORT[utils.wday(d)] .. " " .. string.format("%02d", d.day)
		local grp = "BloockyHeader"
		if utils.same_day(d, ctx.today) then
			grp = "BloockyToday"
		end
		table.insert(header, { "│", "BloockyGrid" })
		table.insert(header, { utils.center(label, cws[i]), grp })
	end
	local header_lnum, header_spans = push(header)
	for i, d in ipairs(days) do
		if utils.same_day(d, ctx.cursor.date) then
			local span = header_spans[2 * i + 1]
			table.insert(hls, { line = header_lnum, s = span.s, e = span.e, group = "BloockyCursor", prio = 60 })
		end
	end

	-- Blocks for the week, split once: all-day ones go in a strip above the
	-- grid, timed ones into it.
	local occ, all_day = {}, {}
	for i, d in ipairs(days) do
		all_day[i], occ[i] = state.split_for_date(d)
	end

	-- All-day strip
	local any_all_day = false
	for i in ipairs(days) do
		if #all_day[i] > 0 then
			any_all_day = true
		end
	end
	if any_all_day then
		local chunks = { { utils.fit(" " .. cfg.icons.all_day, gutter), "BloockyTime" } }
		for i in ipairs(days) do
			table.insert(chunks, { "│", "BloockyGrid" })
			if #all_day[i] > 0 then
				local block = all_day[i][1]
				local text = marks.icon(block) .. block.title
				if #all_day[i] > 1 then
					text = marks.icon(block) .. "×" .. #all_day[i] .. " " .. block.title
				end
				table.insert(chunks, { utils.fit(text, cws[i]), highlights.block_group(block), 100 })
			else
				table.insert(chunks, { string.rep(" ", cws[i]) })
			end
		end
		push(chunks)
	end

	-- Dooing deadline strip
	local due = {}
	local any_due = false
	for i, d in ipairs(days) do
		due[i] = dooing.tasks_for_date(utils.date_to_str(d))
		if #due[i] > 0 then
			any_due = true
		end
	end
	if any_due then
		local chunks = { { utils.fit(" due", gutter), "BloockyTime" } }
		for i in ipairs(days) do
			table.insert(chunks, { "│", "BloockyGrid" })
			if #due[i] > 0 then
				local text = cfg.icons.dooing .. " " .. due[i][1].text
				if #due[i] > 1 then
					text = cfg.icons.dooing .. "×" .. #due[i] .. " " .. due[i][1].text
				end
				table.insert(chunks, { utils.fit(text, cws[i]), "BloockyDooing" })
			else
				table.insert(chunks, { string.rep(" ", cws[i]) })
			end
		end
		push(chunks)
	end

	local rule = { { string.rep("─", gutter), "BloockyGrid" } }
	for i = 1, 7 do
		table.insert(rule, { "┼" .. string.rep("─", cws[i]), "BloockyGrid" })
	end
	push(rule)

	-- Hour grid
	local cursor_col = nil
	for i, d in ipairs(days) do
		if utils.same_day(d, ctx.cursor.date) then
			cursor_col = i
		end
	end

	-- Whatever the header and strips did not use goes to the hour grid, which
	-- always shows every hour — grouping them if the window is short
	local h0, h1 = cfg.hours.start, cfg.hours["end"]
	for _, row in ipairs(utils.hour_layout(h0, h1, ctx.height - #lines, ctx.fill)) do
		local row_s, row_e = row.s, row.e

		-- The cell of every day for this slot, laid out once and reused by the
		-- lines the slot spans (only the first one carries the block's text)
		local cells = {}
		for i in ipairs(days) do
			local block, n = occ_at(occ[i], row_s, row_e)
			local text
			if block then
				if block.start_min >= row_s then
					text = marks.icon(block) .. utils.format_hhmm(block.start_min) .. " " .. block.title
					if block.recurrence then
						text = text .. " " .. cfg.icons.recurring
					end
				else
					text = marks.icon(block)
				end
				if n > 1 then
					text = utils.fit(text, cws[i] - 2) .. "+ "
				else
					text = utils.fit(text, cws[i])
				end
			end
			cells[i] = { block = block, text = text }
		end

		local on_cursor = cursor_col and ctx.cursor.min >= row_s and ctx.cursor.min < row_e
		for r = 1, row.lines do
			local chunks = {
				{ (r == 1) and row.label or string.rep(" ", gutter), (r == 1) and "BloockyTime" or nil },
			}
			for i in ipairs(days) do
				table.insert(chunks, { "│", "BloockyGrid" })
				local cell = cells[i]
				if cell.block then
					local text = (r == 1) and cell.text or string.rep(" ", cws[i])
					table.insert(chunks, { text, highlights.block_group(cell.block), 100 })
				else
					table.insert(chunks, { string.rep(" ", cws[i]) })
				end
			end
			local lnum, spans = push(chunks)
			if on_cursor then
				local span = spans[2 * cursor_col + 1]
				table.insert(hls, { line = lnum, s = span.s, e = span.e, group = "BloockyCursor", prio = 200 })
				meta.cursor_line = meta.cursor_line or (lnum + 1)
			end
		end

		-- Dotted divider between hours; blocks spanning the boundary stay solid
		if row.div then
			local bmin = row_e
			local div = { { string.rep(" ", gutter) } }
			for i in ipairs(days) do
				table.insert(div, { "│", "BloockyGrid" })
				local cont = spanning(occ[i], bmin)
				if cont then
					table.insert(div, { string.rep(" ", cws[i]), highlights.block_group(cont), 100 })
				else
					table.insert(div, { string.rep("┄", cws[i]), "BloockyGrid" })
				end
			end
			push(div)
		end
	end

	meta.title = string.format(
		" 󰃭 %s %02d – %s %02d, %d — Week ",
		utils.MONTHS_SHORT[wstart.month],
		wstart.day,
		utils.MONTHS_SHORT[wend.month],
		wend.day,
		wend.year
	)
	return lines, hls, meta
end

return M
