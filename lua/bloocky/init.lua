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
	if keymaps.toggle_sidebar then
		vim.keymap.set("n", keymaps.toggle_sidebar, function()
			require("bloocky.ui").toggle_sidebar()
		end, { noremap = true, silent = true, desc = "Bloocky: toggle calendar sidebar" })
	end

	local views = function()
		return { "day", "week", "month" }
	end

	vim.api.nvim_create_user_command("Bloocky", function(cmd)
		local view = cmd.args ~= "" and cmd.args or nil
		require("bloocky.ui").open(view)
	end, {
		nargs = "?",
		complete = views,
		desc = "Open the Bloocky calendar",
	})

	vim.api.nvim_create_user_command("BloockyToggle", function()
		require("bloocky.ui").toggle()
	end, { desc = "Toggle the Bloocky calendar" })

	vim.api.nvim_create_user_command("BloockySidebar", function(cmd)
		local view = cmd.args ~= "" and cmd.args or nil
		require("bloocky.ui").open_sidebar(view)
	end, {
		nargs = "?",
		complete = views,
		desc = "Open the Bloocky calendar as a sidebar",
	})

	vim.api.nvim_create_user_command("BloockySidebarToggle", function(cmd)
		local view = cmd.args ~= "" and cmd.args or nil
		require("bloocky.ui").toggle_sidebar(view)
	end, {
		nargs = "?",
		complete = views,
		desc = "Toggle the Bloocky calendar sidebar",
	})

	vim.api.nvim_create_user_command("BloockyAdd", function()
		local ui = require("bloocky.ui")
		ui.open()
		ui.add_block()
	end, { desc = "Create a new time block" })
end

-- `opts` is a view name, or { view = "day"|"week"|"month", mode = "float"|"sidebar" }
function M.open(opts)
	require("bloocky.ui").open(opts)
end

function M.toggle(opts)
	require("bloocky.ui").toggle(opts)
end

function M.open_sidebar(view)
	require("bloocky.ui").open_sidebar(view)
end

function M.toggle_sidebar(view)
	require("bloocky.ui").toggle_sidebar(view)
end

function M.close()
	require("bloocky.ui").close()
end

return M
