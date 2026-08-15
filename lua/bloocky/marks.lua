-- What the sync layer knows that the grid ought to show.
--
-- Two facts live in the sync sidecar but matter visually: a block the calendar
-- overwrote, and a block on a calendar you cannot write to. Without them the
-- grid quietly lies — a conflict is a notification you may have missed, and a
-- read-only block looks exactly like an editable one right up until your edit
-- is handed back.
--
-- The sets are read once per redraw rather than per block, and not at all when
-- sync is off, so the render path stays free of sync entirely for users who
-- never turn it on.

local config = require("bloocky.config")

local M = {}

local conflicted, readonly = {}, {}

function M.refresh()
	conflicted, readonly = {}, {}

	local sync = config.options.sync
	if not (sync and sync.enabled) then
		return
	end
	local ok, store = pcall(require, "bloocky.sync.store")
	if not ok then
		return
	end
	-- A broken sidecar must not take the calendar down with it.
	pcall(function()
		conflicted = store.conflicted_ids()
		readonly = store.readonly_ids()
	end)
end

function M.is_conflicted(block)
	return block ~= nil and conflicted[block.id] == true
end

function M.is_readonly(block)
	return block ~= nil and readonly[block.id] == true
end

function M.any_conflicts()
	return next(conflicted) ~= nil
end

-- The leading glyph on a block. Conflict wins over read-only: being overwritten
-- is the more urgent of the two.
function M.icon(block)
	local icons = config.options.icons
	if M.is_conflicted(block) then
		return icons.conflict or icons.block
	end
	if M.is_readonly(block) then
		return icons.readonly or icons.block
	end
	return icons.block
end

return M
