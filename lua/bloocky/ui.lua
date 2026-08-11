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
M.mode = nil -- "float" | "sidebar"
M.cursor = nil -- { date = { year, month, day }, min = minutes from midnight }

local function is_open()
	return win ~= nil and vim.api.nvim_win_is_valid(win)
end
M.is_open = is_open

local function sidebar_options()
	return config.options.window.sidebar or {}
end

-- Columns the sidebar split asks for
local function sidebar_width()
	local w = sidebar_options().width or 46
	if w <= 1 then
		w = vim.o.columns * w
	end
	return math.floor(math.max(20, math.min(w, vim.o.columns - 4)))
end

-- A size option is either a single value or one value per view
local function per_view(value)
	if type(value) == "table" then
		return value[M.view]
	end
	return value
end

-- Cells the border steals from the editor (title and footer live in it)
local function border_cells()
	local b = config.options.window.border
	if not b or b == "none" or b == "shadow" then
		return 0
	end
	return 2
end

local function content_width()
	if M.mode == "sidebar" then
		-- The split may have been resized by hand, so trust the window itself
		return is_open() and vim.api.nvim_win_get_width(win) or sidebar_width()
	end

	local usable = math.max(20, vim.o.columns - border_cells())
	local w = per_view(config.options.window.width) or 0.8
	if w == "full" then
		return usable
	end
	if w > 1 then
		return math.floor(math.min(w, usable))
	end
	return math.floor(math.min(vim.o.columns * w, usable))
end

-- Rows usable for content: the editor minus the command line and the border,
-- keeping one spare row so the window never sits flush against the cmdline.
local function max_height()
	if M.mode == "sidebar" then
		local h = is_open() and vim.api.nvim_win_get_height(win) or (vim.o.lines - vim.o.cmdheight - 2)
		-- The winbar carries the title and takes a row out of the window
		return math.max(6, h - 1)
	end
	return math.max(6, vim.o.lines - vim.o.cmdheight - border_cells() - 1)
end

-- Rows the view is laid out in, and whether it should stretch to cover them.
-- "auto" lets the view stay compact inside everything on offer, anything else
-- pins a height the view fills exactly.
local function target_height()
	local max = max_height()
	local h = per_view(config.options.window.height) or "auto"
	if h == "full" then
		return max, true
	end
	if type(h) == "number" then
		local want = (h > 1) and h or ((vim.o.lines - vim.o.cmdheight) * h)
		return math.max(6, math.min(math.floor(want), max)), true
	end
	return max, false
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

	local height, fill = target_height()
	local ctx = {
		width = content_width(),
		height = height,
		fill = fill,
		cursor = M.cursor,
		today = utils.today(),
		config = config.options,
	}
	local lines, hls, meta = views[M.view].render(ctx)

	if M.mode == "sidebar" then
		-- A split cannot carry a title, so the winbar stands in for it
		local title = (meta.title or " Bloocky "):gsub("%%", "%%%%")
		vim.api.nvim_set_option_value("winbar", "%=" .. title .. "%=", { win = win })
	else
		local width = meta.width or ctx.width
		local rows = math.min(#lines, ctx.height)
		-- Centre inside the rows the editor actually offers, border included
		local usable = vim.o.lines - vim.o.cmdheight
		local row = math.floor((usable - (rows + border_cells())) / 2)
		vim.api.nvim_win_set_config(win, {
			relative = "editor",
			width = width,
			height = rows,
			row = math.max(0, row),
			col = math.max(0, math.floor((vim.o.columns - width) / 2)),
			title = meta.title or " Bloocky ",
			title_pos = "center",
			footer = footer_text(width),
			footer_pos = "center",
		})
	end

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
	if M.mode ~= "sidebar" then
		-- In a sidebar <Esc> is far too eager: it is a window you keep around
		map("<Esc>", M.close)
	end
end

local function open_float()
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
end

local function open_sidebar()
	-- A split cannot be opened from a floating window, so step out of one first
	if vim.api.nvim_win_get_config(0).relative ~= "" then
		for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
			if vim.api.nvim_win_get_config(w).relative == "" then
				vim.api.nvim_set_current_win(w)
				break
			end
		end
	end

	local side = sidebar_options().position == "left" and "topleft" or "botright"
	vim.cmd(side .. " vsplit")
	win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_win_set_width(win, sidebar_width())

	for name, value in pairs({
		cursorline = false,
		wrap = false,
		number = false,
		relativenumber = false,
		list = false,
		spell = false,
		signcolumn = "no",
		foldcolumn = "0",
		statuscolumn = "",
		winfixwidth = true,
	}) do
		vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
	end
end

-- Normalise the public argument: a view name, or { view = ..., mode = ... }
local function normalize(opts)
	if type(opts) == "string" then
		return { view = opts }
	end
	return opts or {}
end

-- Open the calendar (optionally forcing a view and/or a window mode)
function M.open(opts)
	opts = normalize(opts)
	highlights.setup()
	state.ensure_loaded()

	local mode = opts.mode or (is_open() and M.mode) or config.options.window.mode or "float"
	if mode ~= "sidebar" then
		mode = "float"
	end

	local keep_cursor, keep_view = nil, nil
	if is_open() then
		if mode == M.mode then
			if opts.view and views[opts.view] then
				M.view = opts.view
			end
			vim.api.nvim_set_current_win(win)
			M.render()
			return
		end
		-- Switching mode rebuilds the window, so carry the cursor and view across
		keep_cursor, keep_view = M.cursor, M.view
		M.close()
	end

	M.mode = mode
	M.view = opts.view or keep_view or (mode == "sidebar" and sidebar_options().view) or config.options.default_view
	if not views[M.view] then
		M.view = "week"
	end

	local now = os.date("*t")
	M.cursor = keep_cursor or { date = utils.today(), min = now.hour * 60 }

	buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("filetype", "bloocky", { buf = buf })

	if mode == "sidebar" then
		open_sidebar()
	else
		open_float()
	end

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
			if M.mode == "sidebar" then
				pcall(vim.api.nvim_win_set_width, win, sidebar_width())
			end
			M.render()
		end,
	})

	if mode == "sidebar" then
		-- WinResized is matched against window IDs, so it cannot be buffer-local:
		-- watch globally and drop out once the sidebar is gone
		local last_w, last_h
		vim.api.nvim_create_autocmd("WinResized", {
			callback = function()
				if not is_open() then
					return true
				end
				local w, h = vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win)
				if w ~= last_w or h ~= last_h then
					last_w, last_h = w, h
					M.render()
				end
			end,
		})
	end

	M.render()
end

function M.open_sidebar(view)
	M.open({ view = view or sidebar_options().view, mode = "sidebar" })
end

function M.close()
	if is_open() then
		-- Closing the last window of a tab is refused; drop the buffer instead
		if not pcall(vim.api.nvim_win_close, win, true) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end
	win = nil
	buf = nil
end

-- Close when the calendar already shows what was asked for, open otherwise
function M.toggle(opts)
	opts = normalize(opts)
	if is_open() and (not opts.mode or opts.mode == M.mode) then
		M.close()
	else
		M.open(opts)
	end
end

function M.toggle_sidebar(view)
	M.toggle({ view = view or sidebar_options().view, mode = "sidebar" })
end

return M
