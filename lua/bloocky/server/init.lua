-- Bloocky's own LAN bus — the companion app's way to time blocks, so a
-- bloocky-only user has a mobile path without installing anything else.
--
-- Adapted from dooing's server.lua under the copy-not-require rule (see
-- server/httpd.lua). Two deliberate differences from dooing's:
--   * port 7284 — each product owns its bus, pairing is independent;
--   * NO v1 compatibility mode: this port never had unauthenticated
--     clients, so it is born with every data route behind a device token.
--
-- Routes: GET / (QR pairing page), GET /version, POST /v2/pair,
-- GET /blocks (all blocks, read view), POST /v2/sync/blocks (local-only
-- exchange — see server/exchange.lua for the one-road rule).

local M = {}

local config = require("bloocky.config")
local devices = require("bloocky.server.devices")
local httpd = require("bloocky.server.httpd")
local uv = vim.uv or vim.loop
local api = vim.api

local PROTOCOL_VERSION = 2
local MAX_CONNECTIONS = 16
local IDLE_TIMEOUT_MS = 10000

local server_handle = nil
local open_connections = 0

local function server_options()
	return config.options.server or {}
end

local function get_local_ip()
	local socket = uv.new_udp()
	socket:connect("8.8.8.8", 80)
	local sockname = socket:getsockname()
	socket:close()
	if not sockname or not sockname.ip then
		vim.notify("Could not determine local IP address", vim.log.levels.ERROR)
		return "127.0.0.1"
	end
	return sockname.ip
end

--------------------------------------------------------------------------
-- Routes
--------------------------------------------------------------------------

