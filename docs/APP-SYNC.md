# Bloocky's companion-app bus

This document is **normative** for the LAN protocol between bloocky.nvim and a companion app. It is bloocky's own bus — independent of dooing's (port 7283, `dooing/docs/SYNC-PROTOCOL.md`) and entirely separate from the calendar sync ([CALENDARS.md](../CALENDARS.md)). The three never mix.

## Transport and security

Plain HTTP on the LAN, default port **7284** (`server.port`, `server.bind`). The security posture is identical to dooing's, with one difference: **there is no v1 compatibility mode**. This port never had unauthenticated clients, so every data route requires a paired device token from day one.

- No CORS headers, ever; any request carrying `Origin` is rejected 403.
- `Host` must be an IP literal (or `localhost`) with this port — the DNS-rebinding guard. A `Host` carrying a DNS *name* is 403, because the plugin only ever hands out IP literals, so a name means a browser resolving somebody else's domain.
- 8 KB header cap, 1 MB body cap, 16 connections, 10 s idle timeout, `Content-Length` framing only (`Transfer-Encoding` is refused).
- **One request per connection.** Every response carries `Connection: close` and the socket is closed after it. Clients must not hold the connection open for a second request.
- Device tokens are stored **hashed** (sha256) at `stdpath("state")/bloocky/devices.json` (0600). Only the hash is ever written, so the file leaking does not leak a credential.

Every non-2xx response is JSON of exactly this shape, and nothing else:

```json
{ "error": "pair this device first (scan the QR)" }
```

An unknown path — or a known path with the wrong method — is **404**, not 405.

## Pairing and identity

`GET /` (public) — the QR page opened by `:BloockyShare`. The QR payload:

```json
{ "v": 2, "p": "bloocky", "host": "http://192.168.1.20:7284", "t": "<pairing token>" }
```

Every load of that page **mints a fresh pairing token**; reloading invalidates nothing, it just adds one. Tokens are single-use, expire after 10 minutes, and never survive the Neovim session that displayed them — they are written to `devices.json` as pending state but deliberately ignored on load, so a QR photographed last week cannot pair a device today.

> The page renders the QR with `qrcode.js` from a CDN, so the machine viewing it needs internet access. On an air-gapped box, read the payload out of the page source and enter the `host` and `t` by hand.

`GET /version` (public) → `{ "protocol": 2, "product": "bloocky" }`. Check `product` before pairing: dooing's bus answers the same route on 7283 and the two token stores are separate.

```
POST /v2/pair                  (public — the pairing token IS the credential)
{ "token": "<t from the QR>", "device_name": "Átila's iPhone" }

200 { "device_id": "<16 hex chars>", "device_token": "<48 hex chars>", "name": "Átila's iPhone" }
401 { "error": "invalid or expired pairing token" }
```

`device_name` is optional (defaults to `"device"`) and **truncated to 64 characters**. The pairing token is consumed whether or not anything later in the request succeeds — one scan, one chance.

`device_token` is returned in plaintext **exactly once, here**. Store it; it cannot be recovered.

Every route below `/version` is authenticated with it:

```
Authorization: Bearer <device_token>
```

Anything else — a missing header, another scheme, an unknown token — is **401**. The comparison is against the stored sha256.

The server auto-starts on Neovim startup once any device is paired (`server.enabled = "auto"`); `true`/`false` force it always/never. `:BloockyServe` and `:BloockyServeStop` drive it by hand.

```lua
server = {
    enabled = "auto",   -- "auto" = start once a device is paired | true | false
    autostart = true,   -- false: never start on startup, whatever `enabled` says
    port = 7284,
    bind = "0.0.0.0",   -- "127.0.0.1" for tunnel-only setups
},
```

## THE ONE-ROAD RULE

**A block travels by exactly one road.** A calendar-backed block (`source` set to a sync account) converges through the calendar — both Neovim and the app are independent clients of it — and never rides this bus. A local block (`source` absent or `"local"`) rides this bus and never touches a calendar. Enforced, not advisory:

- the exchange filters the server side to local blocks,
- a device pushing a calendar-backed block gets **400**, loudly — that client has a routing bug worth hearing about,
- the blocks file is reassembled as (calendar-backed blocks, untouched) + (merged local blocks); the calendar sidecar (`bloocky_sync.json`) is never read or written here.

So a client that fetches `GET /blocks` sees calendar-backed blocks and must treat them as **render-only on this bus**. If it wants to edit them it has to be a calendar client itself; sending one back is a 400, not a merge.

## Routes

`GET /blocks` (authenticated) — ALL blocks, verbatim from the file: the app's read view, calendar-backed ones included (it renders them; it does not push them).

