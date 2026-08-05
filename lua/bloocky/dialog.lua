local config = require("bloocky.config")
local utils = require("bloocky.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("bloocky_dialog")

local FIELDS = { "Title", "Date", "Start", "Duration", "Repeat", "Days", "Until", "Notes" }

-- Shown inside the input while it is empty
local HINTS = {
	Title = "what are you blocking time for?",
	Date = "YYYY-MM-DD",
	Start = "HH:MM (24h)",
	Duration = "1h30m · 45m · 2h",
	Repeat = "none · daily · weekly · weekdays · custom",
	Days = "custom only — mon,wed,fri",
	Until = "repeat end date, empty = forever",
	Notes = "optional",
}

-- Extmark id namespaces: field i keeps its input line at id i,
-- its placeholder at PLACEHOLDER + i and its error at ERROR + i.
local PLACEHOLDER = 100
local ERROR = 200

local function initial_values(opts)
	local block = opts.block
	if block then
		local r = block.recurrence
		local day_names = {}
		if r and type(r.days) == "table" then
			local rev = { "sun", "mon", "tue", "wed", "thu", "fri", "sat" }
			for _, d in ipairs(r.days) do
				table.insert(day_names, rev[d])
			end
		end
		return {
			Title = block.title,
			Date = block.date,
			Start = utils.format_hhmm(block.start_min),
			Duration = utils.format_duration(block.duration_min),
			Repeat = r and r.type or "none",
			Days = table.concat(day_names, ","),
			Until = (r and r.until_date) or "",
			Notes = (block.notes or ""):gsub("\n", " "),
		}
	end
	local prefill = opts.prefill or {}
	return {
		Title = "",
		Date = prefill.date or utils.date_to_str(utils.today()),
		Start = utils.format_hhmm(prefill.start_min or 9 * 60),
		Duration = "1h",
		Repeat = "none",
		Days = "",
		Until = "",
		Notes = "",
	}
end

-- Validate raw field values (lowercase keys) into block fields.
-- Returns fields, or nil plus a { Field = "message" } table.
local function validate(raw)
	local errs = {}

	local title = vim.trim(raw.title or "")
	if title == "" then
		errs.Title = "required"
	end
	local date = utils.str_to_date(vim.trim(raw.date or ""))
	if not date then
		errs.Date = "use YYYY-MM-DD"
	end
	local start_min = utils.parse_hhmm(vim.trim(raw.start or ""))
	if not start_min then
		errs.Start = "use HH:MM (24h)"
	end
	local duration = utils.parse_duration(vim.trim(raw.duration or ""))
	if not duration then
		errs.Duration = "e.g. 1h30m"
	end

	local rtype = vim.trim(raw["repeat"] or ""):lower()
	if rtype == "" then
		rtype = "none"
	end
	local valid_repeat = { none = true, daily = true, weekly = true, weekdays = true, custom = true }
	if not valid_repeat[rtype] then
		errs.Repeat = "none · daily · weekly · weekdays · custom"
	end

	local days = nil
	if rtype == "custom" then
		days = {}
		for token in (raw.days or ""):gmatch("[^,%s]+") do
			local wd = utils.DAY_TOKENS[token:lower():sub(1, 3)]
			if wd then
				table.insert(days, wd)
			else
				errs.Days = "unknown day: " .. token
			end
		end
		if #days == 0 and not errs.Days then
			errs.Days = "needs days, e.g. mon,wed,fri"
		end
	end

	local until_date = nil
	local u_raw = vim.trim(raw["until"] or "")
	if u_raw ~= "" then
		local u = utils.str_to_date(u_raw)
		if u then
			until_date = utils.date_to_str(u)
		else
			errs.Until = "use YYYY-MM-DD"
		end
	end

	if next(errs) then
		return nil, errs
	end

	local granularity = config.options.granularity or 30
	start_min = utils.snap(start_min, granularity)
	duration = math.max(granularity, utils.snap(duration, granularity))

	local recurrence = nil
	if rtype ~= "none" then
		recurrence = { type = rtype, days = days, until_date = until_date }
	end

	return {
		title = title,
		date = utils.date_to_str(date),
		start_min = start_min,
		duration_min = duration,
		notes = vim.trim(raw.notes or ""),
		recurrence = recurrence,
	}
end

-- Expose for reuse/testing
M.validate = validate

-- Open the block dialog.
-- opts: { block = existing_block? , prefill = { date, start_min }?, on_save = fn(fields) }
function M.open(opts)
	local values = initial_values(opts)

	-- One field = label line + input line, separated by a blank line
	local lines, label_rows = {}, {}
	for i, field in ipairs(FIELDS) do
		table.insert(lines, "  " .. field)
		label_rows[i] = #lines - 1
		table.insert(lines, values[field] or "")
		if i < #FIELDS then
			table.insert(lines, "")
		end
	end

	local width = 56
	local height = #lines

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("filetype", "bloocky_dialog", { buf = buf })

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2) - 1,
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = config.options.window.border,
		title = opts.block and "  Edit block " or "  New block ",
		title_pos = "center",
		footer = " ⏎ save · ⇥/⇧⇥ move · q cancel ",
		footer_pos = "center",
		zindex = 60,
	})

	-- Labels + input strips. The input extmarks (id = field index) also
	-- track each field's line through edits, so parsing never relies on
	-- fixed line numbers.
	for i, field in ipairs(FIELDS) do
		local lrow = label_rows[i]
		vim.api.nvim_buf_set_extmark(buf, ns, lrow, 0, {
			end_col = #lines[lrow + 1],
			hl_group = "BloockyHeader",
			priority = 100,
		})
		vim.api.nvim_buf_set_extmark(buf, ns, lrow + 1, 0, {
			id = i,
			virt_text = { { "  ▎ ", "BloockyInputBar" } },
			virt_text_pos = "inline",
			line_hl_group = "BloockyInput",
			right_gravity = false,
		})
	end

	local function input_row(i)
		local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, i, {})
		return pos and pos[1] or nil
	end

	local function input_text(i)
		local row = input_row(i)
		if not row then
			return ""
		end
		return vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
	end

	-- Placeholder hints on empty inputs
	local function refresh_placeholders()
		for i, field in ipairs(FIELDS) do
			local row = input_row(i)
			if row then
				if vim.trim(input_text(i)) == "" then
					vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
						id = PLACEHOLDER + i,
						virt_text = { { HINTS[field], "BloockyMore" } },
						virt_text_pos = "eol",
					})
				else
					pcall(vim.api.nvim_buf_del_extmark, buf, ns, PLACEHOLDER + i)
				end
			end
		end
	end

	local function clear_errors()
		for i = 1, #FIELDS do
			pcall(vim.api.nvim_buf_del_extmark, buf, ns, ERROR + i)
		end
	end

	refresh_placeholders()
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = buf,
		callback = function()
			refresh_placeholders()
			clear_errors()
		end,
	})

	-- Field the cursor is on (nearest input line)
	local function current_field()
		local row = vim.api.nvim_win_get_cursor(win)[1] - 1
		local best, bestd = 1, math.huge
		for i = 1, #FIELDS do
			local irow = input_row(i)
			if irow then
				local d = math.abs(irow - row)
				if d < bestd then
					best, bestd = i, d
				end
			end
		end
		return best
	end

	local function goto_field(i, enter_insert)
		i = math.max(1, math.min(#FIELDS, i))
		local row = input_row(i)
		if not row then
			return
		end
		vim.api.nvim_win_set_cursor(win, { row + 1, math.max(0, #input_text(i)) })
		if enter_insert and not vim.api.nvim_get_mode().mode:find("i") then
			vim.cmd("startinsert!")
		end
	end

	local function close()
		vim.cmd("stopinsert")
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	local function save()
		clear_errors()
		local raw = {}
		for i, field in ipairs(FIELDS) do
			raw[field:lower()] = vim.trim(input_text(i))
		end
		local fields, errs = validate(raw)
		if not fields then
			local first = nil
			for i, field in ipairs(FIELDS) do
				if errs[field] then
					first = first or i
					local row = input_row(i)
					if row then
						vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
							id = ERROR + i,
							virt_text = { { "✗ " .. errs[field] .. " ", "BloockyError" } },
							virt_text_pos = "right_align",
						})
					end
				end
			end
			vim.cmd("stopinsert")
			if first then
				goto_field(first, false)
			end
			return
		end
		close()
		opts.on_save(fields)
	end

	local kopts = { buffer = buf, noremap = true, silent = true, nowait = true }
	local map = vim.keymap.set

	map("n", "<CR>", save, kopts)
	map({ "n", "i" }, "<C-s>", save, kopts)
	map("n", "q", close, kopts)
	map("n", "<Esc>", close, kopts)

	-- ⏎ in insert advances through the form and saves from the last field
	map("i", "<CR>", function()
		local i = current_field()
		if i >= #FIELDS then
			save()
		else
			goto_field(i + 1, true)
		end
	end, kopts)

	map({ "n", "i" }, "<Tab>", function()
		goto_field(current_field() + 1, vim.fn.mode():find("i") ~= nil)
	end, kopts)
	map({ "n", "i" }, "<S-Tab>", function()
		goto_field(current_field() - 1, vim.fn.mode():find("i") ~= nil)
	end, kopts)

	-- Movement jumps between fields instead of raw lines
	for _, lhs in ipairs({ "j", "<Down>" }) do
		map("n", lhs, function()
			goto_field(current_field() + 1, false)
		end, kopts)
	end
	for _, lhs in ipairs({ "k", "<Up>" }) do
		map("n", lhs, function()
			goto_field(current_field() - 1, false)
		end, kopts)
	end
	map("n", "o", function()
		goto_field(current_field() + 1, true)
	end, kopts)
	map("n", "O", function()
		goto_field(current_field() - 1, true)
	end, kopts)

	-- dd clears the current field instead of deleting the line
	map("n", "dd", function()
		local row = input_row(current_field())
		if row then
			vim.api.nvim_buf_set_lines(buf, row, row + 1, false, { "" })
			refresh_placeholders()
			clear_errors()
		end
	end, kopts)

	-- Start typing the title right away when creating
	goto_field(1, not opts.block)
end

return M
