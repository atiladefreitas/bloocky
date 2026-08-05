local M = {}

-- Initialize bloocky with user options
function M.setup(opts)
	local config = require("bloocky.config")
	config.setup(opts)

	require("bloocky.highlights").setup()
	require("bloocky.state").load_blocks()

	vim.api.nvim_create_autocmd("ColorScheme", {
		group = vim.api.nvim_create_augroup("BloockyHighlights", { clear = true }),
		callback = function()
			require("bloocky.highlights").setup()
		end,
	})

	local keymaps = config.options.keymaps
	if keymaps.toggle then
		vim.keymap.set("n", keymaps.toggle, function()
			require("bloocky.ui").toggle()
		end, { noremap = true, silent = true, desc = "Bloocky: toggle calendar" })
	end

	vim.api.nvim_create_user_command("Bloocky", function(cmd)
		local view = cmd.args ~= "" and cmd.args or nil
		require("bloocky.ui").open(view)
	end, {
		nargs = "?",
		complete = function()
			return { "day", "week", "month" }
		end,
		desc = "Open the Bloocky calendar",
	})

	vim.api.nvim_create_user_command("BloockyToggle", function()
		require("bloocky.ui").toggle()
	end, { desc = "Toggle the Bloocky calendar" })

	vim.api.nvim_create_user_command("BloockyAdd", function()
		local ui = require("bloocky.ui")
		ui.open()
		ui.add_block()
	end, { desc = "Create a new time block" })
end

function M.open(view)
	require("bloocky.ui").open(view)
end

function M.toggle(view)
	require("bloocky.ui").toggle(view)
end

function M.close()
	require("bloocky.ui").close()
end

return M
