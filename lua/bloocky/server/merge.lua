-- Three-way merge for LOCAL-ONLY time blocks — the companion-app bus.
--
-- Same doctrine as dooing's todo merge (the reference for the semantics):
-- base decides WHETHER something changed, updated_at only breaks genuine
-- conflicts (exact ties to the lexicographically smaller device id),
-- delete-vs-edit resurrects, notes take a strict superset silently, and
-- every losing value is returned for the trail. What differs is the field
-- groups: blocks have no tree and no derived category, and TIMING moves as
-- one unit — date, start, duration and all_day describe a single placement
-- on the calendar, and mixing two sides' halves would invent a time neither
-- side ever chose.
--
-- Calendar-backed blocks (source ~= "local") NEVER travel this bus — one
-- road per block. Enforced by the exchange, assumed here.
--
-- Behaviour is pinned by spec/fixtures/appsync/cases.json, which the app's
-- port runs verbatim.

local canonical = require("bloocky.server.canonical")

local M = {}

local NIL = vim.NIL

M.GROUPS = {
	{ name = "title", fields = { "title" } },
	{ name = "timing", fields = { "date", "start_min", "duration_min", "all_day" } },
	{ name = "notes", fields = { "notes" } },
	{ name = "recurrence", fields = { "recurrence" } },
}

local function val(block, field)
	local v = block[field]
	if v == NIL then
		return nil
	end
	return v
end

local function group_value(block, group)
	local out = {}
	for _, field in ipairs(group.fields) do
		out[field] = block and val(block, field) or nil
	end
	return out
end

local function group_changed(block, base, group)
	if not base then
		return true
	end
	return not canonical.equal(group_value(block, group), group_value(base, group))
end

local function changed_at(block)
	return val(block, "updated_at") or val(block, "created_at") or 0
end

local function newer_side(l, r, local_device, remote_device)
	local lu, ru = changed_at(l), changed_at(r)
	if lu ~= ru then
		return lu > ru and "local" or "remote"
	end
	return tostring(local_device) < tostring(remote_device) and "local" or "remote"
end

local function notes_superset(a, b)
	if type(a) ~= "string" or type(b) ~= "string" or #a <= #b then
		return false
	end
	return a:sub(1, #b) == b or a:sub(-#b) == b
end

local function any_group_changed(block, base)
	for _, group in ipairs(M.GROUPS) do
		if group_changed(block, base, group) then
			return true
		end
	end
	return false
end

local function merge_groups(id, b, l, r, local_device, remote_device, conflicts)
	local result = { id = id }

	for _, group in ipairs(M.GROUPS) do
		local lc = group_changed(l, b, group)
		local rc = group_changed(r, b, group)
		local winner

		if not lc and not rc then
			winner = b
		elseif lc and not rc then
			winner = l
		elseif rc and not lc then
			winner = r
		elseif canonical.equal(group_value(l, group), group_value(r, group)) then
			winner = l
		elseif group.name == "notes" and notes_superset(val(l, "notes") or "", val(r, "notes") or "") then
			winner = l
		elseif group.name == "notes" and notes_superset(val(r, "notes") or "", val(l, "notes") or "") then
			winner = r
		else
			local side = newer_side(l, r, local_device, remote_device)
			winner = side == "local" and l or r
			local loser = side == "local" and r or l
			table.insert(conflicts, {
				id = id,
				kind = "edit-vs-edit",
				group = group.name,
				winner = side,
				loser_value = group_value(loser, group),
			})
		end

		for _, field in ipairs(group.fields) do
			result[field] = winner and val(winner, field) or nil
		end
	end

	local lc_at, rc_at = val(l, "created_at"), val(r, "created_at")
	if b and val(b, "created_at") then
		result.created_at = val(b, "created_at")
	elseif lc_at and rc_at then
		result.created_at = math.min(lc_at, rc_at)
	else
		result.created_at = lc_at or rc_at
	end

	local u = math.max(val(l, "updated_at") or 0, val(r, "updated_at") or 0)
	result.updated_at = u > 0 and u or nil

	-- Both inputs are local-bus blocks by contract; keep whichever spelling
	-- of "local" they carry (absent means local, docs/block-structure.md).
	result.source = val(l, "source") or val(r, "source")
	return result
end

--- Same contract shape as dooing's merge.merge, over blocks.
function M.merge(input)
	local base = input.base or {}
	local local_device = input.local_device or "local"
	local remote_device = input.remote_device or "remote"

	local locals_by_id, local_order = {}, {}
	for _, block in ipairs(input.local_blocks or {}) do
		locals_by_id[block.id] = block
		table.insert(local_order, block.id)
	end
	local remotes_by_id, remote_order = {}, {}
	for _, block in ipairs(input.remote_blocks or {}) do
		remotes_by_id[block.id] = block
		table.insert(remote_order, block.id)
	end
	local tomb_by_id = {}
	for _, t in ipairs(input.local_tombstones or {}) do
		tomb_by_id[t.id] = t
	end
	for _, t in ipairs(input.remote_tombstones or {}) do
		tomb_by_id[t.id] = tomb_by_id[t.id] or t
	end

	local sequence, seen = {}, {}
	for _, id in ipairs(local_order) do
		table.insert(sequence, id)
		seen[id] = true
	end
	for _, id in ipairs(remote_order) do
		if not seen[id] then
			table.insert(sequence, id)
			seen[id] = true
		end
	end
	for id in pairs(base) do
		if not seen[id] then
			table.insert(sequence, id)
			seen[id] = true
		end
	end
	for id in pairs(tomb_by_id) do
		if not seen[id] then
			table.insert(sequence, id)
		end
	end

	local conflicts, tombstones, blocks = {}, {}, {}

	for _, id in ipairs(sequence) do
		local b, l, r = base[id], locals_by_id[id], remotes_by_id[id]

		if l and r then
			table.insert(blocks, merge_groups(id, b, l, r, local_device, remote_device, conflicts))
		elseif l and not r then
			if b then
				if any_group_changed(l, b) then
					table.insert(blocks, vim.deepcopy(l))
					table.insert(conflicts, { id = id, kind = "delete-vs-edit", winner = "local" })
				else
					local t = tomb_by_id[id]
					table.insert(tombstones, { id = id, deleted_at = t and t.deleted_at or nil })
				end
			else
				table.insert(blocks, vim.deepcopy(l))
			end
		elseif r and not l then
			if b then
				if any_group_changed(r, b) then
					table.insert(blocks, vim.deepcopy(r))
					table.insert(conflicts, { id = id, kind = "delete-vs-edit", winner = "remote" })
				else
					local t = tomb_by_id[id]
					table.insert(tombstones, { id = id, deleted_at = t and t.deleted_at or nil })
				end
			else
				table.insert(blocks, vim.deepcopy(r))
			end
		end
		-- Gone from both sides: agreement; the tombstone has done its job.
	end

	local new_base = {}
	for _, block in ipairs(blocks) do
		new_base[block.id] = block
	end

	return { blocks = blocks, tombstones = tombstones, base = new_base, conflicts = conflicts }
end

return M
