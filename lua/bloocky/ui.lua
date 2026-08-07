local config = require("bloocky.config")
local utils = require("bloocky.utils")
local state = require("bloocky.state")
local highlights = require("bloocky.highlights")

local M = {}

local views = {
	month = require("bloocky.views.month"),
	week = require("bloocky.views.week"),
	day = require("bloocky.views.day"),
}
local view_order = { "day", "week", "month" }

local buf, win = nil, nil
local ns = vim.api.nvim_create_namespace("bloocky")

M.view = nil
M.cursor = nil -- { date = { year, month, day }, min = minutes from midnight }

local function is_open()
	return win ~= nil and vim.api.nvim_win_is_valid(win)
end
M.is_open = is_open

local function content_width()
	local w = config.options.window.width
	if type(w) == "table" then
		w = w[M.view]
	end
	w = w or 0.8
	if w > 1 then
		return math.floor(math.min(w, vim.o.columns - 4))
	end
	return math.floor(vim.o.columns * w)
end

-- Rows the border steals from the editor (title and footer live in it)
local function border_rows()
	local b = config.options.window.border
	if not b or b == "none" or b == "shadow" then
		return 0
	end
	return 2
end

-- Rows usable for content: the editor minus the command line and the border,
-- keeping one spare row so the window never sits flush against the cmdline.
local function max_height()
	return math.max(6, vim.o.lines - vim.o.cmdheight - border_rows() - 1)
end

local function clamp_cursor()
	local h0 = config.options.hours.start
	local h1 = config.options.hours["end"]
	local min = M.cursor.min or h0 * 60
	M.cursor.min = math.min(math.max(min, h0 * 60), (h1 - 1) * 60)
end

local function footer_text(width)
	local km = config.options.keymaps.calendar
	local full = string.format(
		" %s add · %s edit · %s delete · %s view · %s today · %s close ",
		km.add or "-",
		km.edit or "-",
		km.delete or "-",
		km.cycle_view or "-",
		km.today or "-",
		km.close or "-"
	)
	if width and utils.dw(full) > width then
		return string.format(" %s add · %s edit · %s close ", km.add or "-", km.edit or "-", km.close or "-")
	end
	return full
end

