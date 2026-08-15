-- OAuth 2.0 with PKCE, over a loopback redirect (RFC 8252).
--
-- The security decisions here were made deliberately in docs/two-way-sync.md
-- and should not be relaxed casually:
--
--   * The OAuth client belongs to the *user*, not to bloocky. A client id
--     shipped in a public repo would be shared by everyone, so one user's
--     abuse could get it suspended for all of them, and the unverified-app
--     warning would train people to click through security prompts.
--   * PKCE S256 on every request, so an intercepted authorization code is
--     useless without the verifier.
--   * An ephemeral loopback port, never a fixed one — a fixed port is a
--     predictable target for anything else running on the machine.
--   * `state` is generated from a CSPRNG and verified on return.
--   * Tokens land in a file created 0600, never in the Lua config.
--   * Nothing token-shaped reaches a log without passing through redaction.

local account_config = require("bloocky.sync.account")
local async = require("bloocky.sync.async")
local http = require("bloocky.sync.http")

local M = {}

local PROVIDERS = {
	google = {
		authorize = "https://accounts.google.com/o/oauth2/v2/auth",
		token = "https://oauth2.googleapis.com/token",
		revoke = "https://oauth2.googleapis.com/revoke",
		-- Deliberately not "auth/calendar": that scope can delete entire
		-- calendars, and bloocky only ever needs to read the calendar list and
		-- edit events.
		scopes = {
			"https://www.googleapis.com/auth/calendar.events",
			"https://www.googleapis.com/auth/calendar.calendarlist.readonly",
		},
	},
}

function M.endpoints(account)
	return PROVIDERS[account.provider]
end

--------------------------------------------------------------------------
-- Token storage
--------------------------------------------------------------------------

local tokens = nil

function M.path()
	return vim.fn.stdpath("state") .. "/bloocky/tokens.json"
end

local function load_tokens()
	tokens = {}
	local file = io.open(M.path(), "r")
	if not file then
		return tokens
	end
	local content = file:read("*a")
	file:close()
	local ok, decoded = pcall(vim.json.decode, content or "")
	if ok and type(decoded) == "table" then
		tokens = decoded
	end
	return tokens
end

