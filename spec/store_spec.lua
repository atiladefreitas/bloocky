local config = require("bloocky.config")
local store = require("bloocky.sync.store")

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")

local counter = 0

-- Each test gets its own file and a freshly loaded store, so nothing leaks
-- between them through the module-level cache.
local function fresh()
	counter = counter + 1
	config.options.sync = config.options.sync or {}
	config.options.sync.store_path = ("%s/sync_%d.json"):format(tmpdir, counter)
	store.load()
	return config.options.sync.store_path
end

local function block(overrides)
	return vim.tbl_extend("force", {
		id = "1755043200_4821",
		title = "Deep work",
		date = "2026-08-13",
		start_min = 540,
		duration_min = 90,
		notes = "",
	}, overrides or {})
end

describe("sync.store", function()
	describe("persistence", function()
		it("starts empty when there is no file", function()
			fresh()
			eq(store.tombstones(), {})
			eq(store.conflicts(), {})
			eq(store.get_mapping("anything"), nil)
		end)

		it("round-trips through the file", function()
			fresh()
			local b = block()
			store.mark_synced(b, { account = "work", uid = "abc@example.com", etag = '"v1"' })
			store.load() -- drop the in-memory copy, read it back off disk

			local mapping = store.get_mapping(b.id)
			eq(mapping.account, "work")
			eq(mapping.uid, "abc@example.com")
			eq(mapping.etag, '"v1"')
			truthy(mapping.base_hash)
		end)

		it("leaves no temp file behind", function()
			local path = fresh()
			store.mark_synced(block(), { account = "work" })
			eq(vim.fn.filereadable(path), 1)
			eq(vim.fn.filereadable(path .. ".tmp"), 0, "the temp file should have been renamed away")
		end)

		it("starts fresh rather than throwing on a corrupt file", function()
			local path = fresh()
			vim.fn.writefile({ "{ this is not json" }, path)
			store.load()
			eq(store.conflicts(), {})
		end)

		-- An older bloocky must not overwrite state it cannot understand.
		it("refuses to write over a newer format", function()
			local path = fresh()
			vim.fn.writefile({ vim.json.encode({ version = 99, mappings = {}, conflicts = {} }) }, path)
			store.load()
			falsy(store.save())
			eq(vim.json.decode(table.concat(vim.fn.readfile(path), "\n")).version, 99)
		end)
	end)

	describe("local_changes", function()
		it("treats an unmapped block as a creation", function()
			fresh()
			local b = block()
			local changes = store.local_changes({ b })
			eq(#changes.created, 1)
			eq(#changes.updated, 0)
		end)

		it("sees nothing to do right after a sync", function()
			fresh()
			local b = block()
			store.mark_synced(b, { account = "work" })
			local changes = store.local_changes({ b })
			eq(#changes.created, 0)
			eq(#changes.updated, 0)
		end)

		it("spots an edit made after the last sync", function()
			fresh()
			local b = block()
			store.mark_synced(b, { account = "work" })
			b.title = "Shallow work"
			local changes = store.local_changes({ b })
			eq(#changes.updated, 1)
			eq(changes.updated[1].title, "Shallow work")
		end)

		-- The point of hashing rather than trusting updated_at: a companion app
		-- writing the JSON directly may never bump it.
		it("catches an edit that never touched updated_at", function()
			fresh()
			local b = block({ updated_at = 1755043200 })
			store.mark_synced(b, { account = "work" })
			b.start_min = 600 -- moved, timestamp untouched
			eq(#store.local_changes({ b }).updated, 1)
		end)

		it("never queues a push to a read-only calendar", function()
			fresh()
			local b = block()
			store.mark_synced(b, { account = "work", readonly = true })
			b.title = "Edited anyway"
			eq(#store.local_changes({ b }).updated, 0)
		end)
	end)

	describe("tombstones", function()
		it("records one for a synced block", function()
			fresh()
			local b = block()
			store.mark_synced(b, { account = "work", uid = "abc", href = "/cal/abc.ics", etag = '"v1"' })
			local tombstone = store.record_deletion(b)

			eq(tombstone.uid, "abc")
			eq(tombstone.href, "/cal/abc.ics")
			eq(tombstone.etag, '"v1"')
			eq(tombstone.title, "Deep work", "the title is kept for the report")
			eq(#store.tombstones(), 1)
		end)

		-- Nothing upstream to delete, so a tombstone would only be noise.
		it("records nothing for a block that was never synced", function()
			fresh()
			eq(store.record_deletion(block()), nil)
			eq(#store.tombstones(), 0)
		end)

		it("drops the mapping so the block is not also seen as an edit", function()
			fresh()
			local b = block()
			store.mark_synced(b, { account = "work" })
			store.record_deletion(b)
			eq(store.get_mapping(b.id), nil)
		end)

		it("filters by account", function()
			fresh()
			local work, home = block({ id = "a" }), block({ id = "b" })
			store.mark_synced(work, { account = "work" })
			store.mark_synced(home, { account = "home" })
			store.record_deletion(work)
			store.record_deletion(home)

			eq(#store.tombstones("work"), 1)
			eq(store.tombstones("work")[1].id, "a")
			eq(#store.tombstones(), 2)
		end)

		it("clears one once the remote delete lands", function()
			fresh()
			local b = block()
			store.mark_synced(b, { account = "work" })
			store.record_deletion(b)
			truthy(store.clear_tombstone(b.id))
			eq(#store.tombstones(), 0)
			falsy(store.clear_tombstone(b.id), "clearing twice is a no-op")
		end)
	end)

	describe("conflicts", function()
		it("keeps the losing local version", function()
			fresh()
			store.record_conflict({ block_id = "a", local_version = { title = "Mine" }, remote = { title = "Theirs" } })
			local trail = store.conflicts()
			eq(#trail, 1)
			eq(trail[1].local_version.title, "Mine")
			truthy(trail[1].at, "entries are timestamped for the report")
		end)

		it("trims the oldest past the limit", function()
			fresh()
			config.options.sync.conflict = { trail_limit = 3 }
			for i = 1, 5 do
				store.record_conflict({ block_id = "block" .. i })
			end
			local trail = store.conflicts()
			eq(#trail, 3)
			eq(trail[1].block_id, "block3", "the oldest entries fall off the front")
			eq(trail[3].block_id, "block5")
			config.options.sync.conflict = { trail_limit = 50 }
		end)
	end)

	describe("reset", function()
		it("clears one account and leaves the others alone", function()
			fresh()
			local work, home = block({ id = "a" }), block({ id = "b" })
			store.mark_synced(work, { account = "work" })
			store.mark_synced(home, { account = "home" })
			store.set_cursor("work", "cursor-1")

			store.reset("work")

			eq(store.get_mapping("a"), nil)
			truthy(store.get_mapping("b"), "the other account is untouched")
			eq(store.account("work").cursor, nil)
		end)

		it("clears everything when given no account", function()
			fresh()
			store.mark_synced(block(), { account = "work" })
			store.reset()
			eq(store.get_mapping("1755043200_4821"), nil)
		end)
	end)
end)
