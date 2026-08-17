-- The companion-app bus: block merge fixtures (the shared corpus the app's
-- port also runs), the exchange with its one-road rule, and the routes.

local canonical = require("bloocky.server.canonical")
local config = require("bloocky.config")
local devices = require("bloocky.server.devices")
local exchange = require("bloocky.server.exchange")
local merge = require("bloocky.server.merge")
local server = require("bloocky.server")
local state = require("bloocky.state")
local store = require("bloocky.server.store")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")

local DEVICE = { id = "phone1", name = "test-phone" }

local function block(id, fields)
	return vim.tbl_extend("force", {
		id = id,
		title = "T",
		date = "2026-08-17",
		start_min = 540,
		duration_min = 30,
		notes = "",
		created_at = 1,
		updated_at = 1,
	}, fields or {})
end

local function fresh(blocks)
	store.reset_for_tests()
	store._path_override = dir .. "/appsync_" .. math.random(1e9) .. ".json"
	devices.reset_for_tests()
	devices._path_override = dir .. "/devices_" .. math.random(1e9) .. ".json"
	local save_path = dir .. "/blocks_" .. math.random(1e9) .. ".json"
	local file = io.open(save_path, "w")
	file:write(vim.json.encode(blocks or {}))
	file:close()
	config.setup({ save_path = save_path })
	state.load_blocks()
end

--------------------------------------------------------------------------
-- The shared corpus
--------------------------------------------------------------------------

local corpus_file = io.open(root .. "/spec/fixtures/appsync/cases.json", "r")
local cases = vim.json.decode(corpus_file:read("*a"))
corpus_file:close()

local function by_id(a, b)
	return a.id < b.id
end

local function sorted(list)
	local copy = vim.deepcopy(list or {})
	table.sort(copy, by_id)
	return copy
end

local function normalize_conflicts(list)
	local out = {}
	for _, c in ipairs(list or {}) do
		table.insert(out, { id = c.id, kind = c.kind, group = c.group, winner = c.winner })
	end
	table.sort(out, function(a, b)
		return a.id .. (a.group or "") .. a.kind < b.id .. (b.group or "") .. b.kind
	end)
	return out
end

describe("app block merge fixtures", function()
	for _, case in ipairs(cases) do
		it(case.name, function()
			local input = case.input
			local side_l, side_r = input["local"], input.remote
			local result = merge.merge({
				base = input.base,
				local_blocks = side_l.blocks,
				remote_blocks = side_r.blocks,
				local_tombstones = side_l.tombstones,
				remote_tombstones = side_r.tombstones,
				local_device = side_l.device,
				remote_device = side_r.device,
			})
			eq(canonical.encode(sorted(result.blocks)), canonical.encode(sorted(case.expected.blocks)), "blocks")
			eq(
				canonical.encode(sorted(result.tombstones)),
				canonical.encode(sorted(case.expected.tombstones)),
				"tombstones"
			)
			eq(
				canonical.encode(normalize_conflicts(result.conflicts)),
				canonical.encode(normalize_conflicts(case.expected.conflicts)),
				"conflicts"
			)
		end)
	end
end)

--------------------------------------------------------------------------
-- The exchange and the one-road rule
--------------------------------------------------------------------------

