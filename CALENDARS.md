# Calendars

Bloocky can keep your time blocks in step with a real calendar, in both directions: blocks you create in Neovim show up in your calendar, and events from your calendar show up on the grid — editable, deletable, and kept in sync.

---

## What works

| Provider | Status |
| --- | --- |
| **CalDAV** — Fastmail, Nextcloud, iCloud, Radicale, mailbox.org, Migadu | ✅ Supported |
| **Google Calendar** | ✅ Supported (needs your own OAuth client — see below) |
| **Proton Calendar** | ❌ Not possible |
| Outlook / Microsoft 365 | ⚠️ Untested; it speaks CalDAV, so it may work |

### Why Proton cannot work

Proton Calendar has no CalDAV support, and that is not an oversight they intend to fix — it is a consequence of their end-to-end encryption. No third-party client can reach it: not Thunderbird, not Apple Calendar, not DAVx⁵, not Bloocky. Proton Mail Bridge does not help either; it handles mail only.

The only external surface Proton offers is a read-only "share via link" `.ics`, which could one day let Bloocky *display* a Proton calendar but could never write to it. If you use Proton, there is nothing to configure here.

---

## Quick start

Sync is off by default. Turn it on and add one account:

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

Then open the calendar and press `s`, or run `:BloockySync`.

> **Try it against a throwaway calendar first.** Bloocky can delete remote events. Point it at a scratch calendar until you trust it.

---

## CalDAV

### Finding your URL

Most servers accept the base DAV URL and discover the rest themselves.

| Provider | URL |
| --- | --- |
| Fastmail | `https://caldav.fastmail.com/dav/` |
| iCloud | `https://caldav.icloud.com/` |
| Nextcloud | `https://your-host/remote.php/dav/` |
| mailbox.org | `https://dav.mailbox.org/` |
| Radicale (local) | `http://localhost:5232/` |

**Use an app-specific password**, never your account password. Fastmail, iCloud and Google all issue them; they are revocable on their own and limited to one protocol.

### Choosing calendars

Omit `calendars` entirely and Bloocky syncs every calendar the server offers. To be selective — and to mark one you never want written to:

```lua
{
    id = "work",
    provider = "caldav",
    url = "https://caldav.fastmail.com/dav/",
    username = "you@fastmail.com",
    password_cmd = { "secret-tool", "lookup", "service", "bloocky", "key", "caldav" },
    calendars = {
        { name = "Work",   mode = "rw", default = true },
        { name = "Team",   mode = "ro" },  -- displayed, never written to
        { name = "Shared", mode = "ro" },
    },
}
```

`default = true` marks where new blocks are created. A calendar the server itself reports as read-only is treated as `ro` regardless of what you put here.

---

## Google Calendar

