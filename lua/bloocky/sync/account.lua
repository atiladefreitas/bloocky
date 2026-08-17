-- Resolving accounts and the secrets they need.
--
-- The rule (CALENDARS.md): a password never lives in the Lua config. What
-- lives there is a *command* that prints one — `pass show ...`, `op read ...`,
-- anything. The value is fetched when it is needed and cached for the session
-- only.

local config = require("bloocky.config")
local http = require("bloocky.sync.http")

local M = {}

local secrets = {}

-- Deep-copied on every call: normalization and the sync engine's bookkeeping
-- write onto these tables, and the originals are the very tables the user
-- passed to setup(). Their config should never grow fields they did not write.
function M.accounts()
	local sync = config.options.sync or {}
	return vim.deepcopy(sync.accounts or {})
end

function M.get(account_id)
	for _, account in ipairs(M.accounts()) do
		if account.id == account_id then
			return account
		end
	end
	return nil
end

-- Run a `*_cmd` and return its first line. Errors are reported without the
-- output, since the output is the secret.
local function run_secret_cmd(cmd, label)
	if type(cmd) == "string" then
		cmd = { "sh", "-c", cmd }
	end
	if type(cmd) ~= "table" or #cmd == 0 then
		return nil, label .. " must be a command (a list of arguments, or a shell string)"
	end

	local ok, result = pcall(function()
		return vim.system(cmd, { text = true }):wait()
	end)
	if not ok then
		local message = http.redact(tostring(result))
		-- By far the most common cause is naming a password manager that is
		-- not installed, so say that rather than quoting a libuv errno.
		if message:find("ENOENT", 1, true) then
			return nil, ("%s: `%s` is not installed or not on your PATH"):format(label, tostring(cmd[1]))
		end
		return nil, ("could not run %s: %s"):format(label, message ~= "" and message or "unknown error")
	end
	if result.code ~= 0 then
		local detail = vim.trim(http.redact(result.stderr or ""))
		return nil, ("%s exited with %d%s"):format(label, result.code, detail ~= "" and (": " .. detail) or "")
	end

	local value = (result.stdout or ""):match("^[^\r\n]*")
	if not value or value == "" then
		return nil, label .. " produced no output"
	end
	return value, nil
end

-- The secret for an account, from `<field>_cmd` if present, else the plain
-- `<field>`. Cached per session so a sync does not prompt a keyring on every
-- request.
function M.secret(account, field)
	local key = account.id .. "/" .. field
	if secrets[key] then
		return secrets[key], nil
	end

	local cmd = account[field .. "_cmd"]
	if cmd then
		local value, err = run_secret_cmd(cmd, account.id .. "." .. field .. "_cmd")
		if not value then
			return nil, err
		end
		secrets[key] = value
		return value, nil
	end

	local plain = account[field]
	if plain and plain ~= "" then
		secrets[key] = plain
		return plain, nil
	end

	return nil, ("%s: no %s or %s_cmd configured"):format(account.id, field, field)
end

function M.forget_secrets(account_id)
	for key in pairs(secrets) do
		if not account_id or key:match("^" .. vim.pesc(account_id) .. "/") then
			secrets[key] = nil
		end
	end
end

--------------------------------------------------------------------------
-- Validation
--------------------------------------------------------------------------

local PROVIDERS = { caldav = true, google = true }

-- Fill in what a provider can infer, so the rest of the code can assume it is
-- there. Idempotent; called from validate and before every sync. Google needs
-- nothing today: the REST provider builds its own endpoints, and calendars are
-- chosen with `calendars = { { name = ... } }`, same as CalDAV.
function M.normalize(account)
	return account
end

-- Returns a list of problems, empty when the account is usable. Checked up
-- front so a misconfiguration is reported once, plainly, instead of surfacing
-- as a confusing HTTP failure mid-sync.
function M.validate(account)
	local problems = {}
	M.normalize(account)

	if type(account.id) ~= "string" or account.id == "" then
		table.insert(problems, "an account needs an `id`")
	end
	if not PROVIDERS[account.provider] then
		table.insert(problems, ("unknown provider %q (expected caldav or google)"):format(tostring(account.provider)))
	end

	if account.provider == "caldav" then
		if type(account.url) ~= "string" or account.url == "" then
			table.insert(problems, "caldav accounts need a `url`")
		else
			local refusal = http.check_url(account.url)
			if refusal then
				table.insert(problems, refusal)
			end
		end
		if not account.username then
			table.insert(problems, "caldav accounts need a `username`")
		end
		if not (account.password or account.password_cmd) then
			table.insert(problems, "caldav accounts need `password_cmd` (preferred) or `password`")
		end
	end

	if account.provider == "google" then
		if not account.client_id or account.client_id == "" then
			table.insert(problems, "google accounts need a `client_id` from your own Google Cloud project")
		end
		-- A leftover option from the CalDAV-bridge design. Saying so beats
		-- silently syncing every calendar under someone who set it expecting
		-- the sync to be limited to one.
		if account.calendar_id then
			table.insert(
				problems,
				"WARN " .. tostring(account.id) .. ": `calendar_id` does nothing; pick calendars with `calendars = { { name = ... } }`"
			)
		end
		-- Fatal, not a warning: there is nothing useful a sync can do without a
		-- token, and burying this among warnings sends people hunting through
		-- a sync report for the real cause.
		if not require("bloocky.sync.oauth").authorised(account.id) then
			table.insert(problems, ("%s is not authorised yet - run `:BloockySyncAuth %s` first"):format(account.id, account.id))
		end
	end

	if account.client_secret and not account.client_secret_cmd then
		table.insert(
			problems,
			"WARN " .. tostring(account.id) .. ": `client_secret` is in plain text in your config; prefer `client_secret_cmd`"
		)
	end

	if account.password and not account.password_cmd then
		table.insert(
			problems,
			"WARN " .. account.id .. ": `password` is stored in plain text in your config; prefer `password_cmd`"
		)
	end

	for _, calendar in ipairs(account.calendars or {}) do
		if calendar.mode and calendar.mode ~= "rw" and calendar.mode ~= "ro" then
			table.insert(problems, ("calendar mode %q must be \"rw\" or \"ro\""):format(tostring(calendar.mode)))
		end
	end

	return problems
end

function M.writable(calendar)
	return (calendar.mode or "rw") == "rw"
end

-- The calendar new blocks are created in: the one marked default, else the
-- first writable one.
function M.default_calendar(account)
	local first_writable = nil
	for _, calendar in ipairs(account.calendars or {}) do
		if M.writable(calendar) then
			if calendar.default then
				return calendar
			end
			first_writable = first_writable or calendar
		end
	end
	return first_writable
end

return M
