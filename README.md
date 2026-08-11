# Bloocky

A timeblocking calendar for Neovim. Plan your day by placing time blocks on a calendar with **day**, **week** and **month** views, navigate everything with `hjkl`, and optionally bring your [Dooing](https://github.com/atiladefreitas/dooing) tasks straight onto the calendar.

![bloocky — week view with the day view alongside](docs/overview.png)

---

## 🚀 Features

- 📅 **Three views** — full month calendar, week grid with hour rows, and a detailed day view
- 🧭 **`hjkl` navigation** — move across days and hours; `H`/`L` jump a whole month or week
- 🪟 **Float or sidebar** — a centered floating window by default, or a persistent split you keep open next to your code while you work
- 🖥️ **Sized how you like it** — per-view width and height, up to `"full"` for a calendar that fills the whole editor
- 🧱 **Time blocks** — give an action a start time and a duration, and see it spread over the grid as a colored block
- 🔁 **Recurring blocks** — daily, weekly, weekdays (Mon–Fri) or a custom set of days, with an optional end date
- 🗨️ **Creation dialog** — a floating form with inline hints; blocks snap to a configurable granularity (30 min by default)
- ✅ **[Dooing](https://github.com/atiladefreitas/dooing) integration** — opt-in, read-only: your [Dooing](https://github.com/atiladefreitas/dooing) todos show up on their due date with estimate and priorities, without ever touching Dooing's data
- 🕐 **Configurable working hours** — decide which hour your day starts and ends, and whether the week starts on Sunday or Monday
- 💾 **Automatic persistence** — blocks are saved to a JSON file on every change

---

## 📦 Installation

### Prerequisites

- Neovim `>= 0.10.0`
- A [Nerd Font](https://www.nerdfonts.com/) for the icons (optional, icons are configurable)

### Using Lazy.nvim

```lua
{
    "atiladefreitas/bloocky",
    config = function()
        require("bloocky").setup({
            -- your custom config here (optional)
        })
    end,
}
```

---

## ⚙️ Configuration

### Default Configuration

```lua
{
    -- Where time blocks are persisted
    save_path = vim.fn.stdpath("data") .. "/bloocky_blocks.json",

    -- View shown when the calendar opens: "day" | "week" | "month"
    default_view = "week",

    -- First day of the week: "sunday" | "monday"
    week_start = "sunday",

    -- Visible hour range in the day and week views
    hours = {
        start = 5,     -- first hour shown (05:00)
        ["end"] = 22,  -- last hour shown (22:00)
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
            width = 46,         -- columns (or a fraction of the editor width if <= 1)
            view = "day",       -- view the sidebar opens in
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
            enabled = false,   -- show Dooing todos on their due date
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
```

---

## 🔑 Default Keybindings

### Global

| Key          | Action                                       |
| ------------ | -------------------------------------------- |
| `<leader>tb` | Toggle the calendar                          |
| `<leader>tB` | Toggle the calendar as a sidebar in day view |

### Inside the calendar

| Key            | Action                                              |
| -------------- | --------------------------------------------------- |
| `h` / `l`      | Previous / next day                                 |
| `j` / `k`      | Next / previous hour (week/day) or week (month)     |
| `H` / `L`      | Previous / next month (month view) or week          |
| `gd` `gw` `gm` | Switch to day / week / month view                   |
| `<Tab>`        | Cycle through the views                             |
| `t`            | Jump to today                                       |
| `a`            | Create a block at the cursor slot                   |
| `<CR>`         | Edit the block under the cursor (or create one)     |
| `x`            | Delete the block under the cursor                   |
| `q` / `<Esc>`  | Close the calendar (`<Esc>` in floating mode only)  |

### Inside the block dialog

| Key               | Action                                        |
| ----------------- | --------------------------------------------- |
| `<Tab>` / `<S-Tab>` | Next / previous field                       |
| `<CR>` (insert)   | Next field (saves from the last one)          |
| `<CR>` (normal)   | Save                                          |
| `<C-s>`           | Save                                          |
| `j` / `k`         | Move between fields                           |
| `dd`              | Clear the current field                       |
| `q` / `<Esc>`     | Cancel                                        |

Invalid fields are marked inline with the reason — fix them and save again.

---

## 📝 Commands

- `:Bloocky [day|week|month]` — open the calendar (optionally in a specific view)
- `:BloockyToggle` — toggle the calendar
- `:BloockySidebar [day|week|month]` — open the calendar as a sidebar
- `:BloockySidebarToggle [day|week|month]` — toggle the sidebar
- `:BloockyAdd` — open the calendar and jump straight into the creation dialog

---

## 🔧 Usage

1. Open the calendar with `<leader>tb` (or `:Bloocky`)
2. Move around with `hjkl`; the highlighted slot is your cursor
3. Press `a` (or `<CR>` on an empty slot) to open the block dialog
4. Fill in the fields — `Duration` accepts `1h30m`, `45m`, `2h`, `90`; set `Repeat` to `daily`, `weekly`, `weekdays` or `custom` (with `Days: mon,wed,fri`) and an optional `Until` date for recurring blocks
5. Save with `<CR>`, and watch the block spread over its hours on the grid
6. `<CR>` on an existing block edits it, `x` deletes it (recurring blocks delete the whole series)

---

## ✅ [Dooing](https://github.com/atiladefreitas/dooing) integration

If you use [Dooing](https://github.com/atiladefreitas/dooing), enable the integration to see your todos on the calendar:

```lua
require("bloocky").setup({
    integrations = {
        dooing = {
            enabled = true,
        },
    },
})
```

Todos with a due date appear on their due day — in the month view as `◆` entries, in the week view as a `due` strip above the grid, and in the day view as a section listing the time estimate and priorities. Overdue todos are highlighted in red. The integration is **read-only**: Bloocky never modifies [Dooing](https://github.com/atiladefreitas/dooing)'s data.

---

## 🎨 Customization

### Working hours and week start

```lua
require("bloocky").setup({
    week_start = "monday",
    hours = { start = 8, ["end"] = 18 },
})
```

### Full screen

To give every view the whole editor, set both sizes to `"full"`:

```lua
require("bloocky").setup({
    window = {
        width = "full",
        height = "full",
    },
})
```

The grid stretches to match: hour slots grow taller instead of leaving the bottom of the window empty, month cells take the spare rows, and the columns share out the cells that do not divide evenly, so the day/week/month grids cover the window exactly.

Both accept a value per view, so you can single out one of them:

```lua
require("bloocky").setup({
    window = {
        width = { month = "full", week = "full", day = 46 },
        height = { month = "full", week = "full", day = "auto" },
    },
})
```

`height = "auto"` (the default) keeps the floating window as tall as its content. A number works like `width`: a fraction of the editor, or absolute rows above `1`. In sidebar mode the split already spans the full height — `height = "full"` there just stretches the grid down to fill it.

### Float or sidebar

By default the calendar opens as a centered floating window. `<leader>tB` opens it instead as a **sidebar** — a regular vertical split, in day view, that stays put while you work in the other windows:

```lua
require("bloocky").setup({
    window = {
        sidebar = {
            position = "left", -- put it on the left instead
            width = 0.25,      -- a quarter of the editor (or pass columns, e.g. 46)
            view = "week",     -- open the sidebar in week view
        },
    },
})
```

To make the sidebar the default for `<leader>tb` and `:Bloocky` as well, set the mode:

```lua
require("bloocky").setup({
    window = { mode = "sidebar" },
})
```

Both modes share the same keymaps, cursor and views, so you can switch between them at any time — `<leader>tB` from an open float moves the calendar into the sidebar without losing your place. The sidebar puts its title in the winbar, respects a width you resize by hand, and does not bind `<Esc>` to close.

### Highlight groups

All groups are defined with `default = true`, so you can override them in your colorscheme:

`BloockyHeader`, `BloockyTime`, `BloockyGrid`, `BloockyToday`, `BloockyCursor`, `BloockyOtherMonth`, `BloockyMore`, `BloockyDooing`, `BloockyDooingDone`, `BloockyDooingOverdue`, and the block palette `BloockyBlock1` … `BloockyBlock6`.

```lua
vim.api.nvim_set_hl(0, "BloockyBlock1", { fg = "#ffffff", bg = "#005f87" })
vim.api.nvim_set_hl(0, "BloockyToday", { fg = "#ff9e64", bold = true })
```

---

## 📄 License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

## 🤝 Contributing

Contributions are welcome! Feel free to open issues or submit pull requests.

---

Made with ❤️ for the Neovim community. If you find any issues or have suggestions, reach out at contact@atiladefreitas.com