local function save_tokens()
	local path = M.path()
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local tmp = path .. ".tmp"

	-- Opened 0600 at creation rather than chmod'd afterwards, so the file is
	-- never briefly readable by anyone else.
	local fd = vim.uv.fs_open(tmp, "w", tonumber("600", 8))
	if not fd then
		vim.notify("Bloocky: could not write " .. tmp, vim.log.levels.ERROR)
		return false
	end
	vim.uv.fs_write(fd, vim.json.encode(tokens or {}))
	vim.uv.fs_close(fd)

	local ok, err = vim.uv.fs_rename(tmp, path)
	if not ok then
		os.remove(tmp)
		vim.notify("Bloocky: could not replace " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
		return false
	end
	return true
end

function M.tokens_for(account_id)
	if not tokens then
		load_tokens()
	end
	return tokens[account_id]
end

function M.store_tokens(account_id, record)
	if not tokens then
		load_tokens()
	end
	tokens[account_id] = record
	save_tokens()
end

function M.forget(account_id)
	if not tokens then
		load_tokens()
	end
	tokens[account_id] = nil
	save_tokens()
end

function M.authorised(account_id)
	local record = M.tokens_for(account_id)
	return record ~= nil and record.access_token ~= nil
end

--------------------------------------------------------------------------
-- PKCE
--------------------------------------------------------------------------

function M.base64url(bytes)
	return (vim.base64.encode(bytes):gsub("%+", "-"):gsub("/", "_"):gsub("=", ""))
end

-- libuv's CSPRNG, falling back to /dev/urandom. Never math.random: it is
-- seeded predictably and these values guard the whole exchange.
function M.random_bytes(count)
	local ok, bytes = pcall(vim.uv.random, count)
	if ok and type(bytes) == "string" and #bytes == count then
		return bytes
	end
	local file = io.open("/dev/urandom", "rb")
	if file then
		local raw = file:read(count)
		file:close()
		if raw and #raw == count then
			return raw
		end
	end
	error("no source of cryptographic randomness available", 0)
end

local function hex_to_bytes(hex)
	return (hex:gsub("%x%x", function(pair)
		return string.char(tonumber(pair, 16))
	end))
end

-- S256: challenge = base64url(sha256(verifier)). Verified against the RFC 7636
-- test vector in the specs.
function M.challenge_for(verifier)
	return M.base64url(hex_to_bytes(vim.fn.sha256(verifier)))
end

function M.new_verifier()
	-- 32 bytes -> 43 base64url characters, the minimum RFC 7636 allows.
	return M.base64url(M.random_bytes(32))
end

--------------------------------------------------------------------------
-- URL helpers
--------------------------------------------------------------------------

function M.encode(value)
	return (tostring(value):gsub("[^%w%-%._~]", function(char)
		return string.format("%%%02X", string.byte(char))
	end))
end

function M.query(params)
	local parts, keys = {}, vim.tbl_keys(params)
	table.sort(keys) -- deterministic, so tests can assert on the whole string
	for _, key in ipairs(keys) do
		table.insert(parts, M.encode(key) .. "=" .. M.encode(params[key]))
	end
	return table.concat(parts, "&")
end

-- "GET /?code=abc&state=xyz HTTP/1.1" -> { code = "abc", state = "xyz" }
function M.parse_redirect(request)
	local target = request:match("^%u+%s+(%S+)%s+HTTP/")
	if not target then
		return nil
	end
	local query = target:match("%?(.*)$")
	if not query then
		return {}
	end
	local params = {}
	for pair in query:gmatch("[^&]+") do
		local key, value = pair:match("^([^=]*)=?(.*)$")
		if key and key ~= "" then
			params[key] = (value:gsub("%+", " "):gsub("%%(%x%x)", function(hex)
				return string.char(tonumber(hex, 16))
			end))
		end
	end
	return params
end

--------------------------------------------------------------------------
-- The loopback listener
--------------------------------------------------------------------------

local PAGE = [[<!doctype html><html><head><meta charset="utf-8"><title>bloocky.nvim</title></head>
<body style="font-family:system-ui;padding:3rem;max-width:32rem">
<h1>%s</h1><p>%s</p><p style="color:#666">You can close this tab and go back to Neovim.</p>
</body></html>]]

local function respond(client, title, message)
	local body = PAGE:format(title, message)
	client:write(table.concat({
		"HTTP/1.1 200 OK",
		"Content-Type: text/html; charset=utf-8",
		"Content-Length: " .. #body,
		"Connection: close",
		"",
		body,
	}, "\r\n"))
end

-- Listens on an ephemeral loopback port and calls `callback(params, err)` once,
-- with the query parameters of the first request that carries a `code` or an
-- `error`. Returns the port so the caller can build the redirect URI.
function M.listen(timeout_ms, callback)
	local server = vim.uv.new_tcp()
	local finished = false

	local function finish(params, err)
		if finished then
			return
		end
		finished = true
		pcall(function()
			server:close()
		end)
		vim.schedule(function()
			callback(params, err)
		end)
	end

	local ok, err = pcall(function()
		assert(server:bind("127.0.0.1", 0))
	end)
	if not ok then
		pcall(function()
			server:close()
		end)
		return nil, "could not open a loopback listener: " .. tostring(err)
	end

	local port = server:getsockname().port

	server:listen(16, function(listen_err)
		if listen_err then
			return finish(nil, tostring(listen_err))
		end
		local client = vim.uv.new_tcp()
		server:accept(client)

		local buffer = ""
		client:read_start(function(read_err, chunk)
			if read_err or not chunk then
				pcall(function()
					client:close()
				end)
				return
			end
			buffer = buffer .. chunk
			-- Wait for the end of the request head; the parameters are all in
			-- the request line, so there is no body to worry about.
			if not buffer:find("\r\n\r\n", 1, true) and not buffer:find("\n\n", 1, true) then
				return
			end

			local params = M.parse_redirect(buffer) or {}
			if params.code or params.error then
				if params.error then
					respond(client, "Authorization failed", "Google reported: " .. tostring(params.error))
				else
					-- Deliberately not "connected": the code still has to be
					-- exchanged for a token, and that can fail. Claiming
					-- success here sends people away believing it worked.
					respond(
						client,
						"Authorization received",
						"Go back to Neovim — it is exchanging this for a token now and will tell you whether it worked."
					)
				end
				client:shutdown(function()
					pcall(function()
						client:close()
					end)
				end)
				finish(params, nil)
			else
				-- Browsers ask for /favicon.ico; answer and keep waiting.
				respond(client, "Waiting", "Still waiting for the authorization redirect.")
				client:shutdown(function()
					pcall(function()
						client:close()
					end)
				end)
			end
		end)
	end)

	vim.defer_fn(function()
		finish(nil, "timed out waiting for the browser to come back")
	end, timeout_ms or 120000)

	return port, nil
end

--------------------------------------------------------------------------
-- Talking to the token endpoint
--------------------------------------------------------------------------

-- Awaitable; must be called inside async.run.
local function post_form(url, params)
	local err, res = async.await(function(cb)
		http.request({
			url = url,
			method = "POST",
			body = M.query(params),
			headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
			retries = 1,
		}, function(request_err, response)
			cb(request_err, response)
		end)
	end)

	if err then
		return nil, err
	end
	local ok, decoded = pcall(vim.json.decode, res.body or "")
	if not ok or type(decoded) ~= "table" then
		return nil, ("%s returned an unreadable response (HTTP %d)"):format(url, res.status)
	end
	if res.status >= 400 or decoded.error then
		local detail = decoded.error_description or decoded.error or ("HTTP " .. res.status)
		return nil, http.redact(tostring(detail))
	end
	return decoded, nil
end

local function credentials(account)
	local client_id = account.client_id
	if not client_id or client_id == "" then
		return nil, nil, account.id .. ": no client_id configured"
	end
	-- Optional: a "Desktop app" client secret is not confidential (RFC 8252),
	-- and PKCE is what actually protects the exchange. Sent when configured
	-- because Google's token endpoint expects it for most client types.
	local secret = nil
	if account.client_secret or account.client_secret_cmd then
		local value, err = account_config.secret(account, "client_secret")
		if not value then
			return nil, nil, err
		end
		secret = value
	end
	return client_id, secret, nil
end

local function store_response(account_id, response, previous)
	local record = {
		access_token = response.access_token,
		-- Google only returns a refresh token on the first consent, so an
		-- existing one must survive a refresh that does not repeat it.
		refresh_token = response.refresh_token or (previous and previous.refresh_token),
		token_type = response.token_type,
		scope = response.scope,
		expires_at = response.expires_in and (os.time() + tonumber(response.expires_in)) or nil,
	}
	M.store_tokens(account_id, record)
	return record
end

--------------------------------------------------------------------------
-- Public flows
--------------------------------------------------------------------------

function M.scopes(account)
	local endpoints = M.endpoints(account)
	return account.scopes or (endpoints and endpoints.scopes) or {}
end

-- Interactive. Opens the browser, waits for the redirect, exchanges the code.
function M.authorize(account, done)
	done = done or function() end

	local endpoints = M.endpoints(account)
	if not endpoints then
		return done(("%s: %s accounts do not use OAuth"):format(account.id, tostring(account.provider)))
	end

	local client_id, client_secret, cred_err = credentials(account)
	if cred_err then
		return done(cred_err)
	end

	local verifier = M.new_verifier()
	local state = M.base64url(M.random_bytes(16))

	-- Assigned once the listener reports its port, below. The callback cannot
	-- run before the browser redirects, which is long after that.
	local redirect_uri

	local port, listen_err = M.listen(120000, function(params, err)
		if err then
			return done(err)
		end
		if params.error then
			return done("authorization was refused: " .. tostring(params.error))
		end
		-- Constant work either way; a mismatch means the response did not come
		-- from the request we made.
		if params.state ~= state then
			return done("state mismatch - ignoring a redirect bloocky did not initiate")
		end

		async.run(function()
			local response, exchange_err = post_form(endpoints.token, {
				code = params.code,
				client_id = client_id,
				client_secret = client_secret,
				code_verifier = verifier,
				grant_type = "authorization_code",
				redirect_uri = redirect_uri,
			})
			if not response then
				return done(exchange_err)
			end
			local record = store_response(account.id, response, nil)
			if not record.refresh_token then
				vim.notify(
					"Bloocky: no refresh token was issued, so you will have to re-authorise when this one expires",
					vim.log.levels.WARN
				)
			end
			done(nil)
		end, function(run_err)
			if run_err then
				done(tostring(run_err))
			end
		end)
	end)

	if not port then
		return done(listen_err)
	end

	redirect_uri = ("http://127.0.0.1:%d/"):format(port)

	local url = endpoints.authorize .. "?" .. M.query({
		client_id = client_id,
		redirect_uri = redirect_uri,
		response_type = "code",
		scope = table.concat(M.scopes(account), " "),
		code_challenge = M.challenge_for(verifier),
		code_challenge_method = "S256",
		state = state,
		-- Without these Google issues no refresh token, and the connection
		-- would silently die in an hour.
		access_type = "offline",
		prompt = "consent",
	})

	-- The URL carries no secret: the client id is public, the challenge is a
	-- one-way hash, and `state` is single use. Showing it is what makes the
	-- flow recoverable when the browser does not open, or opens in the wrong
	-- profile, or the machine has no browser at all.
	local ok, handle = pcall(vim.ui.open, url)
	if ok and handle then
		vim.notify(
			("Bloocky: waiting for authorisation of %s in your browser (listening on 127.0.0.1:%d, 120s)")
				:format(account.id, port),
			vim.log.levels.INFO
		)
	else
		vim.notify(
			("Bloocky: could not open a browser. Visit this URL to authorise %s (120s):\n%s"):format(account.id, url),
			vim.log.levels.WARN
		)
	end
	return url
end

-- Awaitable; must be called inside async.run.
function M.refresh(account)
	local previous = M.tokens_for(account.id)
	if not previous or not previous.refresh_token then
		return nil, ("%s: no refresh token - run :BloockySyncAuth %s"):format(account.id, account.id)
	end
	local endpoints = M.endpoints(account)
	local client_id, client_secret, cred_err = credentials(account)
	if cred_err then
		return nil, cred_err
	end

	local response, err = post_form(endpoints.token, {
		refresh_token = previous.refresh_token,
		client_id = client_id,
		client_secret = client_secret,
		grant_type = "refresh_token",
	})
	if not response then
		return nil, err
	end
	return store_response(account.id, response, previous).access_token, nil
end

-- Awaitable; must be called inside async.run. Refreshes when the token is
-- within a minute of expiring, so a long sync cannot have it die mid-flight.
function M.access_token(account)
	local record = M.tokens_for(account.id)
	if not record or not record.access_token then
		return nil, ("%s is not authorised - run :BloockySyncAuth %s"):format(account.id, account.id)
	end
	if not record.expires_at or record.expires_at - os.time() > 60 then
		return record.access_token, nil
	end
	return M.refresh(account)
end

function M.revoke(account, done)
	done = done or function() end
	local record = M.tokens_for(account.id)
	if not record then
		M.forget(account.id)
		return done(nil)
	end
	local endpoints = M.endpoints(account)

	async.run(function()
		local token = record.refresh_token or record.access_token
		local _, err = post_form(endpoints.revoke, { token = token })
		-- Drop it locally regardless: if the upstream call failed we still do
		-- not want to keep a credential we have stopped trusting.
		M.forget(account.id)
		done(err)
	end, function(run_err)
		if run_err then
			M.forget(account.id)
			done(tostring(run_err))
		end
	end)
end

return M