-- Redraw the calendar for the current view/cursor
function M.render()
	if not is_open() then
		return
	end
	clamp_cursor()

	local ctx = {
		width = content_width(),
		height = max_height(),
		cursor = M.cursor,
		today = utils.today(),
		config = config.options,
	}
	local lines, hls, meta = views[M.view].render(ctx)

	local width = meta.width or ctx.width
	local height = math.min(#lines, ctx.height)
	-- Centre inside the rows the editor actually offers, border included
	local usable = vim.o.lines - vim.o.cmdheight
	local row = math.floor((usable - (height + border_rows())) / 2)
	vim.api.nvim_win_set_config(win, {
		relative = "editor",
		width = width,
		height = height,
		row = math.max(0, row),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
		title = meta.title or " Bloocky ",
		title_pos = "center",
		footer = footer_text(width),
		footer_pos = "center",
	})

	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	for _, h in ipairs(hls) do
		pcall(vim.api.nvim_buf_set_extmark, buf, ns, h.line, h.s, {
			end_col = h.e,
			hl_group = h.group,
			priority = h.prio or 100,
		})
	end

	pcall(vim.api.nvim_win_set_cursor, win, { meta.cursor_line or 1, 0 })
end

-- Cursor movement / period jumps
local function move_cursor(action)
	local c = M.cursor
	if action == "left" then
		c.date = utils.add_days(c.date, -1)
	elseif action == "right" then
		c.date = utils.add_days(c.date, 1)
	elseif action == "up" then
		if M.view == "month" then
			c.date = utils.add_days(c.date, -7)
		else
			c.min = c.min - 60
		end
	elseif action == "down" then
		if M.view == "month" then
			c.date = utils.add_days(c.date, 7)
		else
			c.min = c.min + 60
		end
	elseif action == "prev" then
		if M.view == "month" then
			c.date = utils.add_months(c.date, -1)
		else
			c.date = utils.add_days(c.date, -7)
		end
	elseif action == "next" then
		if M.view == "month" then
			c.date = utils.add_months(c.date, 1)
		else
			c.date = utils.add_days(c.date, 7)
		end
	elseif action == "today" then
		c.date = utils.today()
	end
	M.render()
end

-- Blocks under the cursor (whole day in month view, current slot otherwise)
local function hits_at_cursor()
	local blocks = state.blocks_for_date(M.cursor.date)
	if M.view == "month" then
		return blocks
	end
	local s = M.cursor.min
	local e = s + 60
	local out = {}
	for _, block in ipairs(blocks) do
		if block.start_min < e and block.start_min + block.duration_min > s then
			table.insert(out, block)
		end
	end
	return out
end

local function pick_block(blocks, callback)
	if #blocks == 1 then
		callback(blocks[1])
		return
	end
	vim.ui.select(blocks, {
		prompt = "Which block?",
		format_item = function(block)
			return utils.format_hhmm(block.start_min) .. " " .. block.title
		end,
	}, function(choice)
		if choice then
			callback(choice)
		end
	end)
end

-- The window the dialog should hand focus back to once it closes. Passed
-- explicitly because vim.ui.select may still own the cursor at that point.
local function return_win()
	return is_open() and win or nil
end

-- Open the creation dialog prefilled with the cursor slot
function M.add_block()
	require("bloocky.dialog").open({
		return_win = return_win(),
		prefill = {
			date = utils.date_to_str(M.cursor.date),
			start_min = (M.view == "month") and 9 * 60 or M.cursor.min,
		},
		on_save = function(fields)
			state.add_block(fields)
			M.render()
		end,
	})
end

-- Edit the block under the cursor (or create one on an empty slot)
function M.edit_block()
	local blocks = hits_at_cursor()
	if #blocks == 0 then
		M.add_block()
		return
	end
	local back = return_win()
	pick_block(blocks, function(block)
		require("bloocky.dialog").open({
			block = block,
			return_win = back,
			on_save = function(fields)
				state.update_block(block.id, fields)
				M.render()
			end,
		})
	end)
end

-- Delete the block under the cursor
function M.delete_block()
	local blocks = hits_at_cursor()
	if #blocks == 0 then
		vim.notify("Bloocky: no block under the cursor", vim.log.levels.INFO)
		return
	end
	pick_block(blocks, function(block)
		local label = block.title
		if block.recurrence then
			label = label .. " (recurring — the whole series will be deleted)"
		end
		if vim.fn.confirm('Delete "' .. label .. '"?', "&Yes\n&No", 2) == 1 then
			state.delete_block(block.id)
			M.render()
		end
	end)
end

function M.set_view(view)
	if views[view] then
		M.view = view
		M.render()
	end
end

function M.cycle_view()
	for i, v in ipairs(view_order) do
		if v == M.view then
			M.view = view_order[(i % #view_order) + 1]
			break
		end
	end
	M.render()
end

local function setup_keymaps()
	local km = config.options.keymaps.calendar
	local opts = { buffer = buf, noremap = true, silent = true, nowait = true }
	local map = function(lhs, fn)
		if lhs then
			vim.keymap.set("n", lhs, fn, opts)
		end
	end
	map(km.nav_left, function()
		move_cursor("left")
	end)
	map(km.nav_right, function()
		move_cursor("right")
	end)
	map(km.nav_up, function()
		move_cursor("up")
	end)
	map(km.nav_down, function()
		move_cursor("down")
	end)
	map(km.prev_period, function()
		move_cursor("prev")
	end)
	map(km.next_period, function()
		move_cursor("next")
	end)
	map(km.today, function()
		move_cursor("today")
	end)
	map(km.view_day, function()
		M.set_view("day")
	end)
	map(km.view_week, function()
		M.set_view("week")
	end)
	map(km.view_month, function()
		M.set_view("month")
	end)
	map(km.cycle_view, M.cycle_view)
	map(km.add, M.add_block)
	map(km.edit, M.edit_block)
	map(km.delete, M.delete_block)
	map(km.close, M.close)
	map("<Esc>", M.close)
end

-- Open the calendar (optionally forcing a view)
function M.open(view)
	highlights.setup()
	state.ensure_loaded()

	if is_open() then
		if view and views[view] then
			M.view = view
		end
		vim.api.nvim_set_current_win(win)
		M.render()
		return
	end

	M.view = view or config.options.default_view
	if not views[M.view] then
		M.view = "week"
	end

	local now = os.date("*t")
	M.cursor = { date = utils.today(), min = now.hour * 60 }

	buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("filetype", "bloocky", { buf = buf })

	win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = 20,
		height = 10,
		row = 3,
		col = 3,
		style = "minimal",
		border = config.options.window.border,
		title = " Bloocky ",
		title_pos = "center",
		zindex = 45,
	})
	vim.api.nvim_set_option_value("cursorline", false, { win = win })
	vim.api.nvim_set_option_value("wrap", false, { win = win })

	setup_keymaps()

	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		once = true,
		callback = function()
			win = nil
			buf = nil
		end,
	})

	-- Refit the layout to the new terminal size
	vim.api.nvim_create_autocmd("VimResized", {
		buffer = buf,
		callback = function()
			if not is_open() then
				return true
			end
			M.render()
		end,
	})

	M.render()
end

function M.close()
	if is_open() then
		vim.api.nvim_win_close(win, true)
	end
	win = nil
	buf = nil
end

function M.toggle(view)
	if is_open() then
		M.close()
	else
		M.open(view)
	end
end

return M
