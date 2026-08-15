local config = require("bloocky.config")
local ui = require("bloocky.ui")

-- Swap in a counting stub for the real sync, so these tests never touch a
-- network and only assert on *when* a sync is asked for.
local function with_stub(fn)
	local real = ui.sync
	local calls = {}
	ui.sync = function(opts)
		table.insert(calls, opts or {})
	end
	local ok, err = pcall(fn, calls)
	ui.sync = real
	if not ok then
		error(err, 0)
	end
end

local function configure(sync)
	config.options.sync = vim.tbl_extend("force", {
		enabled = true,
		accounts = { { id = "a", provider = "caldav", url = "https://x/", username = "u", password = "p" } },
		edit_debounce_ms = 40,
	}, sync or {})
end

describe("ui sync triggers", function()
	describe("debouncing edits", function()
		-- A burst of edits must cost one sync, not one each: five rapid saves
		-- should not mean five round trips to somebody's calendar server.
		it("collapses a burst into a single sync", function()
			configure()
			with_stub(function(calls)
				for _ = 1, 5 do
					ui.schedule_sync()
				end
				eq(#calls, 0, "nothing should fire while edits are still arriving")
				vim.wait(300, function()
					return #calls > 0
				end)
				eq(#calls, 1, "five edits should produce one sync")
			end)
		end)

		it("syncs quietly, since the user did not ask for it", function()
			configure()
			with_stub(function(calls)
				ui.schedule_sync()
				vim.wait(300, function()
					return #calls > 0
				end)
				truthy(calls[1].quiet, "an automatic sync should not announce an uneventful result")
			end)
		end)

		it("does nothing when sync is disabled", function()
			configure({ enabled = false })
			with_stub(function(calls)
				ui.schedule_sync()
				vim.wait(200)
				eq(#calls, 0)
			end)
		end)

		it("does nothing when no accounts are configured", function()
			configure({ accounts = {} })
			with_stub(function(calls)
				ui.schedule_sync()
				vim.wait(200)
				eq(#calls, 0)
			end)
		end)

		it("respects sync_on_edit = false", function()
			configure({ sync_on_edit = false })
			with_stub(function(calls)
				ui.schedule_sync()
				vim.wait(200)
				eq(#calls, 0)
			end)
		end)
	end)

	describe("opening the calendar", function()
		it("returns before any sync runs", function()
			configure()
			with_stub(function(calls)
				ui.open()
				-- The window has to be on screen first; the sync is deferred.
				truthy(ui.is_open())
				eq(#calls, 0, "opening must not wait on the network")
				vim.wait(300, function()
					return #calls > 0
				end)
				eq(#calls, 1)
				truthy(calls[1].quiet)
				ui.close()
			end)
		end)

		it("does not sync on open when told not to", function()
			configure({ sync_on_open = false })
			with_stub(function(calls)
				ui.open()
				vim.wait(200)
				eq(#calls, 0)
				ui.close()
			end)
		end)

		it("does not sync on open when sync is off", function()
			configure({ enabled = false })
			with_stub(function(calls)
				ui.open()
				vim.wait(200)
				eq(#calls, 0)
				ui.close()
			end)
		end)
	end)

	describe("the sync keymap", function()
		it("is bound inside the calendar when sync is on", function()
			configure()
			config.options.keymaps.calendar.sync = "s"
			ui.open()
			local found = false
			for _, map in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_win_get_buf(0), "n")) do
				if map.lhs == "s" then
					found = true
				end
			end
			ui.close()
			truthy(found, "`s` should sync from inside the calendar")
		end)

		-- Otherwise `s` would shadow the built-in substitute for no benefit.
		it("is left alone when sync is off", function()
			configure({ enabled = false })
			ui.open()
			local found = false
			for _, map in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_win_get_buf(0), "n")) do
				if map.lhs == "s" then
					found = true
				end
			end
			ui.close()
			falsy(found, "an unused key should not be taken over")
		end)
	end)

	describe("the syncing indicator", function()
		it("appears and goes away again", function()
			configure()
			ui.open()
			local before = #vim.api.nvim_list_wins()
			ui.show_status("syncing")
			truthy(#vim.api.nvim_list_wins() > before, "the indicator should be visible")
			ui.hide_status()
			eq(#vim.api.nvim_list_wins(), before, "and gone once the sync finishes")
			ui.close()
		end)

		-- Two syncs can overlap; the first to finish must not clear the other's
		-- indicator.
		it("survives overlapping syncs", function()
			configure()
			ui.open()
			local before = #vim.api.nvim_list_wins()
			ui.show_status("syncing")
			ui.show_status("syncing")
			ui.hide_status()
			truthy(#vim.api.nvim_list_wins() > before, "still syncing, so it should still show")
			ui.hide_status()
			eq(#vim.api.nvim_list_wins(), before)
			ui.close()
		end)

		it("never outlives the calendar window", function()
			configure()
			ui.open()
			local before = #vim.api.nvim_list_wins()
			ui.show_status("syncing")
			ui.close()
			truthy(#vim.api.nvim_list_wins() < before, "closing the calendar must take the indicator with it")
		end)
	end)
end)
