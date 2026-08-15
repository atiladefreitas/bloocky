local xml = require("bloocky.sync.xml")

-- A real-shaped CalDAV reply, with the namespace prefixes servers actually use.
local MULTISTATUS = [[<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
  <D:response>
    <D:href>/dav/calendars/me/work/3f9a.ics</D:href>
    <D:propstat>
      <D:prop>
        <D:getetag>"1a2b3c"</D:getetag>
        <C:calendar-data>BEGIN:VCALENDAR&#13;
END:VCALENDAR</C:calendar-data>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/calendars/me/work/missing.ics</D:href>
    <D:propstat>
      <D:prop><D:getetag/></D:prop>
      <D:status>HTTP/1.1 404 Not Found</D:status>
    </D:propstat>
  </D:response>
  <D:sync-token>http://example.com/ns/sync/1234</D:sync-token>
</D:multistatus>]]

describe("sync.xml", function()
	describe("parsing", function()
		it("skips the declaration and finds the root", function()
			local doc = xml.parse(MULTISTATUS)
			eq(#doc.children, 1)
			eq(doc.children[1].name, "multistatus")
		end)

		it("collects repeated elements", function()
			eq(#xml.find_all(xml.parse(MULTISTATUS), "response"), 2)
		end)

		it("reads element text", function()
			local doc = xml.parse(MULTISTATUS)
			eq(xml.find_text(doc, "href"), "/dav/calendars/me/work/3f9a.ics")
			eq(xml.find_text(doc, "sync-token"), "http://example.com/ns/sync/1234")
		end)

		it("reads attributes", function()
			local node = xml.parse('<prop xmlns:D="DAV:" depth="1"/>').children[1]
			eq(node.attrs.depth, "1")
		end)

		it("handles self-closing elements", function()
			local doc = xml.parse("<a><b/><c>text</c></a>")
			eq(#doc.children[1].children, 2)
			eq(xml.find_text(doc, "c"), "text")
		end)
	end)

	-- The one thing that genuinely varies between CalDAV servers.
	describe("namespace prefixes", function()
		it("matches regardless of prefix or case", function()
			for _, markup in ipairs({
				"<d:multistatus><d:href>/x</d:href></d:multistatus>",
				"<D:multistatus><D:href>/x</D:href></D:multistatus>",
				"<multistatus><href>/x</href></multistatus>",
				"<ns0:multistatus><ns0:href>/x</ns0:href></ns0:multistatus>",
			}) do
				eq(xml.find_text(xml.parse(markup), "href"), "/x", markup)
			end
		end)

		it("keeps the original tag around", function()
			eq(xml.find(xml.parse(MULTISTATUS), "href").tag, "D:href")
		end)
	end)

	describe("entities", function()
		it("decodes the named ones", function()
			eq(xml.find_text(xml.parse("<a>&lt;tag&gt; &amp; &quot;quoted&quot;</a>"), "a"), '<tag> & "quoted"')
		end)

		it("decodes numeric and hex references", function()
			eq(xml.find_text(xml.parse("<a>&#65;&#x42;</a>"), "a"), "AB")
		end)

		-- A decoded "&" must not team up with following text to form a second
		-- entity: "&amp;lt;" is the literal text "&lt;", not "<".
		it("does not decode twice", function()
			eq(xml.find_text(xml.parse("<a>&amp;lt;</a>"), "a"), "&lt;")
		end)

		it("leaves an unknown entity alone", function()
			eq(xml.find_text(xml.parse("<a>&nope;</a>"), "a"), "&nope;")
		end)

		-- nr2char throws past INT_MAX; a server response must never be able to
		-- throw its way out of a sync.
		it("survives an out-of-range character reference", function()
			eq(xml.find_text(xml.parse("<a>&#xFFFFFFFF;</a>"), "a"), "&#xFFFFFFFF;")
			eq(xml.find_text(xml.parse("<a>&#0;</a>"), "a"), "&#0;")
			eq(xml.find_text(xml.parse("<a>&#4294967295;</a>"), "a"), "&#4294967295;")
		end)

		it("decodes inside attributes", function()
			eq(xml.parse('<a title="x &amp; y"/>').children[1].attrs.title, "x & y")
		end)
	end)

	describe("awkward markup", function()
		it("passes CDATA through untouched", function()
			eq(xml.find_text(xml.parse("<a><![CDATA[<not> &a; markup]]></a>"), "a"), "<not> &a; markup")
		end)

		it("drops comments", function()
			eq(xml.find_text(xml.parse("<a>keep<!-- drop me -->this</a>"), "a"), "keepthis")
		end)

		it("is not confused by a > inside an attribute", function()
			local node = xml.parse('<a cond="x > y"><b>hi</b></a>')
			eq(node.children[1].attrs.cond, "x > y")
			eq(xml.find_text(node, "b"), "hi")
		end)

		it("survives an unclosed tag", function()
			eq(xml.find_text(xml.parse("<a><b>text</a>"), "b"), "text")
		end)

		it("returns nothing useful for junk rather than throwing", function()
			eq(xml.find(xml.parse("not xml at all"), "href"), nil)
			eq(xml.find(xml.parse(""), "href"), nil)
		end)
	end)

	describe("navigation", function()
		it("returns only direct children", function()
			local doc = xml.parse(MULTISTATUS)
			local multistatus = doc.children[1]
			eq(#xml.children(multistatus, "response"), 2)
			eq(#xml.children(multistatus, "href"), 0, "href is a grandchild, not a child")
		end)

		it("reads a WebDAV status code", function()
			local responses = xml.find_all(xml.parse(MULTISTATUS), "response")
			eq(xml.status_code(responses[1]), 200)
			eq(xml.status_code(responses[2]), 404)
		end)

		it("pulls the etag and calendar data off a response", function()
			local response = xml.find_all(xml.parse(MULTISTATUS), "response")[1]
			eq(xml.find_text(response, "getetag"), '"1a2b3c"')
			truthy(xml.find_text(response, "calendar-data"):find("BEGIN:VCALENDAR", 1, true))
		end)

		it("is safe to call on nil", function()
			eq(xml.find(nil, "href"), nil)
			eq(xml.text(nil), nil)
			eq(xml.children(nil, "href"), {})
		end)
	end)
end)
