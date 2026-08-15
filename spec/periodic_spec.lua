local config = require("bloocky.config")
local sync = require("bloocky.sync")
local ui = require("bloocky.ui")

local function configure(overrides)
	config.options.sync = vim.tbl_extend("force", {
		enabled = true,
		accounts = { { id = "a", provider = "caldav", url = "https://x/", username = "u", password = "p" } },
		-- Minutes, so anything testable has to be a fraction of one.
		interval_min = 0.02, -- 1.2s
		sync_on_open = false,
		sync_on_edit = false,
	}, overrides or {})
end

-- Replace the real sync with a stub that reports whatever we tell it to.
local function with_stub(report, fn)
	local real = ui.sync
	local calls = {}
	ui.sync = function(opts)
		table.insert(calls, opts or {})
		if opts and opts.on_done then
			opts.on_done(report)
		end
	end
	local ok, err = pcall(fn, calls)
	ui.sync = real
	ui.stop_periodic_sync()
	if not ok then
		error(err, 0)
	end
end

-- sync.run hands on_done the *list* of per-account reports.
local function report(errors)
	return { errors = errors or {}, conflicts = {}, reverted = {}, pushed = {}, pulled = {} }
end
local CLEAN = { report() }
local FAILING = { report({ "could not reach the server" }) }
-- The healthy account finished last; the broken one must still be seen.
local MIXED = { report({ "could not reach the server" }), report() }

