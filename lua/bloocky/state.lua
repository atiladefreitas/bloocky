local config = require("bloocky.config")
local utils = require("bloocky.utils")

local M = {}

M.blocks = {}
local loaded = false

local function generate_id()
	return os.time() .. "_" .. math.random(1000, 9999)
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

-- Save blocks to disk
function M.save_blocks()
	local path = config.options.save_path
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local file = io.open(path, "w")
	if not file then
		vim.notify("Bloocky: could not write " .. path, vim.log.levels.ERROR)
		return
	end
	file:write(vim.json.encode(M.blocks))
	file:close()
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
		recurrence = fields.recurrence, -- nil | { type, days?, until_date? }
		created_at = os.time(),
	}
	table.insert(M.blocks, block)
	M.save_blocks()
	return block
end

-- Update an existing block by id
function M.update_block(id, fields)
	for _, block in ipairs(M.blocks) do
		if block.id == id then
			block.title = fields.title
			block.date = fields.date
			block.start_min = fields.start_min
			block.duration_min = fields.duration_min
			block.notes = fields.notes or ""
			block.recurrence = fields.recurrence
			M.save_blocks()
			return block
		end
	end
end

-- Delete a block (recurring blocks lose the whole series)
function M.delete_block(id)
	for i, block in ipairs(M.blocks) do
		if block.id == id then
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

-- Whether a block has an occurrence on the given day
local function occurs_on(block, date_str, wd)
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

-- All blocks occurring on a date, sorted by start time
function M.blocks_for_date(date)
	M.ensure_loaded()
	local date_str = utils.date_to_str(date)
	local wd = utils.wday(date)
	local out = {}
	for _, block in ipairs(M.blocks) do
		if occurs_on(block, date_str, wd) then
			table.insert(out, block)
		end
	end
	table.sort(out, function(a, b)
		return a.start_min < b.start_min
	end)
	return out
end

return M