describe("blocks exchange", function()
	it("unions both sides' local blocks", function()
		fresh({ block("s1", { title = "from nvim" }) })
		local response = exchange.blocks_exchange(DEVICE, {
			blocks = { block("p1", { title = "from phone", source = "local" }) },
			tombstones = {},
		})
		eq(response.revision, 1)
		eq(#response.blocks, 2)
		eq(#state.blocks, 2)
	end)

	it("never touches calendar-backed blocks, and never sends them", function()
		fresh({
			block("cal1", { title = "meeting", source = "work" }),
			block("loc1", { title = "gym" }),
		})
		local response = exchange.blocks_exchange(DEVICE, { blocks = {}, tombstones = {} })
		eq(#response.blocks, 1, "only the local block travels")
		eq(response.blocks[1].id, "loc1")
		-- The calendar-backed block is still in the file, untouched.
		eq(#state.blocks, 2)
		local found = false
		for _, b in ipairs(state.blocks) do
			if b.id == "cal1" then
				found = true
				eq(b.source, "work")
			end
		end
		truthy(found)
	end)

	it("rejects a device trying to push a calendar-backed block", function()
		fresh({})
		local response, status = exchange.blocks_exchange(DEVICE, {
			blocks = { block("x", { source = "work" }) },
			tombstones = {},
		})
		eq(response, nil)
		eq(status, 400)
	end)

	it("propagates a device deletion of a local block", function()
		fresh({ block("loc1") })
		exchange.blocks_exchange(DEVICE, { blocks = {}, tombstones = {} }) -- base
		local response = exchange.blocks_exchange(DEVICE, {
			blocks = {},
			tombstones = { { id = "loc1", deleted_at = 999 } },
		})
		eq(#response.blocks, 0)
		eq(#state.blocks, 0)
	end)

	it("keeps the whole losing block in the trail, not just which group lost", function()
		fresh({ block("loc1", { title = "agreed" }) })
		exchange.blocks_exchange(DEVICE, { blocks = {}, tombstones = {} }) -- agree on a base

		-- Both sides then edit the title away from that base, with the same
		-- updated_at: a genuine clash, broken by device id, so nvim's loses.
		state.blocks[1].title = "nvim"
		state.blocks[1].updated_at = 500
		state.save_blocks()
		exchange.blocks_exchange(DEVICE, {
			blocks = { block("loc1", { title = "phone", updated_at = 500 }) },
			tombstones = {},
		})
		-- Reporting that something was overwritten without keeping it is the
		-- one thing the trail exists to prevent.
		local trail = store.conflicts()
		eq(#trail, 1)
		eq(trail[1].group, "title")
		truthy(trail[1].loser_block, "the losing block itself is kept")
		eq(trail[1].loser_block.id, "loc1")
	end)

	it("prunes bases for unpaired devices, but never the one it is serving", function()
		fresh({ block("loc1") })
		exchange.blocks_exchange({ id = "ghost", name = "revoked" }, { blocks = {}, tombstones = {} })
		exchange.blocks_exchange(DEVICE, { blocks = {}, tombstones = {} })
		-- A base is a full copy of the blocks; a revoked device must not keep one.
		local ids = {}
		for id in pairs(store.load().devices) do
			table.insert(ids, id)
		end
		eq(#ids, 1)
		eq(ids[1], DEVICE.id)
	end)

	it("converges over two rounds", function()
		fresh({ block("s1") })
		local first = exchange.blocks_exchange(DEVICE, { blocks = {}, tombstones = {} })
		local second = exchange.blocks_exchange(DEVICE, { blocks = first.blocks, tombstones = {} })
		eq(#second.conflicts, 0)
		eq(canonical.encode(sorted(second.blocks)), canonical.encode(sorted(first.blocks)))
	end)
end)

--------------------------------------------------------------------------
-- Routes
--------------------------------------------------------------------------

local function request(method, path, headers, body)
	headers = headers or {}
	headers.host = headers.host or "192.168.1.2:7284"
	return { method = method, path = path, query = "", headers = headers, body = body or "" }
end

local function status_of(response)
	return tonumber(response:match("^HTTP/1%.1 (%d+)"))
end

describe("app server routes", function()
	it("identifies itself as bloocky on /version", function()
		fresh({})
		local response = server._handle_request_for_tests(request("GET", "/version"))
		eq(status_of(response), 200)
		truthy(response:find('"product":"bloocky"', 1, true))
	end)

	it("requires auth for /blocks — no v1 mode on this port, ever", function()
		fresh({ block("s1") })
		eq(status_of(server._handle_request_for_tests(request("GET", "/blocks"))), 401)
		local paired = devices.pair(devices.new_pairing_token(), "phone")
		local ok_response = server._handle_request_for_tests(
			request("GET", "/blocks", { authorization = "Bearer " .. paired.device_token })
		)
		eq(status_of(ok_response), 200)
	end)

	it("requires auth for the exchange", function()
		fresh({})
		eq(status_of(server._handle_request_for_tests(request("POST", "/v2/sync/blocks", nil, '{"blocks":[]}'))), 401)
	end)

	it("rejects Origin and DNS Hosts like every other route", function()
		fresh({})
		eq(
			status_of(server._handle_request_for_tests(request("GET", "/version", { origin = "http://evil.dev" }))),
			403
		)
		eq(
			status_of(server._handle_request_for_tests(request("GET", "/version", { host = "evil.dev:7284" }))),
			403
		)
	end)

	it("runs a full exchange over the route", function()
		fresh({ block("s1") })
		local paired = devices.pair(devices.new_pairing_token(), "phone")
		local response = server._handle_request_for_tests(request("POST", "/v2/sync/blocks", {
			authorization = "Bearer " .. paired.device_token,
		}, vim.json.encode({ blocks = {}, tombstones = {} })))
		eq(status_of(response), 200)
		local body = vim.json.decode(response:match("\r\n\r\n(.*)$"))
		eq(#body.blocks, 1)
		eq(body.revision, 1)
	end)
end)
