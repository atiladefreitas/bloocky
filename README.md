# Bloocky

A timeblocking calendar for Neovim. Plan your day by placing time blocks on a calendar with **day**, **week** and **month** views, navigate everything with `hjkl`, and optionally bring your [Dooing](https://github.com/atiladefreitas/dooing) tasks straight onto the calendar.

> ### 🔄 Two-way calendar sync
>
> Bloocky syncs with **CalDAV** (Fastmail, Nextcloud, iCloud, Radicale…) and **Google Calendar** — blocks you make in Neovim appear in your calendar, and your real events appear on the grid.
>
> **→ [Read the calendar guide](CALENDARS.md)** for setup, security and limits.
>
> *(Proton Calendar cannot be supported — it has no CalDAV. [Why](CALENDARS.md#why-proton-cannot-work).)*

> ### 📱 Companion app
>
> Bloocky serves your **local** blocks to a companion app over your LAN — pair a phone by scanning a QR with `:BloockyShare`, and edits made on either side are merged, not overwritten.
>
> **→ [Read the protocol](docs/APP-SYNC.md)** — it is off until you pair something, and every route needs a paired token.

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
- 🔄 **[Two-way calendar sync](CALENDARS.md)** — CalDAV and Google Calendar, both directions, with conflicts surfaced and recoverable rather than silently resolved
- 📅 **All-day events** — imported from your calendar and shown *above* the hour grid, spanning every day they cover, because a date is not a time
- 📱 **[Companion app sync](docs/APP-SYNC.md)** — opt-in LAN bus for your local blocks, paired by QR, three-way merged
- ✅ **[Dooing](https://github.com/atiladefreitas/dooing) integration** — opt-in, read-only: your [Dooing](https://github.com/atiladefreitas/dooing) todos show up on their due date with estimate and priorities, without ever touching Dooing's data
- 🕐 **Configurable working hours** — decide which hour your day starts and ends, and whether the week starts on Sunday or Monday
- 💾 **Automatic persistence** — blocks are saved to a JSON file on every change
- 🩺 **`:checkhealth bloocky`** — verifies the things that fail quietly, whether or not you use sync

---

## 📦 Installation

### Prerequisites

- Neovim `>= 0.10.0`
- A [Nerd Font](https://www.nerdfonts.com/) for the icons (optional, icons are configurable)
- `curl` — only if you turn on calendar sync; every network call goes through it

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
        all_day = "󰃭",   -- a date-based block, shown above the hour grid
        conflict = "󰀦",  -- the calendar overwrote this block
        readonly = "󰌾",  -- lives on a calendar bloocky cannot write to
    },

    -- Two-way sync with a real calendar. Off by default.
    -- Accounts and the rest of the options: see CALENDARS.md
    sync = {
        enabled = false,
        accounts = {},

        -- Sync bookkeeping (mappings, cursors, the conflict trail).
        -- nil puts bloocky_sync.json next to save_path.
        store_path = nil,

        sync_on_open = true,      -- pull when the calendar opens
        sync_on_edit = true,      -- push after a block changes (debounced)
        edit_debounce_ms = 1500,
        interval_min = 15,        -- keep syncing while the window is open; 0 disables

        window = { past_days = 30, future_days = 180 },
        conflict = { trail_limit = 50 },
    },

    -- The companion-app bus: bloocky's own LAN server for your LOCAL blocks.
    -- Independent of the calendar sync above. See docs/APP-SYNC.md
    server = {
        -- "auto"  start on setup only if a device has been paired
        -- true    always start on setup
        -- false   never start automatically (:BloockyServe still works)
        enabled = "auto",
        autostart = true,   -- false: never start on startup, whatever `enabled` says
        port = 7284,
        bind = "0.0.0.0",   -- "127.0.0.1" for tunnel-only setups
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
            sync = "s",       -- only bound when sync is enabled
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
| `s`            | Sync with your calendar now (only when sync is on)  |
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
- `:checkhealth bloocky` — verify your setup end to end (works with or without sync)

### Calendar sync

Only registered when sync is enabled — see the [calendar guide](CALENDARS.md).

- `:BloockySync [account]` — sync now
- `:BloockySyncStatus` — last sync, pending changes and problems per account
- `:BloockySyncReport` — conflicts resolved in the calendar's favour
- `:BloockySyncRestore <n>` — restore a losing local version as a new block
- `:BloockySyncAuth <account>` — run the OAuth flow (Google)
- `:BloockySyncRevoke <account>` — revoke and delete a stored token
- `:BloockySyncReset [account]` — force a full re-sync

### Companion app

Always registered — the server itself stays off until you pair something.

- `:BloockyShare` — open the pairing QR in your browser
- `:BloockyServe` — start the app server by hand
- `:BloockyServeStop` — stop it

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

## 🔄 Calendar sync

Bloocky keeps your blocks in step with a real calendar, in both directions:

```lua
require("bloocky").setup({
    sync = {
        enabled = true,
        accounts = {
            {
                id = "work",
                provider = "caldav",
                url = "https://caldav.fastmail.com/dav/",
                username = "you@fastmail.com",
                password_cmd = { "secret-tool", "lookup", "service", "bloocky", "key", "caldav" },
            },
        },
    },
})
```

Press `s` in the calendar to sync, or let it happen on open and after each edit. Google Calendar works too, with your own OAuth client.

**[Full guide → CALENDARS.md](CALENDARS.md)** — CalDAV and Google setup, keeping secrets out of your config, how conflicts are handled, what it will and will not write back, and troubleshooting.

---

## 📱 Companion app

Bloocky runs its own small server on your LAN so a companion app can reach your time blocks. Nothing is exposed until you pair a device:

```
:BloockyShare
```

Your browser opens a QR code; scan it from the app. From then on the server starts with Neovim (`server.enabled = "auto"`) and every route needs that device's token.

**One road per block.** Blocks backed by a calendar account converge through the calendar — both Neovim and your phone are already clients of it — so only your **local** blocks travel this bus. The app can display calendar-backed blocks but cannot push them back; sending one is rejected outright rather than merged into a duplicate.

Edits from both sides are three-way merged rather than last-write-wins: a title changed on your phone and a time changed in Neovim both survive. When two edits genuinely clash, the losing version is kept so nothing is destroyed silently.

Some things worth knowing:

- The QR page is served over plain HTTP and holds a token valid for **10 minutes**, single use, dead when Neovim exits.
- Device tokens are stored **hashed**, so `devices.json` leaking does not leak a credential.
- `bind = "127.0.0.1"` keeps it off the LAN entirely if you would rather reach it through a tunnel.
- `enabled = false` means it never starts on its own; `:BloockyServe` still works.

**[Protocol → docs/APP-SYNC.md](docs/APP-SYNC.md)** — routes, pairing, the merge rules and the wire shape. Normative, if you are writing a client.

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

| Group | |
| --- | --- |
| `BloockyHeader` `BloockyTime` `BloockyGrid` | chrome — titles, the hour gutter, grid lines |
| `BloockyToday` `BloockyCursor` `BloockyOtherMonth` `BloockyMore` | the month/week grid |
| `BloockyBlock1` … `BloockyBlock6` | the block palette, cycled per block (or per calendar when synced) |
| `BloockyBlockConflict` | a block the calendar overwrote, until you read the report |
| `BloockySyncStatus` | the `syncing` indicator |
| `BloockyInput` `BloockyInputBar` `BloockyError` | the block dialog: fields, the active field, an invalid one |
| `BloockyDooing` `BloockyDooingDone` `BloockyDooingOverdue` | Dooing todos on the grid |

```lua
vim.api.nvim_set_hl(0, "BloockyBlock1", { fg = "#ffffff", bg = "#005f87" })
vim.api.nvim_set_hl(0, "BloockyToday", { fg = "#ff9e64", bold = true })
```

---

## 📚 Documentation

| | |
| --- | --- |
| [CALENDARS.md](CALENDARS.md) | Two-way calendar sync — CalDAV and Google setup, secrets, conflicts, limits, troubleshooting |
| [docs/APP-SYNC.md](docs/APP-SYNC.md) | The companion-app LAN protocol. Normative |
| [docs/block-structure.md](docs/block-structure.md) | The block JSON format, for anything else that reads or writes the file |

---

## 📄 License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

## 🤝 Contributing

Contributions are welcome! Feel free to open issues or submit pull requests.

The test suite runs with `scripts/test.sh` (Neovim itself is the interpreter, so
specs get the real `vim` API). Please keep it green.

---

Made with ❤️ for the Neovim community. If you find any issues or have suggestions, reach out at contact@atiladefreitas.com
