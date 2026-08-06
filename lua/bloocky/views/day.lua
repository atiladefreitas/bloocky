local utils = require("bloocky.utils")
local state = require("bloocky.state")
local dooing = require("bloocky.dooing")
local highlights = require("bloocky.highlights")

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
	local blocks = state.blocks_for_date(date)
	local tasks = dooing.tasks_for_date(date_str)

	-- Everything above the hour grid is collected first: it only gets the rows
	-- the grid does not need, so the whole day always stays on screen.
	local h0, h1 = cfg.hours.start, cfg.hours["end"]
	local top = {}
	local function add(chunks)
		table.insert(top, chunks)
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
	local rows = utils.hour_layout(h0, h1, ctx.height - #lines)
	for _, row in ipairs(rows) do
		local row_s, row_e = row.s, row.e
		local block, n = occ_at(blocks, row_s, row_e)
		local cell
		if block then
			local text
			if block.start_min >= row_s then
				text = cfg.icons.block
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
				text = cfg.icons.block
			end
			if n > 1 then
				text = text .. " (+" .. (n - 1) .. ")"
			end
			cell = { utils.fit(text, cwidth), highlights.block_group(block), 100 }
		else
			cell = { string.rep(" ", cwidth) }
		end
		local lnum, spans = push({
			{ row.label, "BloockyTime" },
			{ "│", "BloockyGrid" },
			cell,
		})
		if ctx.cursor.min >= row_s and ctx.cursor.min < row_e then
			local span = spans[3]
			table.insert(hls, { line = lnum, s = span.s, e = span.e, group = "BloockyCursor", prio = 200 })
			meta.cursor_line = lnum + 1
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
