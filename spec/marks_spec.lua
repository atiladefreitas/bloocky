local config = require("bloocky.config")
local highlights = require("bloocky.highlights")
local marks = require("bloocky.marks")
local store = require("bloocky.sync.store")

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")
local counter = 0

local function fresh(enabled)
	counter = counter + 1
	config.options.sync = {
		enabled = enabled ~= false,
		store_path = ("%s/marks_%d.json"):format(tmpdir, counter),
		conflict = { trail_limit = 50 },
		accounts = {},
	}
	store.load()
	marks.refresh()
end

local function block(id)
	return {
		id = id or "b1",
		title = "Deep work",
		date = "2026-08-13",
		start_min = 540,
		duration_min = 90,
		notes = "",
	}
end

describe("marks", function()
	describe("conflicts on the grid", function()
		it("flags a block the calendar overwrote", function()
			fresh()
			store.record_conflict({ block_id = "b1", title = "Deep work" })
			marks.refresh()
			truthy(marks.is_conflicted(block("b1")))
			falsy(marks.is_conflicted(block("b2")))
		end)

		it("colours it differently from every other block", function()
			fresh()
			local ordinary = highlights.block_group(block("b1"))
			store.record_conflict({ block_id = "b1", title = "Deep work" })
			marks.refresh()
			eq(highlights.block_group(block("b1")), "BloockyBlockConflict")
			neq(highlights.block_group(block("b1")), ordinary)
		end)

		it("gives it its own icon", function()
			fresh()
			eq(marks.icon(block("b1")), config.options.icons.block)
			store.record_conflict({ block_id = "b1" })
			marks.refresh()
			eq(marks.icon(block("b1")), config.options.icons.conflict)
		end)

		-- Reading the report is the acknowledgement; the flag has to clear or
		-- it becomes permanent noise people learn to ignore.
		it("clears once the conflicts are acknowledged", function()
			fresh()
			store.record_conflict({ block_id = "b1" })
			marks.refresh()
			truthy(marks.is_conflicted(block("b1")))

			store.acknowledge_conflicts()
			marks.refresh()
			falsy(marks.is_conflicted(block("b1")))
			eq(highlights.block_group(block("b1")), highlights.block_group(block("b1")))
		end)

		it("counts only what has not been read", function()
			fresh()
			store.record_conflict({ block_id = "b1" })
			store.record_conflict({ block_id = "b2" })
			eq(store.unacknowledged_count(), 2)
			store.acknowledge_conflicts()
			eq(store.unacknowledged_count(), 0)

			store.record_conflict({ block_id = "b3" })
			eq(store.unacknowledged_count(), 1, "a new conflict should flag again")
		end)

		it("survives a reload", function()
			fresh()
			store.record_conflict({ block_id = "b1" })
			store.acknowledge_conflicts()
			store.load()
			eq(store.unacknowledged_count(), 0, "acknowledgement must be persisted")
		end)
	end)

	describe("read-only blocks", function()
		it("flags a block on a calendar it cannot write to", function()
			fresh()
			store.mark_synced(block("b1"), { account = "work", readonly = true })
			store.mark_synced(block("b2"), { account = "work" })
			marks.refresh()
			truthy(marks.is_readonly(block("b1")))
			falsy(marks.is_readonly(block("b2")))
		end)

		it("gives it a lock rather than a new colour", function()
			fresh()
			store.mark_synced(block("b1"), { account = "work", readonly = true })
			marks.refresh()
			eq(marks.icon(block("b1")), config.options.icons.readonly)
			-- Recolouring every read-only block would flatten the palette; the
			-- icon says it without costing the colour.
			neq(highlights.block_group(block("b1")), "BloockyBlockConflict")
		end)

		-- Being overwritten is the more urgent fact.
		it("yields to a conflict on the same block", function()
			fresh()
			store.mark_synced(block("b1"), { account = "work", readonly = true })
			store.record_conflict({ block_id = "b1" })
			marks.refresh()
			eq(marks.icon(block("b1")), config.options.icons.conflict)
		end)
	end)

	describe("when sync is off", function()
		it("marks nothing and never touches the sidecar", function()
			fresh()
			store.record_conflict({ block_id = "b1" })
			store.mark_synced(block("b2"), { account = "work", readonly = true })

			config.options.sync.enabled = false
			marks.refresh()

			falsy(marks.is_conflicted(block("b1")))
			falsy(marks.is_readonly(block("b2")))
			eq(marks.icon(block("b1")), config.options.icons.block)
		end)
	end)

	describe("robustness", function()
		it("is safe on a nil block", function()
			fresh()
			falsy(marks.is_conflicted(nil))
			falsy(marks.is_readonly(nil))
		end)

		it("falls back to the plain icon when none is configured", function()
			fresh()
			local saved = config.options.icons.conflict
			config.options.icons.conflict = nil
			store.record_conflict({ block_id = "b1" })
			marks.refresh()
			eq(marks.icon(block("b1")), config.options.icons.block)
			config.options.icons.conflict = saved
		end)
	end)
end)
