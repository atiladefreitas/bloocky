-- Async HTTP over curl.
--
-- Two rules shape this module:
--
-- Secrets never touch argv. Anything on a command line is visible to every
-- other process on the machine via `ps`, so credentials go into a temp curl
-- config file created 0600 and passed with `-K`. That covers Basic auth and
-- bearer tokens alike.
--
-- TLS is never optional. A plain-HTTP URL is refused unless it is loopback,
-- and there is no flag to skip certificate verification — sync carries
-- calendar contents and long-lived tokens.

local M = {}

local RETRY_STATUS = { [429] = true, [500] = true, [502] = true, [503] = true, [504] = true }

--------------------------------------------------------------------------
-- Redaction
--------------------------------------------------------------------------

-- Applied to everything that could reach a log, a notification or a debug
-- buffer. Tested, because a redactor that quietly stops matching is worse than
-- no redactor at all.
function M.redact(text)
	if type(text) ~= "string" then
		return text
	end
	local out = text
	out = out:gsub("([Aa]uthorization%s*:%s*%a+%s+)[%w%._%-~%+/=]+", "%1<redacted>")
	out = out:gsub("(%-%-?[uU]%s+)%S+", "%1<redacted>")
	out = out:gsub("(user%s*=%s*)%S+", "%1<redacted>")
	out = out:gsub('(header%s*=%s*"[Aa]uthorization%s*:%s*%a+%s+)[^"]+', "%1<redacted>")
	-- JSON payloads from the token endpoint
	for _, key in ipairs({
		"access_token",
		"refresh_token",
		"client_secret",
		"id_token",
		"code_verifier",
		"code",
		"password",
		"token",
	}) do
		out = out:gsub('(["\']' .. key .. '["\']%s*:%s*["\'])[^"\']*', "%1<redacted>")
		out = out:gsub("(" .. key .. "=)[^&%s]+", "%1<redacted>")
	end
	return out
end

--------------------------------------------------------------------------
-- URL safety
--------------------------------------------------------------------------

local LOOPBACK = { localhost = true, ["127.0.0.1"] = true, ["::1"] = true, ["[::1]"] = true }

-- Returns nil when the URL is safe to send credentials to, or a reason.
function M.check_url(url)
	if type(url) ~= "string" then
		return "missing URL"
	end
	local scheme, authority = url:match("^(%a[%w%+%.%-]*)://([^/?#]+)")
	if not scheme then
		return "malformed URL: " .. M.redact(url)
	end
	scheme = scheme:lower()
	if scheme == "https" then
		return nil
	end
	if scheme == "http" then
		local host = authority:match("^%[.-%]") or authority:match("^([^:]+)")
		if LOOPBACK[(host or ""):lower()] then
			return nil -- the OAuth loopback redirect, which never leaves the machine
		end
		return "refusing to use plain HTTP for " .. tostring(host) .. "; use https"
	end
	return "unsupported URL scheme: " .. scheme
end

--------------------------------------------------------------------------
-- Responses
--------------------------------------------------------------------------

-- curl dumps a header block per response, so redirects and "100 Continue"
-- leave several. The last block is the one that answered.
function M.parse_headers(raw)
	local status, headers = nil, {}
	for line in tostring(raw or ""):gmatch("[^\r\n]+") do
		local code = line:match("^HTTP/[%d%.]+%s+(%d+)")
		if code then
			status, headers = tonumber(code), {}
		else
			local name, value = line:match("^([^:]+):%s*(.*)$")
			if name then
				headers[name:lower()] = value
			end
		end
	end
	return status, headers
end

--------------------------------------------------------------------------
-- Requests
--------------------------------------------------------------------------

local function write_secret_config(lines)
	local path = vim.fn.tempname()
	-- Created 0600 up front rather than chmod'd afterwards, so the file is
	-- never briefly world-readable.
	local fd = vim.uv.fs_open(path, "w", tonumber("600", 8))
	if not fd then
		return nil
	end
	vim.uv.fs_write(fd, table.concat(lines, "\n") .. "\n")
	vim.uv.fs_close(fd)
	return path
end

local function quote(value)
	return '"' .. tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function build(opts)
	local args = {
		"curl",
		"--silent",
		"--show-error",
		"--connect-timeout",
		tostring(math.floor((opts.timeout or 30000) / 1000)),
		"--max-time",
		tostring(math.floor((opts.timeout or 30000) / 1000)),
	}

	-- Secrets go in the config file, everything else on the command line.
	local secrets = {}
	if opts.auth and opts.auth.user then
		table.insert(secrets, "user = " .. quote(opts.auth.user .. ":" .. (opts.auth.password or "")))
	end
	if opts.bearer then
		table.insert(secrets, "header = " .. quote("Authorization: Bearer " .. opts.bearer))
	end

	local config_path = nil
	if #secrets > 0 then
		config_path = write_secret_config(secrets)
		if config_path then
			table.insert(args, "--config")
			table.insert(args, config_path)
		end
	end

	if opts.follow then
		table.insert(args, "--location")
	end
	if opts.method and opts.method ~= "GET" then
		table.insert(args, "--request")
		table.insert(args, opts.method)
	end
	for name, value in pairs(opts.headers or {}) do
		table.insert(args, "--header")
		table.insert(args, name .. ": " .. value)
	end
	if opts.body then
		table.insert(args, "--data-binary")
		table.insert(args, "@-")
	end

	local header_path = vim.fn.tempname()
	table.insert(args, "--dump-header")
	table.insert(args, header_path)
	table.insert(args, opts.url)

	return args, header_path, config_path
end

local function cleanup(...)
	for _, path in ipairs({ ... }) do
		if path then
			os.remove(path)
		end
	end
end

-- request(opts, callback)
--
-- opts: url, method, headers, body, auth = { user, password }, bearer,
--       timeout (ms), retries, follow
-- callback(err, res) with res = { status, headers, body }
--
-- `err` is a redacted string. A non-2xx status is *not* an error — callers
-- need the code to react to 404, 410 and 412.
function M.request(opts, callback)
	local refusal = M.check_url(opts.url)
	if refusal then
		return vim.schedule(function()
			callback(refusal, nil)
		end)
	end

	local attempt, max_attempts = 0, (opts.retries or 2) + 1

	local function run()
		attempt = attempt + 1
		local args, header_path, config_path = build(opts)

		local function finish(err, res)
			cleanup(header_path, config_path)
			vim.schedule(function()
				callback(err, res)
			end)
		end

		local ok, err = pcall(vim.system, args, { stdin = opts.body, text = true }, function(result)
			local raw_headers = ""
			local file = io.open(header_path, "r")
			if file then
				raw_headers = file:read("*a") or ""
				file:close()
			end
			local status, headers = M.parse_headers(raw_headers)

			local failed = result.code ~= 0 or not status
			local retryable = failed or RETRY_STATUS[status]

			if retryable and attempt < max_attempts then
				cleanup(header_path, config_path)
				-- Honour Retry-After when the server sets it; otherwise back
				-- off exponentially from 500ms.
				local after = tonumber(headers["retry-after"])
				local delay = after and math.min(after * 1000, 30000) or (500 * 2 ^ (attempt - 1))
				return vim.defer_fn(run, delay)
			end

			if failed then
				local message = result.stderr ~= "" and result.stderr or ("curl exited with " .. result.code)
				return finish(M.redact(vim.trim(message)), nil)
			end

			finish(nil, { status = status, headers = headers, body = result.stdout or "" })
		end)

		if not ok then
			cleanup(header_path, config_path)
			vim.schedule(function()
				callback(M.redact(tostring(err)), nil)
			end)
		end
	end

	run()
end

return M
