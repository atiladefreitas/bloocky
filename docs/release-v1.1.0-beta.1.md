# v1.1.0-beta.1 Release Notes — Bloocky

## v1.1.0-beta.1 Two-Way Calendar Sync, Companion App & All-Day Events 📅🔄📱

> 🧪 **This is a beta.** Everything below works and is covered by 395 specs, but
> sync can **write to and delete from your real calendar**. Point it at a
> throwaway calendar until you trust it. What has and has not been verified
> against live servers is spelled out in [Beta status](#beta-status) — please
> read that section before enabling sync on a calendar you care about.

### New Feature Overview

Bloocky v1.0.0 was a calendar that lived entirely inside Neovim. This release
connects it to the rest of your life.

**Blocks you create in Neovim now appear in your real calendar, and events from
your real calendar appear on the grid** — as genuine, editable, deletable blocks,
not a read-only mirror. It speaks **CalDAV** (Fastmail, iCloud, Nextcloud,
Radicale, mailbox.org, and anything else implementing RFC 4791) and **Google
Calendar** through its REST API.

The second headline is a **companion-app bus**: bloocky runs a small server on
your LAN, paired by scanning a QR code, so a phone app can reach your local time
blocks. It is bloocky's own bus on its own port, independent of the calendar
sync and of [Dooing](https://github.com/atiladefreitas/dooing).

Both are **off by default**. If you never enable them, not a single line of
either subsystem is loaded, and bloocky behaves exactly as it did in v1.0.0.

The design rule underneath all of it: **never destroy work silently.** When the
calendar wins a genuine conflict, your version is kept and restorable. When an
edit cannot be pushed, it is handed back rather than left displaying a time your
calendar has never had. When bloocky cannot model a repeat rule, it refuses to
rewrite it rather than flattening someone else's meeting.

Key capabilities:

*   **Two-way CalDAV sync** — discovery, incremental pulls via `sync-collection`
    (RFC 6578) with a full-resync fallback, and `If-Match` on every write
*   **Two-way Google Calendar sync** — REST v3, `syncToken` incremental pulls,
    `410 Gone` recovery, and your own OAuth client with PKCE
*   **Multiple accounts and calendars**, each markable read-write or read-only
*   **Conflicts surfaced and recoverable** — a trail you can inspect and restore
    from, plus a marker on the grid so you notice without reading a notification
*   **All-day events** — imported and drawn *above* the hour grid, spanning every
    day they cover
*   **Excluded dates (`EXDATE`)** — a weekly meeting with a skipped week is no
    longer locked read-only
*   **Companion-app sync over your LAN** — QR pairing, hashed device tokens,
    three-way merge
*   **`:checkhealth bloocky`** — verifies the things that fail quietly
*   **Per-view window height** and `"full"` sizing, with the grid stretching to
    match
*   **395 specs**, including an end-to-end suite against an in-memory CalDAV
    server

---

### Setting Up Your Calendar

This is the part that takes ten minutes once and then never again. Pick your
provider below. Every path ends the same way: `:checkhealth bloocky`, then
`:BloockySync`.

> The same walkthroughs live in [CALENDARS.md](../CALENDARS.md), which is kept
> current after this release page scrolls out of view.

#### Before you start — where the password goes

**Bloocky will not take a password typed into your config.** Well, it will, but
it warns you every time, because a plain-text credential in a dotfiles repo is
how credentials leak. What it wants instead is a **command that prints the
password on stdout**. Bloocky runs it when it needs the value and reads the
first line.

Pick whichever you already have:

```lua
-- libsecret / GNOME Keyring — already present on most Linux desktops
password_cmd = { "secret-tool", "lookup", "service", "bloocky", "key", "caldav" }

-- pass
password_cmd = { "pass", "show", "fastmail/caldav" }

-- 1Password CLI
password_cmd = { "op", "read", "op://Private/Fastmail/caldav" }

-- macOS Keychain
password_cmd = { "security", "find-generic-password", "-s", "bloocky-caldav", "-w" }

-- Just a file you chmod 600
password_cmd = { "cat", vim.fn.expand("~/.config/bloocky/caldav-password") }
```

To store one with `secret-tool` (it will prompt for the value):

```sh
secret-tool store --label='bloocky caldav' service bloocky key caldav
```

**Always use an app-specific password, never your account password.** Every
provider below issues them. They are revocable on their own, and they cannot be
used to log in to your account.

---

#### 📮 Fastmail

**1. Create an app password.** In Fastmail's web settings, find **Password &
Security → App Passwords** and create a new one. When it asks what the password
is for, choose the option covering **CalDAV / Calendars** (not "Mail"). Copy the
generated password — Fastmail shows it once.

**2. Store it:**

```sh
secret-tool store --label='bloocky fastmail' service bloocky key caldav
```

**3. Configure:**

```lua
require("bloocky").setup({
    sync = {
        enabled = true,
        accounts = {
            {
                id = "fastmail",
                provider = "caldav",
                url = "https://caldav.fastmail.com/dav/",
                username = "you@fastmail.com",   -- your full address
                password_cmd = { "secret-tool", "lookup", "service", "bloocky", "key", "caldav" },
            },
        },
    },
})
```

**4. Restart Neovim**, then run `:checkhealth bloocky`. You want to see
`password_cmd works (N characters)`.

**5. Sync:** `:BloockySync`. Then `:BloockySyncStatus` to see which calendars it
found and when it last ran.

Fastmail is the smoothest CalDAV provider to set up — discovery works from the
base URL with no extra steps.

---

#### 🍎 iCloud

**1. Create an app-specific password.** Go to
[appleid.apple.com](https://appleid.apple.com) → **Sign-In and Security** →
**App-Specific Passwords** → **+**. Name it something like `bloocky`. Copy it —
Apple shows it once. It looks like `abcd-efgh-ijkl-mnop`.

> Two-factor authentication must be on. Apple does not offer app-specific
> passwords without it.

**2. Store it:**

```sh
secret-tool store --label='bloocky icloud' service bloocky key icloud
```

**3. Configure:**

```lua
require("bloocky").setup({
    sync = {
        enabled = true,
        accounts = {
            {
                id = "icloud",
                provider = "caldav",
                url = "https://caldav.icloud.com/",
                username = "you@icloud.com",   -- your Apple ID email
                password_cmd = { "secret-tool", "lookup", "service", "bloocky", "key", "icloud" },
            },
        },
    },
})
```

**4. Restart, `:checkhealth bloocky`, then `:BloockySync`.**

**If discovery fails**, iCloud is the most likely provider to need a hand. It
hands out your calendar home on a numbered partition host — something like
`https://p42-caldav.icloud.com/1234567890/calendars/`. Bloocky follows that
cross-host redirect on purpose (a strict same-origin rule would break iCloud
entirely; the URL check guarantees it is only ever reached over verified TLS).
If it still cannot find your calendars, you can skip discovery entirely:

```lua
{
    id = "icloud",
    provider = "caldav",
    url = "https://caldav.icloud.com/",
    username = "you@icloud.com",
    password_cmd = { "secret-tool", "lookup", "service", "bloocky", "key", "icloud" },
    -- Paste the calendar-home URL another CalDAV client showed you
    calendar_home = "https://p42-caldav.icloud.com/1234567890/calendars/",
}
```

> ⚠️ iCloud has **not** been exercised end to end. It is known to be fussy about
> discovery. If you hit something, an issue with the `:messages` output is
> genuinely useful.

---

#### ☁️ Nextcloud

**1. Create an app password.** In Nextcloud: **Settings → Security → Devices &
sessions → Create new app password**. Give it a name, copy the password.

**2. Store it:**

```sh
secret-tool store --label='bloocky nextcloud' service bloocky key nextcloud
```

**3. Configure.** The URL is your Nextcloud host plus `/remote.php/dav/`:

```lua
require("bloocky").setup({
    sync = {
        enabled = true,
        accounts = {
            {
                id = "nextcloud",
                provider = "caldav",
                url = "https://cloud.example.com/remote.php/dav/",
                username = "yourusername",   -- your Nextcloud login, not an email
                password_cmd = { "secret-tool", "lookup", "service", "bloocky", "key", "nextcloud" },
            },
        },
    },
})
```

**4. Restart, `:checkhealth bloocky`, `:BloockySync`.**

> Your Nextcloud must be served over **HTTPS**. Bloocky refuses plain HTTP to
> anything but `localhost`, and TLS verification is never disabled — not even
> behind a config flag. A self-signed certificate needs to be trusted by your
> system's CA store.

---

#### 📬 mailbox.org

Identical to Nextcloud in shape, with mailbox.org's own DAV host:

```lua
{
    id = "mailbox",
    provider = "caldav",
    url = "https://dav.mailbox.org/",
    username = "you@mailbox.org",
    password_cmd = { "secret-tool", "lookup", "service", "bloocky", "key", "mailbox" },
}
```

Create the app password in mailbox.org's settings under the section covering
app-specific or third-party passwords.

---

#### 🔵 Google Calendar

Google takes the longest, because **the OAuth client has to be yours**. Bloocky
deliberately ships none.

A shared client id would put every bloocky user behind one credential — so one
person's abuse could get it suspended for everyone — and behind the same "this
app isn't verified" warning screen, which trains people to click through
security prompts. Your own client is isolated, scoped, and revocable by you.

About five minutes, once.

**1. Create a Google Cloud project.**
Go to [console.cloud.google.com](https://console.cloud.google.com) and create a
project. Any name.

**2. Enable the Google Calendar API** for that project. Search for it in the API
library and click Enable. Sync will fail with a confusing error if you skip this.

**3. Configure the OAuth consent screen.**
Choose **External**. Fill in the required fields. Then — and this is the step
people miss — add **your own Google account under Test users**.

> ⚠️ **You are not exempt from the test-user list.** An unverified External
> consent screen only admits accounts explicitly added as test users, *including
> the account that owns the project*.

**4. Create the credentials.**
**Credentials → Create credentials → OAuth client ID**, application type
**Desktop app**.

> ⚠️ **It must be "Desktop app".** A *Web application* client rejects the
> loopback redirect bloocky uses and fails with `redirect_uri_mismatch`. This is
> the single most common setup mistake.

Copy the **client ID** and the **client secret**.

**5. Store the client secret.**

```sh
secret-tool store --label='bloocky google' service bloocky key google
```

The secret is required. Google's token endpoint rejects the exchange without it
even for Desktop clients, despite RFC 8252 treating such clients as public.

**6. Configure:**

```lua
require("bloocky").setup({
    sync = {
        enabled = true,
        accounts = {
            {
                id = "gcal",
                provider = "google",
                client_id = "123456789-xxxxxxxx.apps.googleusercontent.com",
                client_secret_cmd = { "secret-tool", "lookup", "service", "bloocky", "key", "google" },
            },
        },
    },
})
```

**7. Restart Neovim, then authorise:**

```
:BloockySyncAuth gcal
```

Your browser opens, you approve, and the page tells you to go back to Neovim.

> **Neovim is the only thing that declares success.** The browser page confirms
> only that the authorization code arrived; the token exchange happens
> afterwards and can still fail. Wait for Neovim's message, and check
> `:messages` if you are unsure.

**8. `:checkhealth bloocky`** — you want `token valid` and `token stored,
readable only by you`. Then `:BloockySync`.

**Which permissions bloocky asks for.** Only two, both the narrowest that do the
job:

*   `calendar.events` — view and edit events
*   `calendar.calendarlist.readonly` — see which calendars you have

Never the broad `calendar` scope, which can permanently delete entire calendars.
This is also why bloocky uses Google's REST API rather than its CalDAV bridge:
the bridge rejects these narrow scopes with `403 insufficientPermissions` and
demands the broad one. That was tested against a live account, not assumed.

---

#### 🧪 Radicale — a local server to try it safely

The best way to trust sync before pointing it at real data. Radicale is a small
CalDAV server you can run locally in a minute:

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

Point bloocky at it:

```lua
{
    id = "local",
    provider = "caldav",
    url = "http://localhost:5232/",
    username = "test",
    password = "test",   -- a throwaway; the plain-text warning is expected here
}
```

Plain HTTP to `localhost` is allowed for exactly this reason. Events land as
`.ics` files under `/tmp/radicale/collections/`, where you can read them
yourself and watch bloocky work.

---

#### Choosing which calendars sync

Omit `calendars` entirely and bloocky syncs **every** calendar the server
offers, with the first one becoming the default for new blocks. To be selective,
or to mark one you never want written to:

```lua
{
    id = "fastmail",
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

*   Names are matched **case-insensitively** against the server's display names.
*   `default = true` marks where new blocks are created. Without it, the first
    writable calendar wins.
*   A calendar the **server itself** reports as read-only is treated as `ro`
    regardless of what you wrote here. For Google that means any calendar where
    your access role is `reader` or `freeBusyReader`.
*   Named a calendar the server does not have? You get
    `calendar "X" not found on the server` rather than silence. Clear the list,
    sync, and check `:BloockySyncStatus` for the real names.

#### Multiple accounts at once

```lua
sync = {
    enabled = true,
    accounts = {
        { id = "work",     provider = "caldav", url = "...", username = "...", password_cmd = { ... } },
        { id = "personal", provider = "google", client_id = "...", client_secret_cmd = { ... } },
    },
}
```

`:BloockySync` syncs all of them; `:BloockySync work` syncs one. New blocks are
created in the default calendar of the **first** account.

#### Verifying it worked

```
:checkhealth bloocky     " every credential command actually runs, not just "is configured"
:BloockySync             " sync now
:BloockySyncStatus       " last sync, what is waiting to go up, problems per account
```

Then open the calendar and press `s` any time you want to sync by hand.

---

### What's Changed

#### 🔄 Two-Way Calendar Sync

**CalDAV (`lua/bloocky/sync/providers/caldav.lua`):**

*   Discovery walks `PROPFIND` on your base URL → `current-user-principal` →
    `calendar-home-set` → the calendars themselves. Each hop is skippable:
    set `calendar_home` and you pay for none of them.
*   Collections are filtered on `resourcetype` **and**
    `supported-calendar-component-set`, because servers advertise address books
    and task lists in the same listing.
*   The first fetch is a time-bounded `calendar-query`; subsequent ones use
    `sync-collection` (RFC 6578), falling back to a ctag comparison plus
    `calendar-query` for servers that do not implement it.
*   `calendar-multiget` is chunked, so a large calendar does not become one
    enormous request.
*   Every `PUT` and `DELETE` carries `If-Match`. A `412` is a real conflict.
*   Cross-host hrefs are followed on purpose — iCloud legitimately hands out a
    calendar home on a partition host — and the URL check guarantees any such
    host is reached only over verified TLS.

**Google (`lua/bloocky/sync/providers/google.lua`):**

*   REST v3, with `syncToken` incremental pulls and `410 Gone` recovery.
*   Events are converted to **iCalendar text on the way in**, so recurrence
    modelling, lossiness detection and timezone handling stay on one code path
    instead of growing a second, subtly different implementation for JSON.
*   Writes use `PATCH`, not `PUT`, so attendees, conferencing data and
    everything else bloocky knows nothing about survive server-side.
*   A `syncToken` is bound to the exact query that issued it, so `timeMin` is
    stored *with* the cursor and reused rather than recomputed from the clock.

**The engine (`lua/bloocky/sync/init.lua`):**

*   **Every sync pushes before it pulls.** If it pulled first, a local edit that
    had not reached the server yet would look out of date and get reverted.
    Pushing first means only a genuine clash — the same event changed in both
    places since the last sync — counts as a conflict.
*   Per-account locking, so runs can never overlap.
*   `sync.window` bounds how much of the calendar is kept in step
    (30 days back, 180 forward by default). Everything outside it is left alone.
*   Tombstones and mappings for accounts removed from your config are pruned.

**Conflicts, made loud (`lua/bloocky/sync/store.lua`, `lua/bloocky/marks.lua`):**

*   When the calendar wins, your version goes into a trail — `:BloockySyncReport`
    shows what was overwritten, `:BloockySyncRestore <n>` brings it back as a new
    block. Capped at `conflict.trail_limit` (default 50).
*   Overwritten blocks are **recoloured on the grid** and marked `󰀦`, so you
    notice without having read a notification. Reading the report is the
    acknowledgement — a marker that never clears is one people stop seeing.
*   Read-only blocks carry `󰌾`, so you can see why before you spend an edit.
*   A conflict recolours; read-only only changes the icon. Giving every
    read-only block its own colour would flatten the palette that makes blocks
    distinguishable.

**Edits it will not send are handed back:**

Two cases where bloocky refuses to write — a repeat rule it cannot model, and a
read-only calendar. In both, the block reverts to what the calendar actually
holds and the sync reports how many edits were undone. It does not silently keep
a time your calendar has never heard of, which matters especially because pulls
are incremental: nothing would ever come along to correct it.

**Triggers (`lua/bloocky/ui.lua`):**

*   **`s` syncs** from inside the calendar. Bound only when sync is enabled, so
    it keeps its usual Vim meaning otherwise.
*   **Sync on open** — the window appears immediately and the network happens
    behind a small indicator. Opening the calendar never waits on a server.
*   **Sync after an edit**, debounced 1.5s, so a burst of edits costs one sync.
*   **Periodic sync** every 15 minutes while the window is open, stopping when it
    closes, and backing off 15 → 30 → 60 → 120 minutes after consecutive
    failures. A laptop shut in a bag offline for an hour should not have spent
    that hour retrying.
*   **Being offline is fine.** Pending work lives in the blocks file and the
    sidecar's tombstones, both durable, so a sync that cannot reach the server
    changes nothing and the next one that can picks it up.

**Notification hygiene.** A failure is reported once per account until it changes
or a sync succeeds; config problems once per session. Conflicts, reverted edits
and real changes are never suppressed. (Testing found the plain-text-password
warning firing on *every* sync — four popups an hour, forever.)

#### 📅 All-Day Events & Excluded Dates

*   **All-day events are drawn above the hour grid**, not in it. A date is not a
    time, and placing one at 00:00 would be inventing one.
*   **Multi-day events appear on every day they cover.** `duration_min` carries
    the span in whole days and the lookup walks back over it, which also makes a
    recurring multi-day block work without a second mechanism. The lookback is
    capped so a malformed duration cannot turn a redraw into a long loop.
*   **`EXDATE` is modelled** via `recurrence.exdates`, so an ordinary weekly
    meeting with one skipped week is no longer locked read-only. Excluding a day
    drops the whole occurrence, span included.
*   All-day timing is locked on push, and bloocky **cannot create** one — the
    block dialog has no way to say "a date, not a time".

#### 📱 Companion-App Sync

Bloocky serves your **local** blocks to a companion app over your LAN. Its own
port, its own pairing — each product owns its bus, so a device paired with one
is not implicitly trusted by another.

```
:BloockyShare       " opens the pairing QR in your browser
:BloockyServe       " start the server by hand
:BloockyServeStop   " stop it
```

*   **Authenticated from day one.** This port never had unauthenticated clients,
    so unlike its sibling it carries no v1 compatibility mode — every data route
    requires a paired device token, with no legacy path to opt back out of.
*   **QR pairing.** The code carries a single-use token, valid 10 minutes, dead
    when Neovim exits. A device exchanges it once for a long-lived bearer token.
*   **Tokens stored hashed** (sha256), so the device file leaking does not leak a
    credential.
*   **Three-way merge, not last-write-wins.** A title changed on the phone and a
    time changed in Neovim both survive. Timing moves as one unit — `date`,
    `start_min`, `duration_min` and `all_day` describe a single placement, and
    mixing two sides' halves would invent a time nobody chose.
*   **Auto-start on pairing.** `server.enabled = "auto"` runs the server only
    once a device exists, so a user who never pairs never runs a server.

**THE ONE-ROAD RULE.** A block travels by exactly one road. A calendar-backed
block converges through the calendar — Neovim and the app are both already
clients of it — and letting it ride the LAN as well is how duplicates appear. So
a local block rides this bus and never touches a calendar, and a calendar-backed
one does the reverse. Enforced, not advisory: a device pushing a calendar-backed
block gets a **400**, loudly, because that client has a routing bug worth
hearing about.

The protocol is documented in [docs/APP-SYNC.md](APP-SYNC.md), which is
normative if you are writing a client.

#### 🩺 `:checkhealth bloocky`

New in this release, and it checks the things that fail quietly:

*   `curl` exists
*   each `password_cmd` / `client_secret_cmd` **actually runs**, rather than
    merely being configured — "it is configured" and "it works" are different
    claims, and the gap between them is where setup fails
*   the OAuth token is present, valid, and mode `0600`
*   the system timezone database is available
*   how much is waiting to sync, and how many conflicts are unread
*   the companion-app server: whether it is listening and where, how many
    devices are paired, and whether `bind` put it on your LAN or only loopback

#### 🪟 Window Sizing

*   **Per-view height** to match the per-view width that already existed:
    `"auto"` fits the window to its content, `"full"` takes every row available,
    a number is a fraction of the editor (or absolute rows above `1`).
*   **`"full"` width**, so a view can take the whole editor.
*   **The grid stretches to match.** Anything but `"auto"` fills the window
    exactly rather than leaving the bottom empty: hour slots grow taller, month
    cells take the spare rows, and columns share out the cells that do not
    divide evenly.

#### 🎨 Per-Calendar Colours

Blocks from the same calendar share a colour, so work and personal separate at a
glance. Purely local blocks keep the varied per-block palette from v1.0.0. This
hangs off the same `highlights.block_group` choke point as conflict marking, so
no view needed restructuring.

---

### Bug Fixes

*   **Timezone conversions forced `isdst = false`**, which made any date inside
    DST an hour early — and an hour early at 23:59 moves the *date*. It surfaced
    as a recurring series' end date drifting from 2026-12-31 to 2027-01-01 in
    Auckland. Never set `isdst` in this codebase.
*   **A refused edit was silently kept.** Editing an event whose recurrence
    bloocky cannot model, or one on a read-only calendar, correctly did not push
    — but the block kept the change, displaying a time the calendar had never
    had, and incremental pulls meant nothing would ever correct it.
*   **One clash was reported twice**, once from the push `412` and once from the
    pull's both-sides-changed check. They are the same event seen from two
    directions.
*   **The delete prompt called a one-off block a recurring series** when its
    recurrence was an explicit JSON `null` — `vim.NIL` is truthy in Lua.
*   **Backoff only saw the last account's result.** With one broken account and
    one healthy one, whether the failure was noticed depended on which finished
    last.
*   **Tombstones and mappings for removed accounts queued forever.**
*   **Account tables passed to `setup()` were mutated in place.**
*   **A malformed `SUMMARY` could break the calendar.** A legal iCalendar title
    containing the `\n` TEXT escape crashed `nvim_buf_set_lines` on every redraw
    until the event was removed.
*   **`&#xFFFFFFFF;` in a server response killed the sync** — an out-of-range
    numeric character reference threw `E5071` out of `nr2char`.
*   **The OAuth browser page claimed success too early**, saying "connected" the
    moment the code arrived and before the token exchange, which could then fail.
*   **"Already up to date" no longer appears next to an error**, which read as if
    the error were harmless.
*   **The conflict trail on the app bus recorded that something was overwritten,
    but not what** — the losing block was attached under one name and persisted
    under another, so the field was always empty.
*   **Unhelpful error messages** — a missing password manager now says
    `` `pass` is not installed or not on your PATH `` instead of trailing off
    after a colon.

---

### Security

Sync means credentials and network access, so this got disproportionate
attention. Each item below was reproduced before it was fixed.

*   **Credentials never reach `argv`**, where any process could read them via
    `ps`. They go to `curl` through a config file created `0600`. The guarantee
    is pinned by a spec.
*   **URL userinfo is stripped before the loopback check.** Otherwise
    `http://localhost:1@evil.com/` reads as loopback and sends credentials to
    `evil.com` over plain HTTP.
*   **Control characters are escaped in curl config values** — a newline inside a
    secret could otherwise terminate the quoted value and turn the remainder into
    config directives.
*   **Server-provided values are treated as hostile.** Sync tokens are
    XML-escaped before being echoed back, and CR/LF is flattened out of Google
    fields such as `iCalUID`, which is chosen by whoever created the event.
*   **OAuth uses PKCE S256** on an ephemeral loopback port with a verified
    `state`. The challenge derivation is pinned against the RFC 7636 test vector.
*   **Narrowest usable scopes**, never the broad `calendar` one.
*   **Bloocky ships no OAuth client**, on purpose.
*   **Plain HTTP is refused** except to loopback, and TLS verification is never
    disabled — not even behind a flag.
*   **Tokens, sync state, blocks and device files are all written `0600`** — the
    sidecars mirror full calendar contents.
*   **Tokens and passwords are scrubbed** from every message, with the redactor
    pinned by specs.
*   **`spec/secrets_spec.lua` fails the build** if anything credential-shaped
    lands in the repository.

---

### Beta Status

Honest accounting of what has actually been run against real servers, so you can
judge the risk yourself.

**Verified end to end:**

*   **Radicale** — exercised continuously throughout development, both
    directions, including conflicts, deletions and recurrence.
*   **Google, read path** — verified against a live account: discovery, access
    roles, event parsing, cursor issue and `410` recovery.

**Covered by specs, but not run against the real thing:**

*   **The Google write path.** Create, update and delete are covered by specs
    against a fake API. **Try it on a throwaway calendar first.**
*   **Every CalDAV server except Radicale.** Fastmail, iCloud, Nextcloud and
    mailbox.org are implemented to the RFCs and to their documented quirks, but
    have not been exercised end to end. iCloud in particular is known to be
    fussy about discovery.
*   **The `sync-collection` fallback path** for servers without RFC 6578.

**Deliberate limits, documented rather than worked around:**

*   **Recurrence is a subset** — daily, weekly, weekdays, a custom day set, an
    end date, and excluded dates. Anything richer (every other week, monthly,
    "the last Friday", individually moved occurrences) is shown and its text
    stays editable, but its timing is locked. Rewriting it from bloocky's simpler
    model would destroy the real rule for everyone else on the invitation.
*   **All-day events cannot be created** from bloocky, only imported.
*   **Blocks are floating local time.** A 09:00 block is 09:00 wherever you are.
    Events arriving from a calendar keep their own timezone and are written back
    into it.
*   **One record per series.** Editing a recurring block edits every occurrence;
    deleting it deletes the series.
*   **DST "fall back" is ambiguous for one hour a year.** A wall clock that
    happens twice is resolved by libc.
*   **Not real-time.** No push notifications; syncs happen on the triggers above.
*   **Proton Calendar cannot be supported.** It has no CalDAV, as a consequence
    of its end-to-end encryption — no third-party client can reach it, not
    Thunderbird, not Apple Calendar, not DAVx⁵, not bloocky.
*   **On the app bus:** no command reads the conflict trail yet, and none lists
    or revokes a paired device.

**How to report something.** `:messages` after a failed sync usually holds the
real reason — tokens and passwords are already scrubbed from it, so it is safe to
paste. `:BloockySyncStatus` and `:checkhealth bloocky` are both useful to
include.

---

### Configuration Reference

Everything new in this release. All of it optional.

```lua
require("bloocky").setup({
    -- Two-way sync with a real calendar. Off by default.
    sync = {
        enabled = false,
        accounts = {},          -- see the setup guide above

        store_path = nil,       -- nil = bloocky_sync.json next to save_path

        sync_on_open = true,    -- pull when the calendar opens
        sync_on_edit = true,    -- push after a block changes (debounced)
        edit_debounce_ms = 1500,
        interval_min = 15,      -- keep syncing while the window is open; 0 disables

        window = { past_days = 30, future_days = 180 },
        conflict = { trail_limit = 50 },
    },

    -- The companion-app LAN bus. Runs nothing until you pair a device.
    server = {
        enabled = "auto",       -- "auto" | true | false
        autostart = true,
        port = 7284,
        bind = "0.0.0.0",       -- "127.0.0.1" for tunnel-only setups
    },

    window = {
        width  = { month = 0.8, week = 0.6, day = 46 },  -- or "full"
        height = "auto",                                  -- "auto" | "full" | number
    },

    icons = {
        all_day  = "󰃭",  -- a date-based block, above the hour grid
        conflict = "󰀦",  -- the calendar overwrote this block
        readonly = "󰌾",  -- lives on a calendar bloocky cannot write to
    },
})
```

#### Give every view the whole editor

```lua
require("bloocky").setup({
    window = { width = "full", height = "full" },
})
```

---

### Commands

**Always available:**

| Command | |
| --- | --- |
| `:Bloocky [day\|week\|month]` | Open the calendar |
| `:BloockyToggle` | Toggle it |
| `:BloockySidebar [view]` | Open it as a sidebar |
| `:BloockySidebarToggle [view]` | Toggle the sidebar |
| `:BloockyAdd` | Open and jump into the creation dialog |
| `:checkhealth bloocky` | Verify your setup end to end |
| `:BloockyShare` | Open the companion-app pairing QR |
| `:BloockyServe` / `:BloockyServeStop` | Start / stop the app server |

**Only when `sync.enabled = true`:**

| Command | |
| --- | --- |
| `:BloockySync [account]` | Sync now — all accounts, or one |
| `:BloockySyncStatus` | Last sync, pending changes and problems per account |
| `:BloockySyncReport` | Conflicts resolved in the calendar's favour |
| `:BloockySyncRestore <n>` | Restore a losing local version as a new block |
| `:BloockySyncAuth <account>` | Run the OAuth flow (Google) |
| `:BloockySyncRevoke <account>` | Revoke upstream and delete the local token |
| `:BloockySyncReset [account]` | Forget cursors and mappings; force a full re-sync |

> If you lazy-load by command, add the sync commands to your `cmd` list — they
> are registered when the plugin loads, so a plugin that has not loaded has no
> `:BloockySyncAuth` to run.

Inside the calendar, **`s` syncs**. It is bound only when sync is enabled, so it
keeps its usual Vim meaning otherwise.

---

### Installation

Requires Neovim `>= 0.10.0`, a [Nerd Font](https://www.nerdfonts.com/) for the
icons (optional — every icon is configurable), and `curl` if you enable sync.

```lua
-- Using lazy.nvim
{
    "atiladefreitas/bloocky",
    version = "v1.1.0-beta.1",
    config = function()
        require("bloocky").setup({
            -- every option has a sensible default; sync and the app bus are off
        })
    end,
}
```

Or with the Neovim 0.12+ native package manager:

```lua
vim.pkg.add("atiladefreitas/bloocky")

require("bloocky").setup({
    -- your config here
})
```

---

### Breaking Changes

**None.** Every change in this release is additive:

*   New config keys only — `sync`, `server`, `window.height`, three new `icons`.
    Nothing was renamed or removed, and an existing v1.0.0 config keeps working
    untouched.
*   The block format gained three **optional** fields (`updated_at`, `source`,
    `all_day`) and `recurrence` gained `exdates`. Blocks written before sync
    existed are read unchanged: absent `source` means `"local"`, absent
    `updated_at` falls back to `created_at`.
*   `s` is bound inside the calendar **only** when sync is enabled.
*   The companion-app server starts only once you have paired a device.

Two behavioural notes that break nothing but are worth knowing:

*   The blocks file is now written mode `0600`, and existing files are tightened
    on the next save. With sync enabled it mirrors your calendar contents, which
    are not for other users of the machine.
*   Sync bookkeeping lives in a **sidecar**, `bloocky_sync.json`, not in the
    blocks file. ETags and raw iCalendar payloads have no business in a file
    other tools read.

---

### Technical Details

**New module layout:**

```
lua/bloocky/
  health.lua              :checkhealth bloocky
  marks.lua               what the sync layer knows that the grid should show
  sync/
    init.lua              orchestrator: push-then-pull, locking, timers, reports
    account.lua           account resolution and *_cmd secret execution
    store.lua             the sidecar: mappings, tombstones, cursors, conflicts
    hash.lua              content hash of a block's syncable fields
    http.lua              async curl: retries, backoff, redaction, TLS enforcement
    xml.lua               minimal pull parser for CalDAV multistatus
    ical.lua              RFC 5545 parse/serialize, folding, escaping, patching
    rrule.lua             RRULE <-> recurrence, with lossiness detection
    tz.lua                IANA zone detection, offset maths
    oauth.lua             PKCE + loopback listener + refresh + revoke
    async.lua             coroutine sequencing
    providers/{caldav,google}.lua
  server/
    init.lua              the LAN bus: routes, connections, QR page
    httpd.lua             request framing and the guards every route sits behind
    devices.lua           paired devices and the tokens that pair them
    exchange.lua          one exchange, and the one-road rule
    merge.lua             three-way merge over local blocks
    canonical.lua         one stable string per value, for change detection
    store.lua             per-device bases and the app conflict trail
```

**Two rules the codebase holds itself to:**

*   **Never re-serialize an event from scratch — patch it.** `RRULE:FREQ=WEEKLY;
    INTERVAL=2;BYDAY=TU` has no representation in bloocky's model. Rebuilding
    the event from what bloocky understands would silently destroy that rule for
    everyone else on the invitation. So the original payload is kept and only
    the fields that actually changed are written back.
*   **`base_hash` is load-bearing, not `updated_at`.** "Has this block changed
    locally?" is answered by re-hashing its syncable fields and comparing —
    which works even if a companion app edited the blocks file without bumping
    the timestamp. `updated_at` is for human-readable ordering in reports.

**On the test suite.** The project had none at v1.0.0; it now has **395 specs**,
run with `scripts/test.sh`. Busted was considered and rejected: it runs in plain
Lua with no `vim` global, so testing code that leans on `vim.json`, `vim.uv` and
`vim.fn.sha256` would mean asserting against a hand-written fake of the exact
API whose behaviour is in question. Specs run under `nvim -l` instead, with the
real API and no dependencies.

---

### All Changes

*   `64a6de6` — window sizing: per-view height, `"full"`, grids that stretch
*   `da83449` — two-way calendar sync with CalDAV and Google Calendar
*   `28f5e47` — all-day events, excluded dates, per-calendar colours, checkhealth
*   `f3d3691` — security hardening and a sweep of the known-bugs list
*   `5fab1a5` — companion-app LAN bus for time blocks on `:7284`
*   `d0604a9` — document the companion-app bus, and fix what it promised

**Full Changelog**: https://github.com/atiladefreitas/bloocky/compare/v1.0.0...v1.1.0-beta.1

---

Made with ❤️ for the Neovim community. If you find any issues or have
suggestions, open an issue or reach out at contact@atiladefreitas.com

---

> ⚠️ **These release notes were written by AI and then analysed,
> corrected and verified by me, line by line.**
