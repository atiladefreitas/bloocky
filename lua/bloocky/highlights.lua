local M = {}

-- Color palette cycled across blocks (bg pills on the grid)
local palette = {
	{ fg = "#c0caf5", bg = "#394b70" }, -- blue
	{ fg = "#c0caf5", bg = "#33635c" }, -- teal
	{ fg = "#c0caf5", bg = "#5a4a78" }, -- purple
	{ fg = "#c0caf5", bg = "#6b5238" }, -- amber
	{ fg = "#c0caf5", bg = "#6f3a4d" }, -- rose
	{ fg = "#c0caf5", bg = "#2b5d6b" }, -- cyan
}

M.palette_size = #palette

function M.setup()
	local set = function(name, val)
		val.default = true
		vim.api.nvim_set_hl(0, name, val)
	end
	set("BloockyHeader", { link = "Title" })
	set("BloockyTime", { link = "Comment" })
	set("BloockyGrid", { link = "NonText" })
	set("BloockyToday", { fg = "#e0af68", bold = true })
	set("BloockyCursor", { link = "Visual" })
	set("BloockyOtherMonth", { link = "NonText" })
	set("BloockyMore", { link = "Comment" })
	set("BloockyDooing", { fg = "#e0af68" })
	set("BloockyDooingDone", { link = "Comment" })
	set("BloockyDooingOverdue", { link = "DiagnosticError" })
	set("BloockyInput", { bg = "#24283b" })
	set("BloockyInputBar", { fg = "#7aa2f7", bg = "#24283b" })
	set("BloockyError", { link = "DiagnosticError" })
	set("BloockySyncStatus", { link = "Comment" })
	set("BloockyBlockConflict", { fg = "#1a1b26", bg = "#f7768e", bold = true })
	for i, color in ipairs(palette) do
		set("BloockyBlock" .. i, { fg = color.fg, bg = color.bg })
	end
end

local function hash_index(text)
	local sum = 0
	for i = 1, #text do
		sum = sum + text:byte(i)
	end
	return sum
end

-- Stable color per block, derived from its id -- except when the sync layer
-- has something more urgent to say about it.
function M.block_group(block)
	local marks = require("bloocky.marks")
	if marks.is_conflicted(block) then
		return "BloockyBlockConflict"
	end
	-- Blocks from the same calendar share a colour, so a glance separates work
	-- from personal. Local blocks keep their per-block colour.
	local calendar = marks.calendar_of(block)
	if calendar then
		return "BloockyBlock" .. (hash_index(calendar) % M.palette_size + 1)
	end
	local sum = 0
	local id = tostring(block.id or "")
	for i = 1, #id do
		sum = sum + id:byte(i)
	end
	return "BloockyBlock" .. ((sum % M.palette_size) + 1)
end

return M
