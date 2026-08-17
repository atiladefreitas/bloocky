# Block JSON structure

The data format bloocky.nvim reads and writes. Everything here is about the
stored shape — no rendering, no UI.

## The file

A **bare JSON array** of block objects. No wrapper object, no version field, no
metadata.

```json
[
  {
    "id": "1755043200_4821",
    "title": "Deep work",
    "date": "2026-08-13",
    "start_min": 540,
    "duration_min": 90,
    "notes": "",
    "created_at": 1755043200,
    "updated_at": 1755043200,
    "source": "local"
  },
  {
    "id": "1755043260_9112",
    "title": "Standup",
    "date": "2026-08-10",
    "start_min": 600,
    "duration_min": 30,
    "notes": "daily sync",
    "created_at": 1755043260,
    "updated_at": 1755049001,
    "source": "work",
    "recurrence": { "type": "weekdays", "until_date": "2026-12-31" }
  }
]
```

## Fields

| Field | Type | Required | Rules |
| --- | --- | --- | --- |
| `id` | string | yes | Unique, stable, never rewritten on edit. Format is `<unix_seconds>_<4 random digits>`, but only uniqueness matters. |
| `title` | string | yes | Non-empty after trimming. |
| `date` | string | yes | `YYYY-MM-DD`, zero-padded. For a recurring block this is the **series start date**. |
| `start_min` | integer | yes | Minutes from local midnight. `09:00` → `540`, `14:30` → `870`. |
| `duration_min` | integer | yes | Length in minutes. `> 0`. The end time is derived: `start_min + duration_min`. |
| `notes` | string | yes | Free text. Use `""` when empty — never `null`. |
| `recurrence` | object \| null | no | See below. Absent or `null` = happens once, on `date`. |
| `created_at` | integer | yes | Unix seconds at creation. Not updated on edit; informational only. |
| `updated_at` | integer | no | Unix seconds of the last edit. Absent on blocks written before sync existed — fall back to `created_at`. |
| `source` | string | no | `"local"`, or the id of the sync account the block came from. Absent means `"local"`. |
| `all_day` | boolean | no | `true` for a date-based block. `start_min` is meaningless; `duration_min` is the span in whole days × 1440. Absent means a timed block. |

### Things the format assumes

- **No timezone, no absolute instant.** `date` + `start_min` are read in the
  device's local calendar. A 09:00 block is 09:00 everywhere.
- **Duration, not end time.** There's no `end_min` field. Storing the pair would
  let them drift out of sync.
- **No cross-midnight blocks.** `start_min + duration_min` can exceed 1440, but
  nothing consumes the overflow into the next day. Split overnight work into two
  blocks.
- **Values are normalized on write** (see below), so a reader never has to clean
  anything up.

## Recurrence

```json
{
  "type": "daily" | "weekly" | "weekdays" | "custom",
  "days": [2, 4, 6],
  "until_date": "2026-12-31"
}
```

| Field | Rules |
| --- | --- |
| `type` | One of the four values. Unknown values must produce **no** occurrences (fail closed). |
| `days` | Only for `type: "custom"`. Array of weekday numbers. Ignored/omitted otherwise. |
| `until_date` | `YYYY-MM-DD`, **inclusive**. `""`, `null`, or absent = forever. |
| `exdates` | Array of `YYYY-MM-DD`. Days the series skips. An excluded day removes the whole occurrence, span and all. |

**Weekday numbering is 1 = Sunday … 7 = Saturday** — the C convention, *not*
ISO 8601 where Monday is 1. This matters: JavaScript's `getDay()` returns
0 = Sunday, so you need `getDay() + 1`.

Only one record is stored per series — occurrences are computed on demand, never
materialized. That means editing a block edits every occurrence, and deleting it
deletes the whole series. Individual days can be *skipped* with `exdates`, but
there are no per-occurrence overrides — a single instance cannot be moved or
retitled.

### Whether a block occurs on a date

```
if no recurrence:
    date == block.date

else:
    date >= block.date                                  // series start bound
    AND (until_date empty OR date <= until_date)        // series end bound
    AND:
        daily     -> always
        weekly    -> weekday(date) == weekday(block.date)
        weekdays  -> weekday(date) in 2..6   (Mon–Fri)
        custom    -> weekday(date) in days
```

Two things to note:

- `weekly` has no weekday field — it derives it from `date`. Changing the start
  date moves the whole series to a different weekday.
- Because dates are fixed-width and zero-padded, plain **string comparison is
  chronological**. `"2026-08-13" >= "2026-08-10"` works. Keep the padding.

### Not supported

No `interval` (every N weeks), no monthly/yearly, no occurrence count, no
per-occurrence overrides. If you add any of these, add them as new `type` values plus new
fields — old readers then fall through to "no match" instead of misreading an
existing type.

