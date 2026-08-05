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
	for i, color in ipairs(palette) do
		set("BloockyBlock" .. i, { fg = color.fg, bg = color.bg })
	end
end

-- Stable color per block, derived from its id
function M.block_group(block)
	local sum = 0
	local id = tostring(block.id or "")
	for i = 1, #id do
		sum = sum + id:byte(i)
	end
	return "BloockyBlock" .. ((sum % M.palette_size) + 1)
end

return M
