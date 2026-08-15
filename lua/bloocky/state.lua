local config = require("bloocky.config")
local utils = require("bloocky.utils")

local M = {}

M.blocks = {}
local loaded = false

local function generate_id()
	return os.time() .. "_" .. math.random(1000, 9999)
end

-- The sync sidecar, but only once the user has opted in. Required lazily so a
-- setup without sync never loads a line of it.
local function sync_store()
	local sync = config.options.sync
	if not (sync and sync.enabled) then
		return nil
	end
	local ok, store = pcall(require, "bloocky.sync.store")
	return ok and store or nil
end

-- Load blocks from disk
function M.load_blocks()
	local path = config.options.save_path
	loaded = true
	local file = io.open(path, "r")
	if not file then
		M.blocks = {}
		return
	end
	local content = file:read("*a")
	file:close()
	if not content or content == "" then
		M.blocks = {}
		return
	end
	local ok, decoded = pcall(vim.fn.json_decode, content)
	if ok and type(decoded) == "table" then
		M.blocks = decoded
		-- Other writers use this file too (docs/block-structure.md), and a
		-- title carrying a newline would crash nvim_buf_set_lines on every
		-- redraw. Sync flattens these on import; do the same for direct writes.
		for _, block in ipairs(M.blocks) do
			if type(block) == "table" and type(block.title) == "string" and block.title:find("[\r\n]") then
				block.title = block.title:gsub("%s*[\r\n]+%s*", " ")
			end
		end
	else
		vim.notify("Bloocky: could not parse " .. path, vim.log.levels.WARN)
		M.blocks = {}
	end
end

function M.ensure_loaded()
	if not loaded then
		M.load_blocks()
	end
end

-- Save blocks to disk. Created 0600: with sync enabled the blocks mirror
-- calendar contents, which are not for other users of the machine. (Other
-- *readers* of the file — see docs/block-structure.md — run as the same user.)
function M.save_blocks()
	local path = config.options.save_path
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local fd = vim.uv.fs_open(path, "w", tonumber("600", 8))
	if not fd then
		vim.notify("Bloocky: could not write " .. path, vim.log.levels.ERROR)
		return
	end
	vim.uv.fs_write(fd, vim.json.encode(M.blocks))
	vim.uv.fs_close(fd)
	-- The mode above only applies at creation; tighten files from before it.
	pcall(vim.uv.fs_chmod, path, tonumber("600", 8))
end

-- Create a new time block
function M.add_block(fields)
	M.ensure_loaded()
	local block = {
		id = generate_id(),
		title = fields.title,
		date = fields.date, -- "YYYY-MM-DD"; start date when recurring
		start_min = fields.start_min, -- minutes from midnight
		duration_min = fields.duration_min,
		notes = fields.notes or "",
		recurrence = fields.recurrence, -- nil | { type, days?, until_date?, exdates? }
		all_day = fields.all_day or nil, -- true for a date-based block; absent means timed
		created_at = os.time(),
		updated_at = os.time(), -- bumped on every edit; sync reads it
		source = fields.source or "local", -- "local" or the sync account it came from
	}
	table.insert(M.blocks, block)
	M.save_blocks()
	return block
end

-- Update an existing block by id.
-- Fields are assigned onto the stored table rather than replacing it, so keys
-- written by another tool survive the edit.
function M.update_block(id, fields)
	for _, block in ipairs(M.blocks) do
		if block.id == id then
			block.title = fields.title
			block.date = fields.date
			block.start_min = fields.start_min
			block.duration_min = fields.duration_min
			block.notes = fields.notes or ""
			block.recurrence = fields.recurrence
			block.all_day = fields.all_day or nil
			block.updated_at = os.time()
			block.source = block.source or "local" -- backfill for pre-sync blocks
			M.save_blocks()
			return block
		end
	end
end

-- Delete a block (recurring blocks lose the whole series)
function M.delete_block(id)
	for i, block in ipairs(M.blocks) do
		if block.id == id then
			-- Leave a tombstone first: once the block is gone, "deleted here"
			-- and "never synced" look identical, and the next pull would put
			-- the event straight back.
			local store = sync_store()
			if store then
				store.record_deletion(block)
			end
			table.remove(M.blocks, i)
			M.save_blocks()
			return true
		end
	end
	return false
end

function M.get_block(id)
	for _, block in ipairs(M.blocks) do
		if block.id == id then
			return block
		end
	end
end

-- How many days an occurrence covers. Only all-day blocks span more than one;
-- a timed block is a single day no matter how long it runs.
local function span_days(block)
	if not block.all_day then
		return 1
	end
	-- Capped so a malformed duration cannot turn the lookup into a long loop.
	return math.max(1, math.min(366, math.ceil((block.duration_min or 1440) / 1440)))
end

-- An excluded date removes the whole occurrence, span and all.
local function excluded(block, date_str)
	local r = block.recurrence
	if type(r) ~= "table" or r == vim.NIL then
		return false
	end
	for _, date in ipairs(r.exdates or {}) do
		if date == date_str then
			return true
		end
	end
	return false
end

-- Whether an occurrence *begins* on the given day
local function starts_on(block, date_str, wd)
	if excluded(block, date_str) then
		return false
	end
	local r = block.recurrence
	if not r or r == vim.NIL then
		return block.date == date_str
	end
	if date_str < block.date then
		return false
	end
	if r.until_date and r.until_date ~= "" and date_str > r.until_date then
		return false
	end
	if r.type == "daily" then
		return true
	end
	if r.type == "weekly" then
		local start = utils.str_to_date(block.date)
		return start ~= nil and utils.wday(start) == wd
	end
	if r.type == "weekdays" then
		return wd >= 2 and wd <= 6
	end
	if r.type == "custom" then
		for _, day in ipairs(r.days or {}) do
			if day == wd then
				return true
			end
		end
	end
	return false
end

-- Whether a block covers the given day, counting a multi-day all-day block as
-- covering every day it runs over rather than only the one it starts on.
local function occurs_on(block, date_str, wd, date)
	if starts_on(block, date_str, wd) then
		return true
	end
	local span = span_days(block)
	if span == 1 or not date then
		return false
	end
	for back = 1, span - 1 do
		local earlier = utils.add_days(date, -back)
		if starts_on(block, utils.date_to_str(earlier), utils.wday(earlier)) then
			return true
		end
	end
	return false
end

-- All blocks covering a date. All-day blocks come first — they are drawn above
-- the hour grid, not in it — and the rest sort by start time.
function M.blocks_for_date(date)
	M.ensure_loaded()
	local date_str = utils.date_to_str(date)
	local wd = utils.wday(date)
	local out = {}
	for _, block in ipairs(M.blocks) do
		if occurs_on(block, date_str, wd, date) then
			table.insert(out, block)
		end
	end
	table.sort(out, function(a, b)
		if not a.all_day ~= not b.all_day then
			return a.all_day and true or false
		end
		return a.start_min < b.start_min
	end)
	return out
end

-- The all-day and timed blocks for a date, already separated: every view needs
-- them apart, and doing it here keeps the rule in one place.
function M.split_for_date(date)
	local all_day, timed = {}, {}
	for _, block in ipairs(M.blocks_for_date(date)) do
		table.insert(block.all_day and all_day or timed, block)
	end
	return all_day, timed
end

return M