local function qr_page(local_ip, port)
	local token = devices.new_pairing_token()
	local payload = vim.json.encode({
		v = PROTOCOL_VERSION,
		p = "bloocky",
		host = ("http://%s:%d"):format(local_ip, port),
		t = token,
	})
	return string.format(
		[[
<!DOCTYPE html>
<html>
<head>
	<meta charset="utf-8">
	<title>Bloocky QR Code</title>
	<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
	<style>
		body { background: #1a1b26; color: #fff; font-family: sans-serif; display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100vh; margin: 0; }
		#qrcode { background: white; padding: 20px; border-radius: 8px; }
		.ip-info { margin-top: 20px; font-size: 14px; color: #888; }
	</style>
</head>
<body>
	<div id="qrcode"></div>
	<div class="ip-info">Bloocky &middot; %s:%d &middot; scan within 10 minutes</div>
	<script>
		new QRCode(document.getElementById("qrcode"), {
			text: %s,
			width: 256,
			height: 256
		});
	</script>
</body>
</html>
]],
		local_ip,
		port,
		vim.json.encode(payload)
	)
end

local function encode_list(list)
	if #list == 0 then
		return "[]"
	end
	return vim.json.encode(list)
end

local function handle_pair(request)
	local ok, body = pcall(vim.json.decode, request.body)
	if not ok or type(body) ~= "table" then
		return httpd.error_response(400, "expected a JSON body")
	end
	local result, err = devices.pair(body.token, body.device_name)
	if not result then
		return httpd.error_response(401, err or "pairing failed")
	end
	vim.schedule(function()
		vim.notify(("Bloocky: paired device %q"):format(result.name), vim.log.levels.INFO)
	end)
	return httpd.json_response(200, result)
end

local function handle_sync_blocks(request)
	local device = devices.authorize(request.headers["authorization"])
	if not device then
		return httpd.error_response(401, "pair this device first (scan the QR)")
	end
	local ok, body = pcall(vim.json.decode, request.body)
	if not ok or type(body) ~= "table" then
		return httpd.error_response(400, "expected a JSON body")
	end
	local exchange = require("bloocky.server.exchange")
	local response, status, message = exchange.blocks_exchange(device, body)
	if not response then
		return httpd.error_response(status or 500, message or "exchange failed")
	end
	local json = ('{"revision":%d,"blocks":%s,"tombstones":%s,"conflicts":%s}'):format(
		response.revision,
		encode_list(response.blocks),
		encode_list(response.tombstones),
		encode_list(response.conflicts)
	)
	return httpd.response(200, "application/json", json)
end

local function handle_request(request, port)
	if not httpd.check_origin(request.headers["origin"]) then
		return httpd.error_response(403, "cross-origin requests are not allowed")
	end
	if not httpd.check_host(request.headers["host"], port) then
		return httpd.error_response(403, "bad Host header")
	end

	local method, path = request.method, request.path

	if method == "GET" and (path == "/" or path == "") then
		return httpd.response(200, "text/html", qr_page(get_local_ip(), port))
	end

	if method == "GET" and path == "/version" then
		return httpd.json_response(200, { protocol = PROTOCOL_VERSION, product = "bloocky" })
	end

	if method == "POST" and path == "/v2/pair" then
		return handle_pair(request)
	end

	if method == "POST" and path == "/v2/sync/blocks" then
		return handle_sync_blocks(request)
	end

	if method == "GET" and path == "/blocks" then
		if not devices.authorize(request.headers["authorization"]) then
			return httpd.error_response(401, "pair this device first (scan the QR)")
		end
		local state = require("bloocky.state")
		state.ensure_loaded()
		return httpd.response(200, "application/json", encode_list(state.blocks))
	end

	return httpd.error_response(404, "no such endpoint")
end

--------------------------------------------------------------------------
-- Connections (same shape as dooing's, copied)
--------------------------------------------------------------------------

local function close_client(client, timer)
	if timer and not timer:is_closing() then
		timer:stop()
		timer:close()
	end
	if not client:is_closing() then
		client:shutdown()
		client:close()
	end
	open_connections = math.max(0, open_connections - 1)
end

local function handle_connection(client, port)
	open_connections = open_connections + 1
	local parser = httpd.new_parser()

	local timer = uv.new_timer()
	timer:start(IDLE_TIMEOUT_MS, 0, function()
		close_client(client, timer)
	end)

	client:read_start(function(err, chunk)
		if err or not chunk then
			close_client(client, timer)
			return
		end
		local request, parse_err = parser:feed(chunk)
		if parse_err then
			client:write(httpd.error_response(400, parse_err))
			close_client(client, timer)
			return
		end
		if not request then
			return
		end
		vim.schedule(function()
			local ok, response = pcall(handle_request, request, port)
			if not ok then
				response = httpd.error_response(500, "internal error")
			end
			client:write(response)
			close_client(client, timer)
		end)
	end)
end

--------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------

function M.is_running()
	return server_handle ~= nil and not server_handle:is_closing()
end

function M.start()
	if M.is_running() then
		return true
	end
	local opts = server_options()
	local port = opts.port or 7284
	local server = uv.new_tcp()
	local ok, err = pcall(function()
		server:bind(opts.bind or "0.0.0.0", port)
	end)
	if not ok then
		vim.notify("Bloocky: failed to bind server: " .. tostring(err), vim.log.levels.ERROR)
		return false
	end
	server:listen(128, function()
		local client = uv.new_tcp()
		server:accept(client)
		if open_connections >= MAX_CONNECTIONS then
			client:close()
			return
		end
		handle_connection(client, port)
	end)
	server_handle = server
	return true
end

function M.stop()
	if M.is_running() then
		server_handle:close()
	end
	server_handle = nil
end

-- The pairing window: QR in the browser, same flow as dooing's share.
function M.share()
	local opts = server_options()
	local port = opts.port or 7284
	local local_ip = get_local_ip()
	if not M.start() then
		return
	end
	local url = ("http://%s:%d"):format(local_ip, port)
	vim.notify("Bloocky: pairing page at " .. url, vim.log.levels.INFO)
	vim.defer_fn(function()
		if vim.fn.has("mac") == 1 then
			os.execute("open " .. url)
		elseif vim.fn.has("unix") == 1 then
			os.execute("xdg-open " .. url)
		elseif vim.fn.has("win32") == 1 then
			os.execute("start " .. url)
		end
	end, 100)
end

-- Spec hook: drive the router without sockets.
function M._handle_request_for_tests(request, port)
	return handle_request(request, port or 7284)
end

return M
