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

		-- Width per view: fraction of the editor width (or absolute columns if > 1).
		-- A single number applies to every view. Floating mode only.
		width = {
			month = 0.8,
			week = 0.6,
			day = 46,
		},
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
