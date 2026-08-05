local config = require("bloocky.config")

local M = {}

local warned = false
local tried_load = false

-- Read-only access to dooing.nvim's state, if installed and enabled
local function dooing_state()
	local opts = config.options.integrations.dooing
	if not (opts and opts.enabled) then
		return nil
	end
	local ok, dstate = pcall(require, "dooing.state")
	if not ok or type(dstate) ~= "table" then
		if not warned then
			vim.notify("Bloocky: dooing integration is enabled but dooing.nvim was not found", vim.log.levels.WARN)
			warned = true
		end
		return nil
	end
	if (type(dstate.todos) ~= "table" or #dstate.todos == 0) and not tried_load then
		tried_load = true
		if type(dstate.load_todos) == "function" then
			pcall(dstate.load_todos)
		end
	end
	return dstate
end

function M.enabled()
	local opts = config.options.integrations.dooing
	return opts and opts.enabled or false
end

-- Dooing todos due on the given day ("YYYY-MM-DD")
function M.tasks_for_date(date_str)
	local dstate = dooing_state()
	if not dstate or type(dstate.todos) ~= "table" then
		return {}
	end
	local show_done = config.options.integrations.dooing.show_done
	local out = {}
	for _, todo in ipairs(dstate.todos) do
		if type(todo) == "table" and todo.due_at and (show_done or not todo.done) then
			if os.date("%Y-%m-%d", todo.due_at) == date_str then
				table.insert(out, todo)
			end
		end
	end
	return out
end

return M