```
POST /v2/sync/blocks           (authenticated)
{ "revision": n, "blocks": [ …the device's LOCAL blocks… ],
  "tombstones": [ { "id", "deleted_at" } ] }

200 { "revision": n+1, "blocks": [ …merged local blocks… ],
      "tombstones": [ … ], "conflicts": [ … ] }
```

Full-state over the local subset. Notes on the fields, in the order they bite:

- **`revision` in the request is ignored.** It is echoed forward, not checked: the server's per-device counter simply increments on every successful exchange. It is a debugging aid, not optimistic concurrency — the base in the sidecar is what actually decides the merge, so a device may send `0` forever without harm.
- **Empty lists are `[]`, never `{}`.** Lua's JSON encoder renders an empty table as an object, so the server special-cases every list in this response. A client may rely on the array type.
- **`blocks` is the device's local blocks only.** Send the full set every time; this is full-state, not a delta.
- **Tombstones flow both ways, but only the device keeps a store.** A device announces its deletions in `tombstones`. The server has no tombstone store of its own — a block deleted in Neovim is simply absent from a base that still holds it, which the merge reads as a deletion and returns in the response `tombstones`. A returned tombstone's `deleted_at` is **absent** when the deletion was inferred that way rather than announced.
- Once a tombstoned id is gone from both sides, it stops being returned: agreement, and the tombstone has done its job.

Three-way merged against the per-device base in `bloocky_app_sync.json` (0600, next to the blocks file). Merge semantics follow dooing's todo merge — base decides changed, `updated_at` breaks genuine ties (exact ties to the smaller device id; the server calls itself `"server"`, and device ids are hex, so ties go to the device), delete-vs-edit resurrects, notes take a strict superset silently, losers are trailed — with block field groups:

| Group | Fields | Why |
| --- | --- | --- |
| `title` | `title` | |
| `timing` | `date`, `start_min`, `duration_min`, `all_day` | one placement on the calendar; mixing halves invents a time nobody chose |
| `notes` | `notes` | superset rule applies |
| `recurrence` | `recurrence` (incl. `exdates`) | whole object |

`created_at` is taken from the base when there is one, else the earlier of the two. `updated_at` is the later of the two. Neither is a group and neither can conflict.

Behaviour is pinned by `spec/fixtures/appsync/cases.json`, which the app's TypeScript port must run verbatim (vendored, drift-checked).

### Conflicts

A conflict is reported whenever a group changed on both sides to different values and no rule dissolved it. Entries look like:

```json
{ "id": "1755043200_4821", "kind": "edit-vs-edit", "group": "timing",
  "winner": "local", "loser_value": { "date": "2026-08-17", "start_min": 540,
                                      "duration_min": 30 },
  "loser_block": { … the whole losing block … } }
```

| Field | |
| --- | --- |
| `kind` | `"edit-vs-edit"` or `"delete-vs-edit"` |
| `group` | the group that clashed; **absent** on `delete-vs-edit`, which is about the whole block |
| `winner` | `"local"` or `"remote"` |
| `loser_value` | only the losing group's fields; absent on `delete-vs-edit` |
| `loser_block` | the whole losing block, so the loser is recoverable rather than merely reported. Present on `edit-vs-edit` only — on a `delete-vs-edit` the losing side is a *deletion*, and there is no block to keep |

> **`winner` is written from the server's point of view.** `"local"` means *Neovim won*, `"remote"` means *the device won* — the opposite of what a device reading its own response would assume. Do not relabel it in the app's UI without flipping it.

`delete-vs-edit` always resurrects: the surviving edit is kept and the conflict records which side had deleted it.

Losing versions are appended to a trail in `bloocky_app_sync.json`, capped by `sync.conflict.trail_limit` (default 50) — yes, the calendar sync's option; the two trails share the cap. There is no `:BloockyAppSyncReport` yet: the trail is written so nothing is destroyed silently, but reading it today means opening the file.

## Wire shape

The block object is [block-structure.md](block-structure.md), v1.1.0 — `updated_at`/`source`/`all_day` optional with the documented absence semantics. Timestamps are unix **seconds**, never milliseconds.

**Unknown keys are preserved, never interpreted**, by every writer on both sides. The merge is the one place that builds a block rather than copying one, so it carries them explicitly: the union of the two live copies, with the newer side winning a key both carry with different values. The base is deliberately not consulted — a key both sides dropped stays dropped instead of becoming immortal. `spec/fixtures/appsync/cases.json` case 11 pins this.

`null` and absent are equivalent everywhere. The canonical serializer drops null-valued keys before comparing, so a device that sends `"recurrence": null` against a server that omits the key is *not* a change.