Google needs an OAuth client, and **it has to be yours** — Bloocky deliberately ships none. A shared client would put every user behind one credential (so one person's abuse could get it suspended for everyone) and behind the same "this app isn't verified" warning, which trains people to click through security prompts. Your own client is isolated, scoped and revocable by you.

It takes about five minutes, once.

### 1. Create the OAuth client

1. Go to [console.cloud.google.com](https://console.cloud.google.com) and create a project.
2. **Enable the Google Calendar API** for it.
3. Configure the **OAuth consent screen**: type *External*, and add your own Google account under **Test users**.
4. **Credentials → Create credentials → OAuth client ID**, application type **Desktop app**.
5. Copy the **client ID** and the **client secret**.

> ⚠️ **It must be "Desktop app".** A *Web application* client rejects the loopback redirect Bloocky uses and fails with `redirect_uri_mismatch`. This is the single most common setup mistake.

> ⚠️ **You are not exempt from the test-user list.** An unverified External consent screen only admits accounts explicitly added as test users, including the account that owns the project.

### 2. Store the client secret

The secret is required — Google's token endpoint rejects the exchange without it, even for Desktop clients. Keep it out of your config with any command that prints it on stdout:

```sh
# libsecret / GNOME Keyring (already present on most Linux desktops)
secret-tool store --label='bloocky google' service bloocky key google

# or pass
pass insert google/bloocky

# or just a file, chmod 600
install -m600 /dev/null ~/.config/bloocky/google-secret
```

### 3. Configure and authorise

```lua
{
    id = "gcal",
    provider = "google",
    client_id = "xxxxxxxx.apps.googleusercontent.com",
    client_secret_cmd = { "secret-tool", "lookup", "service", "bloocky", "key", "google" },
    -- All calendars sync by default; limit it the same way as CalDAV:
    -- calendars = { { name = "Work" } },
}
```

Restart Neovim, then:

```
:BloockySyncAuth gcal
```

Your browser opens, you approve, and the page tells you to go back to Neovim — which then reports whether the token exchange actually succeeded. **Neovim is the only thing that declares success**; the browser page appearing is not enough on its own.

### Which permissions Bloocky asks for

Only two, both the narrowest that do the job:

- `calendar.events` — view and edit events
- `calendar.calendarlist.readonly` — see which calendars you have

Bloocky never requests the broad `calendar` scope, which can permanently delete entire calendars.

> This is also why Bloocky uses Google's REST API rather than its CalDAV bridge. The bridge would have been far less code to support, but it rejects the narrow scopes with `403 insufficientPermissions` and demands the broad one. Tested, not assumed.

---

## Keeping secrets out of your config

Every credential field has a `_cmd` variant that runs a command and reads the first line of its output:

| Plain (warns) | Preferred |
| --- | --- |
| `password` | `password_cmd` |
| `client_secret` | `client_secret_cmd` |

A plain value still works — Bloocky just warns you that it is sitting in your dotfiles in clear text.

Beyond that, Bloocky:

- never puts a credential on a command line, where any process could read it via `ps` — secrets go to `curl` through a config file created `0600`;
- stores OAuth tokens at `stdpath("state")/bloocky/tokens.json`, mode `0600`;
- refuses plain HTTP except to `localhost`, and never disables TLS verification;
- scrubs tokens and passwords out of every message it prints.

---

## How syncing behaves

### It pushes before it pulls

Every sync sends your local changes up *first*, then fetches. This matters: if it pulled first, a local edit that had not reached the server yet would be treated as out of date and reverted. Pushing first means only a genuine clash — the same event changed in both places since the last sync — counts as a conflict.

### When there is a genuine conflict, the calendar wins

Your version is not thrown away. It goes into a conflict trail you can inspect and restore:

```
:BloockySyncReport      " what was overwritten, and when
:BloockySyncRestore 1   " bring your version back as a new block
```

Conflicts are always announced — automatic syncs stay silent about routine results, but never about a conflict, an error, or an edit that was handed back.

**Overwritten blocks are also flagged on the grid**, in a distinct colour with a `󰀦` marker, so you notice without reading a notification you may have missed. Opening `:BloockySyncReport` counts as having seen them and clears the flags — a marker that never goes away is one people learn to ignore.

### Edits it will not send are handed back

Two cases where Bloocky refuses to write:

- **A repeat rule it cannot model** (see below).
- **A read-only calendar.**

In both, the block reverts to what the calendar actually holds and the sync reports how many edits were undone. It does not silently keep a time your calendar has never heard of.

Blocks on a read-only calendar carry a `󰌾` marker on the grid, so you can see why before you spend an edit on one.

### When it syncs

| Trigger | Default |
| --- | --- |
| Opening the calendar | on — the window appears instantly, a small `syncing` indicator shows while it runs |
| After adding, editing or deleting a block | on — debounced, so a burst of edits costs one sync |
| Every 15 minutes while the window is open | on — stops when you close the calendar |
| Pressing `s` in the calendar | always |
| `:BloockySync` | always |

```lua
sync = {
    sync_on_open = true,
    sync_on_edit = true,
    edit_debounce_ms = 1500,
    interval_min = 15,        -- 0 turns the background sync off
    window = { past_days = 30, future_days = 180 },  -- how much to keep in step
}
```

### Being offline is fine

Nothing is lost. Blocks and pending deletions live on disk, so work made without a connection simply stays pending and goes up on the next sync that reaches the server.

Bloocky also tries not to make a nuisance of itself while you are away:

- the background sync **backs off** after consecutive failures (15 → 30 → 60 → 120 minutes) instead of retrying on the dot, and snaps back to normal the moment one succeeds;
- a failure is reported **once**, not every interval — you hear about it again only if the problem changes or a sync succeeds in between;
- config problems (a plain-text password, a bad URL) are mentioned **once a session**, since they do not change between syncs.

A conflict, or anything that actually changed, is never suppressed.

`:BloockySyncStatus` shows what is still waiting to go up.

---

## Limits worth knowing before you rely on it

**Repeat rules are a deliberate subset.** Bloocky models daily, weekly, weekdays and a custom set of days, with an optional end date, plus excluded dates. Anything richer — every other week, monthly, "the last Friday", a series with individual occurrences *moved* rather than skipped — cannot be represented.

Such events are still imported and shown, and you can edit their **title and notes**, which push back normally. Their **timing and repeat rule are locked**, because rewriting them from Bloocky's simpler model would destroy the real rule for everyone else on that invitation.

**All-day events show above the hour grid**, not in it — a date is not a time, and placing one at 00:00 would be inventing one. Multi-day events appear on every day they cover. They can be read and their text edited, but their timing is locked for the same reason a rule bloocky cannot model is: there is no way to express "a date, not a time" from a block, so writing our timing back would turn a holiday into a midnight appointment. **Bloocky cannot create one** — use your calendar for that.

**Blocks use floating local time.** A 09:00 block is 09:00 wherever you are. Events that arrive *from* a calendar keep their own timezone and are written back into it, so an invitation never gets quietly rewritten.

**One record per series.** Editing a recurring block edits every occurrence; deleting it deletes the series.

**Not real-time.** There are no push notifications; syncs happen on the triggers above.

---

## Checking your setup

```
:checkhealth bloocky
```

Verifies the things that fail quietly: that `curl` exists, that each `password_cmd` and `client_secret_cmd` actually *runs* (not just that it is configured), that your OAuth token is present and readable only by you, that the system timezone database is available, and how much is waiting to sync.

---

## Commands

| Command | What it does |
| --- | --- |
| `:BloockySync [account]` | Sync now — all accounts, or one |
| `:BloockySyncStatus` | Last sync, pending changes and problems, per account |
| `:BloockySyncReport` | Conflicts resolved in the calendar's favour |
| `:BloockySyncRestore <n>` | Restore a losing local version as a new block |
| `:BloockySyncAuth <account>` | Run the OAuth flow (Google) |
| `:BloockySyncRevoke <account>` | Revoke the token upstream and delete it locally |
| `:BloockySyncReset [account]` | Forget cursors and mappings; force a full re-sync |

Inside the calendar, `s` syncs. It is only bound when sync is enabled, so it keeps its usual Vim meaning otherwise.

---

## Troubleshooting

**`is not authorised yet - run :BloockySyncAuth <id> first`**
No token stored. Run the auth command. If you already did, it failed — check `:messages` for the real reason.

**`` `pass` is not installed or not on your PATH ``**
Your `*_cmd` names a program you do not have. Use something you do — `secret-tool` ships with most Linux desktops — or point it at a file with `{ "cat", "/path/to/secret" }`.

**`client_secret_cmd exited with 1`**
The command ran but found nothing. Test it in a shell first; for `secret-tool`, the lookup attributes must match exactly what you stored.

**Config changes seem to be ignored**
Plugin config is read once at load. Restart Neovim after editing it.

**`:BloockySyncAuth` does not exist**
If you lazy-load by command, the sync commands are only registered once the plugin loads. Add them to your `cmd` list:

```lua
cmd = { "Bloocky", "BloockyToggle", "BloockyAdd", "BloockySync", "BloockySyncAuth", "BloockySyncStatus" },
```

**The browser said it worked, but Neovim did not**
The browser only confirms the code arrived; the token exchange happens afterwards and can still fail. Trust Neovim's message, and check `:messages`.

**`redirect_uri_mismatch`**
Your Google OAuth client is a *Web application*. Create a **Desktop app** one.

**`403 insufficientPermissions` (Google)**
The token lacks the scopes. Run `:BloockySyncRevoke gcal` then `:BloockySyncAuth gcal` to re-consent.

**`calendar "X" not found on the server`**
The `name` in your `calendars` list does not match the server's. Clear the list to sync everything, then check `:BloockySyncStatus` for the real names.

**Everything re-syncs from scratch every time**
The server's sync token is being rejected. Harmless but slow; `:BloockySyncReset <account>` gives it a clean start.

---

## Testing safely

To try sync without touching a real calendar, run a local [Radicale](https://radicale.org/):

```sh
pip install --user radicale
mkdir -p /tmp/radicale/collections
printf '[server]\nhosts = localhost:5232\n[auth]\ntype = none\n[storage]\nfilesystem_folder = /tmp/radicale/collections\n' > /tmp/radicale/config
radicale --config /tmp/radicale/config
```

Create a calendar:

```sh
curl -X MKCALENDAR -u test:test http://localhost:5232/test/work/
```

Then point Bloocky at `http://localhost:5232/` with username `test`. Plain HTTP to `localhost` is allowed for exactly this reason. Events land as `.ics` files under `/tmp/radicale/collections/` where you can read them yourself.