describe("periodic sync", function()
	describe("scheduling", function()
		it("does not start when the interval is zero", function()
			configure({ interval_min = 0 })
			ui.start_periodic_sync()
			falsy(ui.periodic_state().running)
		end)

		it("does not start when sync is disabled", function()
			configure({ enabled = false })
			ui.start_periodic_sync()
			falsy(ui.periodic_state().running)
		end)

		it("does not start with no accounts", function()
			configure({ accounts = {} })
			ui.start_periodic_sync()
			falsy(ui.periodic_state().running)
		end)

		it("stops on request", function()
			configure()
			ui.start_periodic_sync()
			truthy(ui.periodic_state().running)
			ui.stop_periodic_sync()
			falsy(ui.periodic_state().running)
		end)

		-- Otherwise a laptop that sleeps and wakes accumulates timers.
		it("never leaves two timers running", function()
			configure()
			ui.start_periodic_sync()
			ui.start_periodic_sync()
			ui.start_periodic_sync()
			truthy(ui.periodic_state().running)
			ui.stop_periodic_sync()
			falsy(ui.periodic_state().running)
		end)
	end)

	describe("running", function()
		it("syncs quietly on the interval", function()
			configure()
			ui.open()
			with_stub(CLEAN, function(calls)
				ui.start_periodic_sync()
				vim.wait(4000, function()
					return #calls > 0
				end)
				truthy(#calls > 0, "the timer never fired")
				truthy(calls[1].quiet, "a background sync should not announce routine results")
			end)
			ui.close()
		end)

		it("keeps going after a clean run", function()
			configure()
			ui.open()
			with_stub(CLEAN, function(calls)
				ui.start_periodic_sync()
				vim.wait(6000, function()
					return #calls >= 2
				end)
				truthy(#calls >= 2, "only fired " .. #calls .. " times; it should repeat")
				eq(ui.periodic_state().failures, 0)
			end)
			ui.close()
		end)

		-- The window being gone is the signal to stop; a background timer
		-- hitting somebody's calendar server forever would be rude.
		it("stops itself once the calendar is closed", function()
			configure()
			ui.open()
			with_stub(CLEAN, function(calls)
				ui.start_periodic_sync()
				ui.close()
				vim.wait(3000)
				eq(#calls, 0, "a closed calendar should not keep syncing")
			end)
		end)
	end)

	describe("backing off", function()
		-- A laptop shut in a bag offline for an hour should not have spent that
		-- hour retrying every fifteen minutes.
		it("widens the gap after each failure", function()
			configure()
			ui.open()
			with_stub(FAILING, function(calls)
				ui.start_periodic_sync()
				vim.wait(6000, function()
					return ui.periodic_state().failures >= 2
				end)
				truthy(ui.periodic_state().failures >= 2, "failures were not counted")
			end)
			ui.close()
		end)

		-- Two accounts, one broken, and the healthy one happened to finish
		-- last. The backoff must see the failure anyway.
		it("backs off when any account failed, not just the last one", function()
			configure()
			ui.open()
			with_stub(MIXED, function()
				ui.start_periodic_sync()
				vim.wait(4000, function()
					return ui.periodic_state().failures >= 1
				end)
				truthy(ui.periodic_state().failures >= 1, "a failure hidden behind a healthy account was ignored")
			end)
			ui.close()
		end)

		it("recovers immediately once a sync succeeds", function()
			configure()
			ui.open()
			with_stub(FAILING, function()
				ui.start_periodic_sync()
				vim.wait(4000, function()
					return ui.periodic_state().failures >= 1
				end)
			end)
			truthy(ui.periodic_state().failures >= 1)

			with_stub(CLEAN, function(calls)
				ui.start_periodic_sync()
				vim.wait(4000, function()
					return #calls > 0
				end)
				eq(ui.periodic_state().failures, 0, "one good sync should clear the backoff")
			end)
			ui.close()
		end)

		it("starts a fresh window from a clean slate", function()
			configure()
			ui.open()
			with_stub(FAILING, function()
				ui.start_periodic_sync()
				vim.wait(4000, function()
					return ui.periodic_state().failures >= 1
				end)
			end)
			ui.close()

			ui.open()
			eq(ui.periodic_state().failures, 0, "reopening should not inherit an old backoff")
			ui.close()
			ui.stop_periodic_sync()
		end)
	end)

	-- Being offline is one piece of news, not one every interval.
	describe("repeated failures are reported once", function()
		local function notifications_for(reports)
			local seen = {}
			local real = vim.notify
			vim.notify = function(message)
				table.insert(seen, message)
			end
			for _, report in ipairs(reports) do
				sync.notify_report(report, { quiet = true })
			end
			vim.notify = real
			return seen
		end

		local function failure(account, message)
			return {
				account = account,
				errors = { message },
				conflicts = {},
				reverted = {},
				skipped = {},
				pushed = { created = 0, updated = 0, deleted = 0 },
				pulled = { created = 0, updated = 0, deleted = 0 },
			}
		end

		it("says it once, not every interval", function()
			local seen = notifications_for({
				failure("acct1", "could not reach the server"),
				failure("acct1", "could not reach the server"),
				failure("acct1", "could not reach the server"),
			})
			eq(#seen, 1, "the same failure should not be repeated")
		end)

		it("speaks up when the failure changes", function()
			local seen = notifications_for({
				failure("acct2", "could not reach the server"),
				failure("acct2", "authentication failed"),
			})
			eq(#seen, 2, "a different problem is news")
		end)

		it("speaks up again after recovering", function()
			local clean = {
				account = "acct3",
				errors = {},
				conflicts = {},
				reverted = {},
				skipped = {},
				pushed = { created = 1, updated = 0, deleted = 0 },
				pulled = { created = 0, updated = 0, deleted = 0 },
			}
			local seen = notifications_for({
				failure("acct3", "could not reach the server"),
				clean,
				failure("acct3", "could not reach the server"),
			})
			eq(#seen, 3, "the failure is news again after a good sync")
		end)

		-- Silence must never swallow something that needs acting on.
		it("never suppresses a conflict", function()
			local with_conflict = failure("acct4", "could not reach the server")
			with_conflict.conflicts = { { title = "Standup" } }
			local seen = notifications_for({
				failure("acct4", "could not reach the server"),
				with_conflict,
			})
			eq(#seen, 2, "a conflict must always be reported")
		end)

		it("never suppresses actual progress", function()
			local with_change = failure("acct5", "could not reach the server")
			with_change.pushed = { created = 1, updated = 0, deleted = 0 }
			local seen = notifications_for({
				failure("acct5", "could not reach the server"),
				with_change,
			})
			eq(#seen, 2)
		end)
	end)
end)

-- Config problems are static: they do not change between syncs, so repeating
-- them every interval is pure noise.
describe("config problems are reported once", function()
	local function run_twice(account)
		local seen = {}
		local real = vim.notify
		vim.notify = function(message)
			table.insert(seen, message)
		end
		config.options.sync = { enabled = true, accounts = { account } }
		local done = 0
		sync.run(account.id, function()
			done = done + 1
		end, { quiet = true })
		vim.wait(3000, function()
			return done >= 1
		end)
		sync.run(account.id, function()
			done = done + 1
		end, { quiet = true })
		vim.wait(3000, function()
			return done >= 2
		end)
		vim.notify = real
		return seen
	end

	it("says a fatal config error once on background syncs", function()
		-- A unique id per test, since the dedupe is keyed by account.
		local seen = run_twice({
			id = "spec-fatal-once",
			provider = "caldav",
			url = "http://insecure.example.com/",
			username = "u",
			password = "p",
		})
		local fatal = vim.tbl_filter(function(message)
			return message:find("https", 1, true) ~= nil
		end, seen)
		eq(#fatal, 1, "the same misconfiguration should not be reported every interval")
	end)

	it("says a plain-text password warning once", function()
		local seen = run_twice({
			id = "spec-warn-once",
			provider = "caldav",
			url = "http://insecure.example.com/",
			username = "u",
			password = "p",
		})
		local warnings = vim.tbl_filter(function(message)
			return message:find("plain text", 1, true) ~= nil
		end, seen)
		eq(#warnings, 1)
	end)
end)
