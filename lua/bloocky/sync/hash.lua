-- Content hash of the fields that describe an event.
--
-- The sync engine keeps asking one question: "did this block change since we
-- last talked to the server?" Comparing a fresh hash against the one stored at
-- the last successful sync answers it without trusting `updated_at` — a
-- companion app writing the JSON directly may never bump that field, and a
-- clock that jumped would make it lie.

local M = {}

-- Length-prefix every part so no value can impersonate a delimiter: a title of
-- "a|b" and the pair ("a", "b") must not hash alike.
local function part(s)
	s = tostring(s or "")
	return #s .. ":" .. s
end

local function num(n)
	return part(string.format("%d", n or 0))
end

-- vim.json.decode turns JSON null into vim.NIL, which is *truthy* in Lua.
-- Treat it as "no recurrence", exactly like state.occurs_on does.
local function recurrence_key(r)
	if type(r) ~= "table" or r == vim.NIL then
		return part("")
	end
	local days = {}
	for _, d in ipairs(r.days or {}) do
		table.insert(days, string.format("%d", d))
	end
	table.sort(days) -- the order inside `days` carries no meaning
	return part(r.type or "") .. part(table.concat(days, ",")) .. part(r.until_date or "")
end

-- Only the fields a remote calendar actually carries. `id`, `created_at`,
-- `updated_at` and `source` are bloocky's own bookkeeping — changing them is
-- not a change to the event, and must not trigger a push.
function M.block(block)
	return vim.fn.sha256(table.concat({
		part(block.title),
		part(block.date),
		num(block.start_min),
		num(block.duration_min),
		part(block.notes),
		recurrence_key(block.recurrence),
	}))
end

return M
