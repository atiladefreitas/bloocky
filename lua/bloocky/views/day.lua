local utils = require("bloocky.utils")
local state = require("bloocky.state")
local dooing = require("bloocky.dooing")
local highlights = require("bloocky.highlights")
local marks = require("bloocky.marks")

local M = {}

-- Block still running at minute `min` (spans across it)
local function spanning(blocks, min)
	for _, block in ipairs(blocks) do
		if block.start_min < min and (block.start_min + block.duration_min) > min then
			return block
		end
	end
	return nil
end

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

function M.render(ctx)
	local cfg = ctx.config
	local gutter = 8 -- " 05:00 │"
	local cwidth = ctx.width - gutter

	local lines, hls = {}, {}
	local meta = { width = ctx.width }

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

	local date = ctx.cursor.date
	local date_str = utils.date_to_str(date)
	-- All-day blocks never enter the hour grid; they get their own section.
	local all_day, blocks = state.split_for_date(date)
	local tasks = dooing.tasks_for_date(date_str)

	-- Everything above the hour grid is collected first: it only gets the rows
	-- the grid does not need, so the whole day always stays on screen.
	local h0, h1 = cfg.hours.start, cfg.hours["end"]
	local top = {}
	local function add(chunks)
		table.insert(top, chunks)
	end

	-- All-day section: a date, not a time, so it cannot be placed on an hour
	if #all_day > 0 then
		add({ { " " .. cfg.icons.all_day .. " All day", "BloockyHeader" } })
		local max_shown = 4
		for i, block in ipairs(all_day) do
			if i > max_shown then
				add({ { "    +" .. (#all_day - max_shown) .. " more", "BloockyMore" } })
				break
			end
			local text = "    " .. marks.icon(block) .. " " .. block.title
			local days = math.ceil((block.duration_min or 1440) / 1440)
			if days > 1 then
				text = text .. "  (" .. days .. " days)"
			end
			add({ { utils.fit(text, ctx.width), highlights.block_group(block), 100 } })
		end
		add({ { string.rep("─", ctx.width), "BloockyGrid" } })
	end

	-- Dooing deadline section
	if #tasks > 0 then
		add({ { " " .. cfg.icons.dooing .. " Due this day", "BloockyHeader" } })
		local max_tasks = 4
		for i, todo in ipairs(tasks) do
			if i > max_tasks then
				add({ { "    +" .. (#tasks - max_tasks) .. " more", "BloockyMore" } })
				break
			end
			local text = "    " .. cfg.icons.dooing .. " " .. todo.text
			if todo.estimated_hours then
				text = text .. "  (≈" .. todo.estimated_hours .. "h)"
			end
			if todo.priorities and type(todo.priorities) == "table" and #todo.priorities > 0 then
				text = text .. "  [" .. table.concat(todo.priorities, ", ") .. "]"
			end
			local grp = "BloockyDooing"
			if todo.done then
				grp = "BloockyDooingDone"
			elseif date_str < utils.date_to_str(ctx.today) then
				grp = "BloockyDooingOverdue"
			end
			add({ { utils.truncate(text, ctx.width), grp } })
		end
		add({ { string.rep("─", ctx.width), "BloockyGrid" } })
	end

	-- Trim the top sections down to what is left once every hour has a row
	local budget = math.max(0, ctx.height - (h1 - h0))
	if #top > budget then
		local keep = math.max(0, budget - 1)
		local hidden = #top - keep
		for i = #top, keep + 1, -1 do
			table.remove(top, i)
		end
		if budget > 0 then
			add({ { "    +" .. hidden .. " more above", "BloockyMore" } })
		end
	end
	for _, chunks in ipairs(top) do
		push(chunks)
	end

	-- Hour grid
	local rows = utils.hour_layout(h0, h1, ctx.height - #lines, ctx.fill)
	for _, row in ipairs(rows) do
		local row_s, row_e = row.s, row.e
		local block, n = occ_at(blocks, row_s, row_e)
		local cell
		if block then
			local text
			if block.start_min >= row_s then
				text = marks.icon(block)
					.. utils.format_hhmm(block.start_min)
					.. "–"
					.. utils.format_hhmm(block.start_min + block.duration_min)
					.. " "
					.. block.title
					.. " ("
					.. utils.format_duration(block.duration_min)
					.. ")"
				if block.recurrence then
					text = text .. " " .. cfg.icons.recurring
				end
				if block.notes and block.notes ~= "" then
					text = text .. " — " .. block.notes:gsub("\n", " ")
				end
			else
				text = marks.icon(block)
			end
			if n > 1 then
				text = text .. " (+" .. (n - 1) .. ")"
			end
			cell = { utils.fit(text, cwidth), highlights.block_group(block), 100 }
		else
			cell = { string.rep(" ", cwidth) }
		end
		-- A tall slot keeps its label on the first line; the rest carries the
		-- block's colour on so it reads as one bar
		local on_cursor = ctx.cursor.min >= row_s and ctx.cursor.min < row_e
		for r = 1, row.lines do
			local body = cell
			if r > 1 then
				body = block and { string.rep(" ", cwidth), highlights.block_group(block), 100 }
					or { string.rep(" ", cwidth) }
			end
			local lnum, spans = push({
				{ (r == 1) and row.label or string.rep(" ", gutter - 1), (r == 1) and "BloockyTime" or nil },
				{ "│", "BloockyGrid" },
				body,
			})
			if on_cursor then
				local span = spans[3]
				table.insert(hls, { line = lnum, s = span.s, e = span.e, group = "BloockyCursor", prio = 200 })
				meta.cursor_line = meta.cursor_line or (lnum + 1)
			end
		end

		-- Dotted divider between hours; blocks spanning the boundary stay solid
		if row.div then
			local cont = spanning(blocks, row_e)
			if cont then
				push({
					{ string.rep(" ", gutter - 1) },
					{ "│", "BloockyGrid" },
					{ string.rep(" ", cwidth), highlights.block_group(cont), 100 },
				})
			else
				push({
					{ string.rep(" ", gutter - 1) },
					{ "│", "BloockyGrid" },
					{ string.rep("┄", cwidth), "BloockyGrid" },
				})
			end
		end
	end

	meta.title = string.format(
		" 󰃭 %s, %s %02d %d — Day ",
		utils.WDAYS_LONG[utils.wday(date)],
		utils.MONTHS[date.month],
		date.day,
		date.year
	)
	return lines, hls, meta
end

return M
