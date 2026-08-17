-- One block-sync exchange with a paired device.
--
-- THE ONE-ROAD RULE lives here: only LOCAL blocks (source absent or
-- "local") travel this bus. Calendar-backed blocks converge through the
-- calendar itself — both sides are clients of it — and letting them ride
-- the LAN too is how you get duplicates. So the exchange filters to local
-- blocks on the way in, and reassembles the blocks file as
-- (untouched calendar-backed blocks) + (merged local blocks) on the way out.
--
-- The calendar sync's sidecar (bloocky_sync.json) is never touched: no
-- block it tracks is ever modified here.

local config = require("bloocky.config")
local devices = require("bloocky.server.devices")
local merge = require("bloocky.server.merge")
local state = require("bloocky.state")
local store = require("bloocky.server.store")

local M = {}

local SERVER_DEVICE = "server" -- hex device ids sort before "s": ties go to the device

local function is_local(block)
	return (block.source == nil or block.source == vim.NIL or block.source == "local")
end

local function split_blocks()
	state.ensure_loaded()
	local locals_, others = {}, {}
	for _, block in ipairs(state.blocks) do
		if is_local(block) then
			table.insert(locals_, block)
		else
			table.insert(others, block)
		end
	end
	return locals_, others
end

local function enrich_conflicts(conflicts, server_by_id, device_by_id)
	for _, conflict in ipairs(conflicts) do
		local loser
		if conflict.winner == "local" then
			loser = device_by_id[conflict.id]
		elseif conflict.winner == "remote" then
			loser = server_by_id[conflict.id]
		end
		if loser then
			conflict.loser_block = vim.deepcopy(loser)
		end
	end
end

function M.blocks_exchange(device, payload)
	if type(payload) ~= "table" or type(payload.blocks) ~= "table" then
		return nil, 400, "expected a JSON body with a blocks array"
	end

	-- Refuse calendar-backed blocks outright rather than silently dropping
	-- them: a client sending one has a routing bug worth hearing about.
	for _, block in ipairs(payload.blocks) do
		if type(block) == "table" and not is_local(block) then
			return nil, 400, ("block %s is calendar-backed (source=%s); it travels the calendar, not this bus"):format(
				tostring(block.id),
				tostring(block.source)
			)
		end
	end

	local local_blocks, other_blocks = split_blocks()
	local device_state = store.device(device.id)

	local result = merge.merge({
		base = device_state.base or {},
		local_blocks = local_blocks,
		remote_blocks = payload.blocks,
		local_tombstones = {},
		remote_tombstones = payload.tombstones or {},
		local_device = SERVER_DEVICE,
		remote_device = device.id,
	})

	local server_by_id, device_by_id = {}, {}
	for _, block in ipairs(local_blocks) do
		server_by_id[block.id] = block
	end
	for _, block in ipairs(payload.blocks) do
		device_by_id[block.id] = block
	end
	enrich_conflicts(result.conflicts, server_by_id, device_by_id)

	-- Reassemble: calendar-backed blocks exactly as they were, merged local
	-- blocks after them. save_blocks does not re-stamp updated_at — the
	-- merged values are part of the agreement.
	local next_blocks = {}
	for _, block in ipairs(other_blocks) do
		table.insert(next_blocks, block)
	end
	for _, block in ipairs(result.blocks) do
		table.insert(next_blocks, block)
	end
	state.blocks = next_blocks
	state.save_blocks()

	local revision = store.commit_exchange(device.id, result.base, result.tombstones)
	store.record_conflicts(device.id, result.conflicts)

	local changed = 0
	local after = {}
	for _, block in ipairs(result.blocks) do
		after[block.id] = true
		local prior = server_by_id[block.id]
		if not prior or (prior.updated_at or 0) ~= (block.updated_at or 0) then
			changed = changed + 1
		end
	end
	for _, block in ipairs(local_blocks) do
		if not after[block.id] then
			changed = changed + 1
		end
	end

	if #result.conflicts > 0 then
		vim.notify(
			("Bloocky app sync (%s): %d conflict%s resolved"):format(
				device.name or device.id,
				#result.conflicts,
				#result.conflicts == 1 and "" or "s"
			),
			vim.log.levels.WARN
		)
	elseif changed > 0 then
		vim.notify(
			("Bloocky app sync (%s): %d change%s"):format(device.name or device.id, changed, changed == 1 and "" or "s"),
			vim.log.levels.INFO
		)
	end

	if changed > 0 then
		pcall(function()
			require("bloocky.ui").render()
		end)
	end

	return {
		revision = revision,
		blocks = result.blocks,
		tombstones = result.tombstones,
		conflicts = result.conflicts,
	}
end

return M
