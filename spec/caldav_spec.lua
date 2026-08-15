local caldav = require("bloocky.sync.providers.caldav")

describe("sync.providers.caldav", function()
	describe("request bodies", function()
		it("builds a propfind", function()
			local body = caldav.propfind_body({ "d:resourcetype", "d:displayname" })
			truthy(body:find("<d:propfind", 1, true))
			truthy(body:find("<d:resourcetype/>", 1, true))
			truthy(body:find("<d:displayname/>", 1, true))
		end)

		it("builds a sync-collection with and without a token", function()
			truthy(caldav.sync_collection_body("tok-1"):find("<d:sync-token>tok-1</d:sync-token>", 1, true))
			truthy(caldav.sync_collection_body(nil):find("<d:sync-token></d:sync-token>", 1, true))
		end)

		-- The token is opaque server data coming back around; markup inside it
		-- must not restructure our own request.
		it("escapes the sync token", function()
			local body = caldav.sync_collection_body('x</d:sync-token><evil attr="1"/>')
			falsy(body:find("<evil", 1, true))
			truthy(body:find("&lt;evil", 1, true))
		end)

		it("builds a multiget listing every href", function()
			local body = caldav.multiget_body({ "/cal/a.ics", "/cal/b.ics" })
			truthy(body:find("<d:href>/cal/a.ics</d:href>", 1, true))
			truthy(body:find("<d:href>/cal/b.ics</d:href>", 1, true))
			truthy(body:find("calendar-data", 1, true))
		end)

		-- An href with an ampersand would otherwise produce malformed XML.
		it("escapes hrefs", function()
			truthy(caldav.multiget_body({ "/cal/a&b.ics" }):find("a&amp;b", 1, true))
		end)

		it("builds a time-bounded query", function()
			local body = caldav.calendar_query_body("20260101T000000Z", "20261231T000000Z")
			truthy(body:find('start="20260101T000000Z"', 1, true))
			truthy(body:find('name="VEVENT"', 1, true))
		end)
	end)

	describe("resolve", function()
		it("turns a path into an absolute URL", function()
			eq(
				caldav.resolve("https://dav.example.com/dav/", "/dav/calendars/me/work/"),
				"https://dav.example.com/dav/calendars/me/work/"
			)
		end)

		it("leaves an absolute URL alone", function()
			eq(caldav.resolve("https://a.example.com/", "https://b.example.com/x"), "https://b.example.com/x")
		end)

		it("copes with a relative href", function()
			eq(caldav.resolve("https://dav.example.com/dav/", "cal/a.ics"), "https://dav.example.com/cal/a.ics")
		end)

		it("keeps the port", function()
			eq(caldav.resolve("https://dav.example.com:8443/dav/", "/x"), "https://dav.example.com:8443/x")
		end)
	end)

	describe("parse_multistatus", function()
		local BODY = [[<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:response>
    <d:href>/cal/a.ics</d:href>
    <d:propstat>
      <d:prop><d:getetag>"v1"</d:getetag><c:calendar-data>BEGIN:VCALENDAR</c:calendar-data></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/cal/gone.ics</d:href>
    <d:status>HTTP/1.1 404 Not Found</d:status>
  </d:response>
  <d:sync-token>tok-2</d:sync-token>
</d:multistatus>]]

		it("reads hrefs, etags and payloads", function()
			local parsed = caldav.parse_multistatus(BODY)
			eq(#parsed.responses, 2)
			eq(parsed.responses[1].href, "/cal/a.ics")
			eq(parsed.responses[1].etag, '"v1"')
			eq(parsed.responses[1].data, "BEGIN:VCALENDAR")
		end)

		it("marks a deleted resource by status", function()
			eq(caldav.parse_multistatus(BODY).responses[2].status, 404)
		end)

		it("picks up the new sync token", function()
			eq(caldav.parse_multistatus(BODY).sync_token, "tok-2")
		end)
	end)

	describe("parse_calendars", function()
		-- A calendar-home lists more than calendars: address books, task
		-- lists, and the home collection itself.
		local BODY = [[<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/">
  <d:response>
    <d:href>/dav/calendars/me/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/calendars/me/work/</d:href>
    <d:propstat><d:prop>
      <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
      <d:displayname>Work</d:displayname>
      <cs:getctag>ctag-1</cs:getctag>
      <c:supported-calendar-component-set><c:comp name="VEVENT"/></c:supported-calendar-component-set>
      <d:current-user-privilege-set><d:privilege><d:read/></d:privilege><d:privilege><d:write-content/></d:privilege></d:current-user-privilege-set>
    </d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/calendars/me/tasks/</d:href>
    <d:propstat><d:prop>
      <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
      <d:displayname>Tasks</d:displayname>
      <c:supported-calendar-component-set><c:comp name="VTODO"/></c:supported-calendar-component-set>
    </d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/calendars/me/team/</d:href>
    <d:propstat><d:prop>
      <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
      <d:displayname>Team</d:displayname>
      <d:current-user-privilege-set><d:privilege><d:read/></d:privilege></d:current-user-privilege-set>
    </d:prop></d:propstat>
  </d:response>
</d:multistatus>]]

		it("keeps only event calendars", function()
			local calendars = caldav.parse_calendars(BODY)
			local names = vim.tbl_map(function(c)
				return c.name
			end, calendars)
			eq(names, { "Work", "Team" })
		end)

		it("drops a task list", function()
			for _, calendar in ipairs(caldav.parse_calendars(BODY)) do
				neq(calendar.name, "Tasks", "VTODO collections are not event calendars")
			end
		end)

		it("drops the plain collection with no calendar resourcetype", function()
			eq(#caldav.parse_calendars(BODY), 2)
		end)

		it("reads the ctag", function()
			eq(caldav.parse_calendars(BODY)[1].ctag, "ctag-1")
		end)

		-- Writing to a calendar you only have read access to would fail with a
		-- confusing 403 mid-sync.
		it("notices a read-only calendar", function()
			local calendars = caldav.parse_calendars(BODY)
			falsy(calendars[1].readonly, "Work grants write-content")
			truthy(calendars[2].readonly, "Team grants only read")
		end)

		-- Absence of a privilege set is not evidence of anything.
		it("does not assume read-only when privileges are absent", function()
			local body = [[<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:response><d:href>/c/</d:href><d:propstat><d:prop>
    <d:resourcetype><c:calendar/></d:resourcetype><d:displayname>Plain</d:displayname>
  </d:prop></d:propstat></d:response></d:multistatus>]]
			falsy(caldav.parse_calendars(body)[1].readonly)
		end)
	end)
end)
