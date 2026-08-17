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

	-- The companion-app bus (lua/bloocky/server/) — unrelated to the
	-- calendar sync commands below, which stay gated on sync.enabled.
	vim.api.nvim_create_user_command("BloockyShare", function()
		require("bloocky.server").share()
	end, { desc = "Show the pairing QR for the companion app" })

	vim.api.nvim_create_user_command("BloockyServe", function()
		if require("bloocky.server").start() then
			vim.notify("Bloocky: app server running (:BloockyShare to pair a device)", vim.log.levels.INFO)
		end
	end, { desc = "Start the companion-app server" })

	vim.api.nvim_create_user_command("BloockyServeStop", function()
		require("bloocky.server").stop()
		vim.notify("Bloocky: app server stopped", vim.log.levels.INFO)
	end, { desc = "Stop the companion-app server" })

	-- "auto": pairing is the opt-in. A user who never runs :BloockyShare
	-- runs no server (the paired-device check is one small file read).
	local server_opts = config.options.server or {}
	if server_opts.autostart ~= false and server_opts.enabled ~= false then
		vim.defer_fn(function()
			local should_start = server_opts.enabled == true
				or (server_opts.enabled == "auto" and require("bloocky.server.devices").has_paired_devices())
			if should_start then
				require("bloocky.server").start()
			end
		end, 50)
	end

	if config.options.sync and config.options.sync.enabled then
		local account_names = function()
			local names = {}
			for _, account in ipairs(require("bloocky.sync.account").accounts()) do
				table.insert(names, account.id)
			end
			return names
		end

		vim.api.nvim_create_user_command("BloockySync", function(cmd)
			require("bloocky.sync").run(cmd.args ~= "" and cmd.args or nil)
		end, { nargs = "?", complete = account_names, desc = "Sync blocks with your calendar" })

		vim.api.nvim_create_user_command("BloockySyncStatus", function()
			require("bloocky.sync").status()
		end, { desc = "Show sync status per account" })

		vim.api.nvim_create_user_command("BloockySyncReport", function()
			require("bloocky.sync").report()
		end, { desc = "Show conflicts resolved in favour of the remote calendar" })

		vim.api.nvim_create_user_command("BloockySyncRestore", function(cmd)
			require("bloocky.sync").restore(cmd.args)
		end, { nargs = 1, desc = "Restore a local version that lost a conflict" })

		vim.api.nvim_create_user_command("BloockySyncAuth", function(cmd)
			local account = require("bloocky.sync.account").get(cmd.args)
			if not account then
				vim.notify("Bloocky: no sync account called " .. cmd.args, vim.log.levels.ERROR)
				return
			end
			require("bloocky.sync.oauth").authorize(account, function(err)
				if err then
					vim.notify("Bloocky: authorization failed - " .. err, vim.log.levels.ERROR)
				else
					vim.notify("Bloocky: " .. account.id .. " is authorised", vim.log.levels.INFO)
				end
			end)
		end, { nargs = 1, complete = account_names, desc = "Authorise a sync account with OAuth" })

		vim.api.nvim_create_user_command("BloockySyncRevoke", function(cmd)
			local account = require("bloocky.sync.account").get(cmd.args)
			if not account then
				vim.notify("Bloocky: no sync account called " .. cmd.args, vim.log.levels.ERROR)
				return
			end
			require("bloocky.sync.oauth").revoke(account, function(err)
				vim.notify(
					"Bloocky: token for " .. account.id .. " deleted locally"
						.. (err and (", but the server said: " .. err) or " and revoked upstream"),
					err and vim.log.levels.WARN or vim.log.levels.INFO
				)
			end)
		end, { nargs = 1, complete = account_names, desc = "Revoke and delete a stored OAuth token" })

		vim.api.nvim_create_user_command("BloockySyncReset", function(cmd)
			require("bloocky.sync.store").reset(cmd.args ~= "" and cmd.args or nil)
			vim.notify("Bloocky: sync state cleared; the next sync will be a full one", vim.log.levels.INFO)
		end, { nargs = "?", complete = account_names, desc = "Force a full re-sync" })
	end
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
