local hash = require("bloocky.sync.hash")

local function block(overrides)
	return vim.tbl_extend("force", {
		id = "1755043200_4821",
		title = "Deep work",
		date = "2026-08-13",
		start_min = 540,
		duration_min = 90,
		notes = "",
		created_at = 1755043200,
		updated_at = 1755043200,
		source = "local",
	}, overrides or {})
end

describe("sync.hash", function()
	it("is stable across calls", function()
		eq(hash.block(block()), hash.block(block()))
	end)

	-- The whole point: bookkeeping churn must not look like an edit, or every
	-- sync would push every block.
	it("ignores id, timestamps and source", function()
		local base = hash.block(block())
		eq(hash.block(block({ id = "other" })), base)
		eq(hash.block(block({ created_at = 1 })), base)
		eq(hash.block(block({ updated_at = 999999 })), base)
		eq(hash.block(block({ source = "work" })), base)
	end)

	it("notices every syncable field", function()
		local base = hash.block(block())
		neq(hash.block(block({ title = "Shallow work" })), base, "title")
		neq(hash.block(block({ date = "2026-08-14" })), base, "date")
		neq(hash.block(block({ start_min = 600 })), base, "start_min")
		neq(hash.block(block({ duration_min = 60 })), base, "duration_min")
		neq(hash.block(block({ notes = "with a note" })), base, "notes")
	end)

	-- Without length prefixes, ("ab", "") and ("a", "b") would concatenate to
	-- the same string and a real edit could hash unchanged.
	it("cannot be fooled by field boundaries", function()
		neq(hash.block(block({ title = "ab", notes = "" })), hash.block(block({ title = "a", notes = "b" })))
	end)

	describe("recurrence", function()
		it("treats absent, null and vim.NIL alike", function()
			local base = hash.block(block({ recurrence = nil }))
			eq(hash.block(block({ recurrence = vim.NIL })), base, "vim.NIL is truthy in Lua")
		end)

		it("separates a recurring block from a one-off", function()
			neq(hash.block(block({ recurrence = { type = "daily" } })), hash.block(block()))
		end)

		it("distinguishes types and end dates", function()
			neq(hash.block(block({ recurrence = { type = "daily" } })), hash.block(block({
				recurrence = { type = "weekly" },
			})))
			neq(
				hash.block(block({ recurrence = { type = "daily", until_date = "2026-12-31" } })),
				hash.block(block({ recurrence = { type = "daily" } }))
			)
		end)

		-- `days` is a set. A JSON round-trip or a different UI may reorder it,
		-- and that is not an edit.
		it("ignores the order of custom days", function()
			eq(
				hash.block(block({ recurrence = { type = "custom", days = { 2, 4, 6 } } })),
				hash.block(block({ recurrence = { type = "custom", days = { 6, 2, 4 } } }))
			)
		end)

		it("still notices a different set of days", function()
			neq(
				hash.block(block({ recurrence = { type = "custom", days = { 2, 4, 6 } } })),
				hash.block(block({ recurrence = { type = "custom", days = { 2, 4, 5 } } }))
			)
		end)
	end)

	it("survives a JSON round-trip", function()
		local original = block({ recurrence = { type = "custom", days = { 2, 4, 6 }, until_date = "2026-12-31" } })
		eq(hash.block(vim.json.decode(vim.json.encode(original))), hash.block(original))
	end)
end)