## Normalization on write

The editor applies these before storing, so persisted values are always clean:

- `granularity` (default **30** minutes) is the quantum for both time fields.
- `start_min` → rounded to the nearest granularity step: `floor(x / g + 0.5) * g`
- `duration_min` → same rounding, then clamped to a minimum of one step, so a
  block is never zero-length.
- `title` and `notes` trimmed.
- `date` and `until_date` re-emitted as `YYYY-MM-DD` (an input like `8/3/2026`
  is stored as `2026-08-03`).
- `recurrence` set to `null` when the user picked "none"; `days` kept only for
  `custom`.

## Types + occurrence check

```ts
export type Recurrence = {
  type: "daily" | "weekly" | "weekdays" | "custom";
  days?: number[];        // 1=Sun .. 7=Sat, "custom" only
  until_date?: string;    // inclusive; "" or absent = forever
  exdates?: string[];     // YYYY-MM-DD days the series skips
};

export type Block = {
  id: string;
  title: string;
  date: string;           // YYYY-MM-DD (series start when recurring)
  start_min: number;      // minutes from midnight
  duration_min: number;
  notes: string;
  recurrence?: Recurrence | null;
  created_at: number;     // unix seconds
  updated_at?: number;    // unix seconds of the last edit; fall back to created_at
  source?: string;        // "local" (default) or a sync account id
  all_day?: boolean;      // date-based; duration_min is whole days x 1440
};

// 1=Sun .. 7=Sat. Noon avoids DST/UTC shifting the date by a day —
// `new Date("2026-08-13")` parses as UTC and can land on the previous day.
const wdayOf = (date: string) => new Date(`${date}T12:00:00`).getDay() + 1;

// An occurrence *starts* on this date. For an all-day block it then runs for
// `duration_min / 1440` days, so use `coversDate` below to draw it.
export function occursOn(b: Block, date: string): boolean {
  const r = b.recurrence;
  if (r?.exdates?.includes(date)) return false;   // an excluded day removes the whole occurrence
  if (!r || typeof r !== "object") return b.date === date;
  if (date < b.date) return false;
  if (r.until_date && date > r.until_date) return false;
  const wd = wdayOf(date);
  switch (r.type) {
    case "daily":    return true;
    case "weekly":   return wd === wdayOf(b.date);
    case "weekdays": return wd >= 2 && wd <= 6;
    case "custom":   return (r.days ?? []).includes(wd);
    default:         return false;   // unknown type = no occurrences
  }
}

const spanDays = (b: Block) =>
  b.all_day ? Math.max(1, Math.min(366, Math.ceil((b.duration_min ?? 1440) / 1440))) : 1;

const shift = (date: string, days: number) => {
  const d = new Date(`${date}T12:00:00`);
  d.setDate(d.getDate() + days);
  return d.toISOString().slice(0, 10);
};

// A multi-day all-day block covers every day it runs over, not just its first.
export function coversDate(b: Block, date: string): boolean {
  for (let back = 0; back < spanDays(b); back++) {
    if (occursOn(b, shift(date, -back))) return true;
  }
  return false;
}

// All-day blocks first (they belong above an hour grid, not in it), then by
// start time. Callers rely on that ordering.
export const blocksForDate = (all: Block[], date: string) =>
  all
    .filter((b) => coversDate(b, date))
    .sort((a, b) => Number(!!b.all_day) - Number(!!a.all_day) || a.start_min - b.start_min);

export const snap = (min: number, g = 30) => Math.floor(min / g + 0.5) * g;
```

## If you share the file with the Neovim plugin

- Top level must stay a bare array.
- Accept **both** a missing `recurrence` key and an explicit `null` — the Lua
  JSON encoder can emit either for a non-recurring block.
- `date` / `until_date` must stay zero-padded `YYYY-MM-DD`.
- `start_min` / `duration_min` must be integers, already snapped, with
  `duration_min > 0`.
- `notes` must be a string, not `null`.
- Don't regenerate `id` on edit.
- Extra keys of your own **do survive** an edit made in Neovim. The plugin
  assigns known fields onto the stored object rather than replacing it, so keys
  it doesn't recognize are carried through untouched. (An earlier version of
  this document claimed the opposite; that was wrong.)
- Bump `updated_at` when you change a block. Nothing breaks if you forget —
  sync detects changes by hashing the content, not by trusting the timestamp —
  but conflict reports read better when it's accurate.

---

## Related

- [APP-SYNC.md](APP-SYNC.md) — the LAN protocol that moves these blocks between
  bloocky.nvim and a companion app, and the field groups its merge uses.
- [CALENDARS.md](../CALENDARS.md) — how `source`, `all_day` and `recurrence`
  behave once a block is backed by a real calendar.
