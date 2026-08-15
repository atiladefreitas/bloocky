-- :checkhealth bloocky
--
-- Sync has a lot of moving parts that fail off-screen: a password command that
-- is not installed, a token that expired, a zoneinfo database that is missing.
-- Each of those produced a confusing report before it produced a useful error,
-- so they are all checked here in one place, up front.

local M = {}

local function ok(message)
	vim.health.ok(message)
end

local function warn(message, advice)
	vim.health.warn(message, advice)
end

local function err(message, advice)
	vim.health.error(message, advice)
end

--------------------------------------------------------------------------

local function check_neovim()
  vim.health.start("bloocky: Neovim")

	if vim.fn.has("nvim-0.10") == 1 then
		ok("Neovim " .. tostring(vim.version()))
	else
		err("Neovim 0.10 or newer is required", "bloocky uses vim.uv, vim.system and vim.base64.")
	end

	for name, present in pairs({
		["vim.system"] = type(vim.system) == "function",
		["vim.uv"] = type(vim.uv) == "table",
		["vim.base64"] = type(vim.base64) == "table",
		["vim.fn.sha256"] = vim.fn.exists("*sha256") == 1,
	}) do
		if present then
			ok(name .. " available")
		else
			err(name .. " is missing", "Sync cannot run without it.")
		end
	end
end

local function check_storage()
	vim.health.start("bloocky: storage")
	local config = require("bloocky.config")

	local path = config.options.save_path
	local dir = vim.fn.fnamemodify(path, ":h")
	if vim.fn.isdirectory(dir) == 1 or vim.fn.mkdir(dir, "p") == 1 then
		ok("blocks: " .. path)
	else
		err("cannot create " .. dir, "Check save_path.")
	end

	local count = "unknown"
	local file = io.open(path, "r")
	if file then
		local content = file:read("*a")
		file:close()
		local decoded_ok, decoded = pcall(vim.json.decode, content ~= "" and content or "[]")
		if decoded_ok and type(decoded) == "table" then
			count = tostring(#decoded)
			ok(count .. " block(s) stored")
		else
			err("the blocks file is not valid JSON", "bloocky will start empty rather than overwrite it.")
		end
	else
		ok("no blocks file yet (it appears on your first block)")
	end
end

local function check_sync()
	vim.health.start("bloocky: calendar sync")
	local config = require("bloocky.config")
	local sync = config.options.sync or {}

	if not sync.enabled then
		ok("disabled (set sync.enabled = true to turn it on — see CALENDARS.md)")
		return
	end

	if vim.fn.executable("curl") == 1 then
		local version = vim.fn.systemlist({ "curl", "--version" })[1] or "curl"
		ok(version:match("^[^%(]+") or version)
	else
		err("curl is not installed", "Every network call goes through curl.")
	end

	local accounts = sync.accounts or {}
	if #accounts == 0 then
		warn("sync is enabled but no accounts are configured", "See CALENDARS.md.")
		return
	end

	local account_config = require("bloocky.sync.account")
	local store = require("bloocky.sync.store")

	for _, account in ipairs(accounts) do
		vim.health.start("bloocky: account '" .. tostring(account.id) .. "' (" .. tostring(account.provider) .. ")")

		local problems = account_config.validate(account)
		if #problems == 0 then
			ok("configuration looks usable")
		end
		for _, problem in ipairs(problems) do
			if problem:match("^WARN ") then
				warn(problem:sub(6))
			else
				err(problem)
			end
		end

		-- Run the secret command for real. "It is configured" and "it works"
		-- are different claims, and the gap between them is where setup fails.
		for _, field in ipairs({ "password", "client_secret" }) do
			if account[field .. "_cmd"] then
				account_config.forget_secrets(account.id)
				local value, secret_err = account_config.secret(account, field)
				if value then
					ok(field .. "_cmd works (" .. #value .. " characters)")
				else
					err(field .. "_cmd failed: " .. tostring(secret_err), "Try running it in a shell.")
				end
			elseif account[field] then
				warn(field .. " is in plain text in your config", "Prefer " .. field .. "_cmd.")
			end
		end

		if account.provider == "google" then
			local oauth = require("bloocky.sync.oauth")
			local record = oauth.tokens_for(account.id)
			if not record then
				err("not authorised", "Run :BloockySyncAuth " .. tostring(account.id))
			else
				local stat = vim.uv.fs_stat(oauth.path())
				local mode = stat and string.format("%o", stat.mode % 512) or "?"
				if mode == "600" then
					ok("token stored, readable only by you")
				else
					warn("the token file is mode " .. mode, "It should be 600: " .. oauth.path())
				end

				if not record.refresh_token then
					warn("no refresh token", "You will have to re-authorise when this one expires.")
				elseif record.expires_at and record.expires_at < os.time() then
					ok("access token expired; it will be refreshed on the next sync")
				else
					ok("token valid")
				end
			end
		end

		local info = store.account(account.id)
		ok("last sync: " .. (info.last_sync and os.date("%Y-%m-%d %H:%M", info.last_sync) or "never"))

		local pending = store.local_changes(require("bloocky.state").blocks)
		local waiting = #pending.created + #pending.updated + #store.tombstones(account.id)
		if waiting > 0 then
			ok(waiting .. " change(s) waiting to go up")
		end
	end

	local unread = store.unacknowledged_count()
	if unread > 0 then
		warn(unread .. " unread conflict(s)", "Run :BloockySyncReport to see what the calendar overwrote.")
	end
end

local function check_timezone()
	vim.health.start("bloocky: timezone")
	local tz = require("bloocky.sync.tz")

	local zone = tz.local_zone()
	if zone then
		ok("local zone: " .. zone)
	else
		warn(
			"could not work out your IANA timezone",
			"Events in another zone will be read at face value. Set $TZ, or check /etc/localtime."
		)
	end

	-- Non-local TZIDs are resolved through the system tz database; without it
	-- an event in another zone lands at the wrong hour with nothing to notice.
	if tz.zone_exists("America/New_York") then
		ok("system timezone database available")
	else
		warn(
			"no /usr/share/zoneinfo",
			"Events carrying a timezone other than yours will be read as local time."
		)
	end
end

local function check_appearance()
	vim.health.start("bloocky: appearance")
	local icons = require("bloocky.config").options.icons
	local names = {}
	for _, name in ipairs({ "block", "recurring", "all_day", "conflict", "readonly", "dooing" }) do
		if icons[name] and icons[name] ~= "" then
			table.insert(names, icons[name])
		end
	end
	ok("icons: " .. table.concat(names, " ") .. "  (a Nerd Font renders these; override `icons` if not)")

	local integrations = require("bloocky.config").options.integrations or {}
	if integrations.dooing and integrations.dooing.enabled then
		if pcall(require, "dooing.state") then
			ok("dooing integration enabled and dooing.nvim found")
		else
			err("dooing integration is enabled but dooing.nvim is not installed")
		end
	end
end

function M.check()
	check_neovim()
	check_storage()
	check_timezone()
	check_appearance()
	check_sync()
end

return M
