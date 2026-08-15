-- Which module speaks to which kind of server.
--
-- Every provider implements the same small contract, the one `caldav.lua`
-- already defines:
--
--   resolve(base, href)                        -> absolute URL
--   discover(account)                          -> calendars, err
--   initial_fetch(account, url, window)        -> { changed, removed, token }, err
--   incremental_fetch(account, url, cursor)    -> { changed, removed, token }, err
--   put(account, url, body, etag)              -> { etag, conflict? }, err
--   delete(account, url, etag)                 -> { conflict?, missing? }, err
--   get(account, url)                          -> { etag, data }, err
--
-- The fetch functions return entries shaped like a CalDAV response
-- (`href`, `etag`, `data` holding an iCalendar object), because that is what
-- the orchestrator and `mapper.lua` consume. A provider whose wire format is
-- something else is responsible for translating into that shape.

local M = {}

local MODULES = {
	caldav = "bloocky.sync.providers.caldav",
	google = "bloocky.sync.providers.google",
}

function M.for_account(account)
	local provider = account and account.provider
	local module_name = MODULES[provider]
	if not module_name then
		error(("unknown sync provider %q"):format(tostring(provider)), 0)
	end
	local ok, module = pcall(require, module_name)
	if not ok then
		error(("could not load the %s provider: %s"):format(provider, module), 0)
	end
	return module
end

function M.names()
	return vim.tbl_keys(MODULES)
end

return M
