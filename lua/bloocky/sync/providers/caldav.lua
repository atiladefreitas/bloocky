-- CalDAV: RFC 4791, plus RFC 6578 for incremental sync.
--
-- Everything that builds a request body or reads a response is a pure
-- function, so the protocol can be tested without a server. Only the handful
-- of `request`-shaped functions touch the network.

local account_config = require("bloocky.sync.account")
local async = require("bloocky.sync.async")
local http = require("bloocky.sync.http")
local xml = require("bloocky.sync.xml")

local M = {}

local NS = 'xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/"'

--------------------------------------------------------------------------
-- Request bodies
--------------------------------------------------------------------------

function M.propfind_body(props)
	local lines = { '<?xml version="1.0" encoding="utf-8"?>', "<d:propfind " .. NS .. "><d:prop>" }
	for _, prop in ipairs(props) do
		table.insert(lines, "<" .. prop .. "/>")
	end
	table.insert(lines, "</d:prop></d:propfind>")
	return table.concat(lines)
end

local function escape_xml(text)
	return (tostring(text):gsub("[&<>\"]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }))
end

-- The token is the server's own opaque string coming back around; escaped all
-- the same, so nothing it contains can restructure the request.
function M.sync_collection_body(token)
	return table.concat({
		'<?xml version="1.0" encoding="utf-8"?>',
		"<d:sync-collection " .. NS .. ">",
		"<d:sync-token>" .. escape_xml(token or "") .. "</d:sync-token>",
		"<d:sync-level>1</d:sync-level>",
		"<d:prop><d:getetag/></d:prop>",
		"</d:sync-collection>",
	})
end

function M.multiget_body(hrefs)
	local lines = {
		'<?xml version="1.0" encoding="utf-8"?>',
		"<c:calendar-multiget " .. NS .. ">",
		"<d:prop><d:getetag/><c:calendar-data/></d:prop>",
	}
	for _, href in ipairs(hrefs) do
		table.insert(lines, "<d:href>" .. escape_xml(href) .. "</d:href>")
	end
	table.insert(lines, "</c:calendar-multiget>")
	return table.concat(lines)
end

-- A time-bounded query, used for the first sync so we do not drag down years
-- of history. `start_utc` and `end_utc` are "YYYYMMDDTHHMMSSZ".
function M.calendar_query_body(start_utc, end_utc)
	return table.concat({
		'<?xml version="1.0" encoding="utf-8"?>',
		"<c:calendar-query " .. NS .. ">",
		"<d:prop><d:getetag/><c:calendar-data/></d:prop>",
		'<c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT">',
		('<c:time-range start="%s" end="%s"/>'):format(start_utc, end_utc),
		"</c:comp-filter></c:comp-filter></c:filter>",
		"</c:calendar-query>",
	})
end

--------------------------------------------------------------------------
-- Response parsing
--------------------------------------------------------------------------

-- One entry per <response>: href, the WebDAV status if given, the ETag, and
-- the calendar payload when it was asked for.
function M.parse_multistatus(body)
	local root = xml.parse(body)
	local out = { responses = {}, sync_token = xml.find_text(root, "sync-token") }

	for _, response in ipairs(xml.find_all(root, "response")) do
		local href = xml.find_text(response, "href")
		if href then
			table.insert(out.responses, {
				href = href,
				status = xml.status_code(response),
				etag = xml.find_text(response, "getetag"),
				data = xml.find_text(response, "calendar-data"),
			})
		end
	end
	return out
end

-- Which of the collections under a calendar-home are usable event calendars.
-- Servers advertise address books and task lists in the same listing, so
-- filtering on resourcetype and component set is not optional.
function M.parse_calendars(body)
	local root = xml.parse(body)
	local out = {}

	for _, response in ipairs(xml.find_all(root, "response")) do
		local href = xml.find_text(response, "href")
		local resourcetype = xml.find(response, "resourcetype")
		local is_calendar = resourcetype and xml.find(resourcetype, "calendar") ~= nil

		if href and is_calendar then
			-- An explicit component set that omits VEVENT means a task or
			-- journal collection. Absent means "everything".
			local supports_events = true
			local comp_set = xml.find(response, "supported-calendar-component-set")
			if comp_set then
				supports_events = false
				for _, comp in ipairs(xml.find_all(comp_set, "comp")) do
					if (comp.attrs.name or ""):upper() == "VEVENT" then
						supports_events = true
					end
				end
			end

			-- Only trust a privilege set that is actually present; its absence
			-- is not evidence of read-only.
			local readonly = false
			local privileges = xml.find(response, "current-user-privilege-set")
			if privileges then
				readonly = xml.find(privileges, "write-content") == nil and xml.find(privileges, "write") == nil
			end

			if supports_events then
				table.insert(out, {
					href = href,
					name = xml.find_text(response, "displayname") or href,
					ctag = xml.find_text(response, "getctag"),
					readonly = readonly,
				})
			end
		end
	end
	return out
end

--------------------------------------------------------------------------
-- Transport
--------------------------------------------------------------------------

-- Resolve an href against the account's base URL. Servers reply with paths,
-- not absolute URLs.
--
-- An absolute href is honoured even when it names a different host: iCloud
-- legitimately hands out a calendar-home on a pXX-caldav.icloud.com partition
-- host, so a same-origin rule would break real servers. What makes that
-- acceptable is http.check_url, which every request passes through — a
-- delegated host gets credentials only ever over verified TLS.
function M.resolve(base, href)
	if href:match("^https?://") then
		return href
	end
	local scheme, authority = base:match("^(%a[%w%+%.%-]*)://([^/]+)")
	if not scheme then
		return href
	end
	if href:sub(1, 1) ~= "/" then
		href = "/" .. href
	end
	return scheme .. "://" .. authority .. href
end

-- The seam tests use in place of a live server.
M.transport = nil

-- Basic auth for a plain CalDAV server; a bearer token for one behind OAuth
-- (Google's CalDAV bridge). Either way the credential goes into http.lua's
-- 0600 config file, never onto the command line.
local function authorise(account, opts)
	if account.provider ~= "caldav" or account.bearer_auth then
		local oauth = require("bloocky.sync.oauth")
		local token, err = oauth.access_token(account)
		if not token then
			return err
		end
		opts.bearer = token
		return nil
	end

	local password, err = account_config.secret(account, "password")
	if not password then
		return err
	end
	opts.auth = { user = account.username, password = password }
	return nil
end

local function request(account, opts, callback)
	local err = authorise(account, opts)
	if err then
		return callback(err, nil)
	end
	opts.headers = opts.headers or {}
	opts.headers["User-Agent"] = "bloocky.nvim"
	return (M.transport or http.request)(opts, callback)
end

-- Awaitable wrapper: returns (err, res) inside an async.run coroutine.
local function call(account, opts)
	return async.await(function(cb)
		request(account, opts, function(err, res)
			cb(err, res)
		end)
	end)
end

local function dav(account, method, url, body, headers, depth)
	headers = headers or {}
	headers["Content-Type"] = body and 'application/xml; charset="utf-8"' or nil
	if depth then
		headers.Depth = depth
	end
	return call(account, { url = url, method = method, body = body, headers = headers, follow = true })
end

--------------------------------------------------------------------------
-- Discovery
--------------------------------------------------------------------------

-- url -> principal -> calendar-home-set -> the calendars themselves.
-- Each hop is skippable: a user who configured a calendar URL directly should
-- not pay for three extra round trips.
function M.discover(account)
	local base = account.url

	if account.calendar_home then
		return M.list_calendars(account, M.resolve(base, account.calendar_home))
	end

	local err, res = dav(account, "PROPFIND", base, M.propfind_body({ "d:current-user-principal" }), nil, "0")
	if err then
		return nil, err
	end
	if res.status == 401 then
		return nil, "authentication failed for " .. account.id .. " (check username and password_cmd)"
	end
	if res.status >= 400 then
		return nil, ("discovery failed at %s (HTTP %d)"):format(base, res.status)
	end

	local principal = xml.find_text(xml.find(xml.parse(res.body), "current-user-principal"), "href")
		or xml.find_text(xml.parse(res.body), "href")
	if not principal then
		return nil, "server did not return a current-user-principal"
	end

	local home_err, home_res =
		dav(account, "PROPFIND", M.resolve(base, principal), M.propfind_body({ "c:calendar-home-set" }), nil, "0")
	if home_err then
		return nil, home_err
	end

	local home = xml.find_text(xml.find(xml.parse(home_res.body), "calendar-home-set"), "href")
	if not home then
		return nil, "server did not return a calendar-home-set"
	end

	return M.list_calendars(account, M.resolve(base, home))
end

function M.list_calendars(account, home_url)
	local err, res = dav(
		account,
		"PROPFIND",
		home_url,
		M.propfind_body({
			"d:resourcetype",
			"d:displayname",
			"cs:getctag",
			"c:supported-calendar-component-set",
			"d:current-user-privilege-set",
		}),
		nil,
		"1"
	)
	if err then
		return nil, err
	end
	if res.status >= 400 then
		return nil, ("could not list calendars (HTTP %d)"):format(res.status)
	end
	return M.parse_calendars(res.body), nil
end

--------------------------------------------------------------------------
-- Reading events
--------------------------------------------------------------------------

-- The first sync for a calendar: everything in the window, plus a sync-token
-- to make the next one incremental.
function M.initial_fetch(account, calendar_url, window)
	local err, res = dav(
		account,
		"REPORT",
		calendar_url,
		M.calendar_query_body(window.start, window["end"]),
		nil,
		"1"
	)
	if err then
		return nil, err
	end
	if res.status >= 400 then
		return nil, ("calendar-query failed (HTTP %d)"):format(res.status)
	end

	local parsed = M.parse_multistatus(res.body)
	local token = M.fetch_sync_token(account, calendar_url)
	return { changed = parsed.responses, removed = {}, token = token }, nil
end

-- A sync-token with no changes attached, so the *next* sync can be
-- incremental even though this one was a full fetch.
function M.fetch_sync_token(account, calendar_url)
	local err, res = dav(account, "PROPFIND", calendar_url, M.propfind_body({ "d:sync-token" }), nil, "0")
	if err or not res or res.status >= 400 then
		return nil
	end
	return xml.find_text(xml.parse(res.body), "sync-token")
end

-- RFC 6578 incremental sync. Returns changed hrefs (with data fetched via
-- multiget) and removed hrefs.
function M.incremental_fetch(account, calendar_url, token)
	local err, res = dav(account, "REPORT", calendar_url, M.sync_collection_body(token), nil, "1")
	if err then
		return nil, err
	end
	-- 400/403/409 here generally means the token expired or the server never
	-- really supported sync-collection. Either way, fall back to a full fetch.
	if res.status == 400 or res.status == 403 or res.status == 409 or res.status >= 500 then
		return nil, "resync"
	end
	if res.status >= 400 then
		return nil, ("sync-collection failed (HTTP %d)"):format(res.status)
	end

	local parsed = M.parse_multistatus(res.body)
	local changed_hrefs, removed = {}, {}
	for _, response in ipairs(parsed.responses) do
		if response.status == 404 or response.status == 410 then
			table.insert(removed, response.href)
		else
			table.insert(changed_hrefs, response.href)
		end
	end

	local changed = {}
	if #changed_hrefs > 0 then
		local data, fetch_err = M.multiget(account, calendar_url, changed_hrefs)
		if fetch_err then
			return nil, fetch_err
		end
		changed = data
	end

	return { changed = changed, removed = removed, token = parsed.sync_token or token }, nil
end

function M.multiget(account, calendar_url, hrefs)
	local out = {}
	-- Chunked: a multiget naming several thousand hrefs is a request body some
	-- servers simply refuse.
	local CHUNK = 75
	for start = 1, #hrefs, CHUNK do
		local slice = vim.list_slice(hrefs, start, math.min(start + CHUNK - 1, #hrefs))
		local err, res = dav(account, "REPORT", calendar_url, M.multiget_body(slice), nil, "1")
		if err then
			return nil, err
		end
		if res.status >= 400 then
			return nil, ("calendar-multiget failed (HTTP %d)"):format(res.status)
		end
		for _, response in ipairs(M.parse_multistatus(res.body).responses) do
			if response.data then
				table.insert(out, response)
			end
		end
	end
	return out, nil
end

--------------------------------------------------------------------------
-- Writing events
--------------------------------------------------------------------------

-- Create or replace a calendar object.
--
-- `etag` is the version we believe is on the server. Sending it as If-Match
-- is what turns a blind overwrite into a detectable conflict: a 412 means
-- somebody changed the event since we last looked.
function M.put(account, url, body, etag)
	local headers = { ["Content-Type"] = "text/calendar; charset=utf-8" }
	if etag then
		headers["If-Match"] = etag
	else
		headers["If-None-Match"] = "*" -- create only; never clobber a stranger
	end

	local err, res = call(account, { url = url, method = "PUT", body = body, headers = headers })
	if err then
		return nil, err
	end
	if res.status == 412 then
		return { conflict = true, status = res.status }, nil
	end
	if res.status >= 400 then
		return nil, ("PUT failed (HTTP %d)"):format(res.status)
	end
	-- Servers may omit the new ETag, in which case the caller re-reads it.
	return { etag = res.headers.etag, status = res.status }, nil
end

function M.delete(account, url, etag)
	local headers = {}
	if etag then
		headers["If-Match"] = etag
	end
	local err, res = call(account, { url = url, method = "DELETE", headers = headers })
	if err then
		return nil, err
	end
	if res.status == 412 then
		return { conflict = true, status = res.status }, nil
	end
	-- Already gone is a success: the desired state is "not there".
	if res.status == 404 or res.status == 410 then
		return { status = res.status, missing = true }, nil
	end
	if res.status >= 400 then
		return nil, ("DELETE failed (HTTP %d)"):format(res.status)
	end
	return { status = res.status }, nil
end

--------------------------------------------------------------------------
-- The interface the orchestrator actually uses
--------------------------------------------------------------------------
--
-- Everything above is CalDAV plumbing. These four wrap it in terms the sync
-- engine can express for any provider: a block goes up, a change comes down.
-- Building the payload belongs to the provider, because only it knows whether
-- that means iCalendar text or JSON.

function M.create_event(account, calendar, block)
	local mapper = require("bloocky.sync.mapper")
	local body, build_err = mapper.to_ical(block)
	if not body then
		return nil, build_err
	end

	local href = calendar.href:gsub("/$", "") .. "/" .. mapper.href_for(block)
	local url = M.resolve(account.url, href)
	local result, err = M.put(account, url, body, nil)
	if not result then
		return nil, err
	end
	if result.conflict then
		return { conflict = true }, nil
	end

	local etag = result.etag
	if not etag then
		-- Some servers omit the ETag on PUT; read it back so the next update
		-- can send If-Match and get conflict detection.
		local fetched = M.get(account, url)
		etag = fetched and fetched.etag
	end
	return { href = href, uid = mapper.uid_for(block), etag = etag, raw = body }, nil
end

function M.update_event(account, mapping, block)
	local ical = require("bloocky.sync.ical")
	local mapper = require("bloocky.sync.mapper")
	if not mapping.raw then
		return nil, "no cached payload; it will re-sync on the next run"
	end

	-- Patch the server's own bytes rather than rebuilding: see the note at the
	-- top of ical.lua.
	local body = ical.patch(mapping.raw, mapper.patch_changes(block, {
		lossy = mapping.lossy,
		all_day = mapping.all_day,
		tzid = mapping.tz,
	}))
	local result, err = M.put(account, M.resolve(account.url, mapping.href), body, mapping.etag)
	if not result then
		return nil, err
	end
	if result.conflict then
		return { conflict = true }, nil
	end
	return { etag = result.etag, raw = body }, nil
end

function M.delete_event(account, tombstone)
	return M.delete(account, M.resolve(account.url, tombstone.href or ""), tombstone.etag)
end

-- Incremental when we have a cursor, falling back to a full fetch when the
-- server says the token is no longer usable.
function M.fetch(account, calendar, cursor, window)
	local url = M.resolve(account.url, calendar.href)
	local result, err
	if cursor then
		result, err = M.incremental_fetch(account, url, cursor)
		if err == "resync" then
			result, err = nil, nil
		end
	end
	if not result and not err then
		result, err = M.initial_fetch(account, url, window)
	end
	-- `cursor` is the name the orchestrator persists; CalDAV happens to call
	-- its own a sync-token.
	if result then
		result.cursor = result.token
	end
	return result, err
end

-- Read one object back, for when a PUT did not return an ETag.
function M.get(account, url)
	local err, res = call(account, { url = url, method = "GET" })
	if err then
		return nil, err
	end
	if res.status >= 400 then
		return nil, ("GET failed (HTTP %d)"):format(res.status)
	end
	return { etag = res.headers.etag, data = res.body }, nil
end

return M
