local M = {}

M.options = {
	-- Where time blocks are persisted
	save_path = vim.fn.stdpath("data") .. "/bloocky_blocks.json",

	-- View shown when the calendar opens: "day" | "week" | "month"
	default_view = "week",

	-- First day of the week: "sunday" | "monday"
	week_start = "sunday",

	-- Visible hour range in the day and week views
	hours = {
		start = 5, -- first hour shown (05:00)
		["end"] = 22, -- last hour shown (22:00)
	},

	-- Block start/duration are snapped to this many minutes
	granularity = 30,

	window = {
		-- How the calendar is displayed: "float" | "sidebar"
		mode = "float",

		-- Width per view: fraction of the editor width (or absolute columns if > 1),
		-- or "full" for everything the editor has. A single value applies to
		-- every view. Floating mode only.
		width = {
			month = 0.8,
			week = 0.6,
			day = 46,
		},

		-- Height per view: "auto" fits the window to its content, "full" takes
		-- every row available, a number is a fraction of the editor height (or
		-- absolute rows if > 1). Anything but "auto" stretches the grid to fill
		-- the window. A single value applies to every view.
		height = "auto",

		border = "rounded",

		-- Used when the calendar opens as a sidebar (a regular vertical split)
		sidebar = {
			position = "right", -- "left" | "right"
			width = 46, -- columns (or a fraction of the editor width if <= 1)
			view = "day", -- view the sidebar opens in
		},
	},

	icons = {
		block = "▎",
		dooing = "◆",
		recurring = "󰑖",
		conflict = "󰀦", -- the calendar overwrote this block
		readonly = "󰌾", -- lives on a calendar bloocky cannot write to
	},

	-- Two-way sync with a real calendar. See docs/two-way-sync.md.
	-- Works with CalDAV servers and with Google Calendar.
	sync = {
		enabled = false,

		-- Where sync bookkeeping lives: which block maps to which remote event,
		-- pending deletions, per-calendar cursors and the conflict trail.
		-- Defaults to bloocky_sync.json next to save_path.
		store_path = nil,

		-- Pull when the calendar window opens. The window appears immediately
		-- and a small indicator shows while the sync runs.
		sync_on_open = true,

		-- Push after you add, edit or delete a block. Debounced, so a burst of
		-- edits costs one sync rather than one each.
		sync_on_edit = true,
		edit_debounce_ms = 1500,

		-- Keep syncing every N minutes while the calendar window is open.
		-- 0 turns it off. Backs off after failures rather than hammering a
		-- server that is down, or your battery when you are offline.
		interval_min = 15,

		-- How much of the calendar to keep in step. Everything outside this
		-- window is left alone on the server.
		window = {
			past_days = 30,
			future_days = 180,
		},

		conflict = {
			-- How many overwritten local versions to keep for :BloockySyncRestore
			trail_limit = 50,
		},

		-- One entry per calendar account.
		--
		--   {
		--     id = "work",
		--     provider = "caldav",
		--     url = "https://caldav.fastmail.com/dav/",
		--     username = "me@fastmail.com",
		--     -- Any command that prints the password on stdout. Preferred over
		--     -- `password`, which would sit in plain text in your config.
		--     -- Whichever you already have, for example:
		--     --   { "pass", "show", "fastmail/caldav" }
		--     --   { "secret-tool", "lookup", "service", "bloocky", "key", "caldav" }
		--     --   { "cat", vim.fn.expand("~/.config/bloocky/caldav-password") }
		--     password_cmd = { "secret-tool", "lookup", "service", "bloocky", "key", "caldav" },
		--     -- Omit to sync every calendar the server offers.
		--     calendars = {
		--       { name = "Work", mode = "rw", default = true },
		--       { name = "Team", mode = "ro" },  -- shown, never written to
		--     },
		--   }
		--
		-- Google uses your own OAuth client, from a Google Cloud project you
		-- create. bloocky ships no client id on purpose: a shared one would
		-- put every user behind the same credential and the same unverified-app
		-- warning. Run :BloockySyncAuth <id> once to authorise.
		--
		--   {
		--     id = "personal",
		--     provider = "google",
		--     client_id = "xxxx.apps.googleusercontent.com",
		--     -- Optional. A "Desktop app" client secret is not confidential
		--     -- (RFC 8252) and PKCE is what protects the exchange, so you can
		--     -- leave this out entirely if Google accepts the grant without it.
		--     client_secret_cmd = { "secret-tool", "lookup", "service", "bloocky", "key", "google" },
		--     calendar_id = "you@gmail.com",  -- defaults to `username`
		--   }
		--
		-- New blocks are created in the default calendar of the first account.
		accounts = {},
	},

	-- Bring tasks from other plugins into the calendar
	integrations = {
		dooing = {
			enabled = false, -- show dooing.nvim todos on their due date
			show_done = false, -- also show completed todos
		},
	},

	keymaps = {
		-- Global
		toggle = "<leader>tb",
		toggle_sidebar = "<leader>tB",

		-- Inside the calendar window
		calendar = {
			nav_left = "h",
			nav_down = "j",
			nav_up = "k",
			nav_right = "l",
			prev_period = "H", -- previous month/week (depends on view)
			next_period = "L", -- next month/week
			view_day = "gd",
			view_week = "gw",
			view_month = "gm",
			cycle_view = "<Tab>",
			today = "t",
			add = "a",
			edit = "<CR>",
			delete = "x",
			sync = "s", -- sync now (only bound when sync.enabled)
			close = "q",
		},
	},
}

-- Merge user options with defaults
function M.setup(opts)
	if opts then
		M.options = vim.tbl_deep_extend("force", M.options, opts)
	end
end

return M
