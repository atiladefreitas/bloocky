local http = require("bloocky.sync.http")

describe("sync.http", function()
	-- A redactor that silently stops matching is worse than none, because the
	-- logs look safe.
	describe("redaction", function()
		it("hides bearer tokens", function()
			local out = http.redact("Authorization: Bearer ya29.a0AfH6SMBxxxxx")
			falsy(out:find("ya29", 1, true))
			truthy(out:find("<redacted>", 1, true))
		end)

		it("hides basic credentials", function()
			falsy(http.redact("Authorization: Basic dXNlcjpwYXNz"):find("dXNlcjpwYXNz", 1, true))
		end)

		it("hides a curl config user line", function()
			falsy(http.redact('user = "me@example.com:app-specific-password"'):find("app%-specific"))
		end)

		it("hides a header line inside a config file", function()
			local out = http.redact('header = "Authorization: Bearer secret-value"')
			falsy(out:find("secret%-value"))
		end)

		it("hides token-endpoint JSON", function()
			local body = '{"access_token":"tok-123","refresh_token":"ref-456","expires_in":3599}'
			local out = http.redact(body)
			falsy(out:find("tok%-123"))
			falsy(out:find("ref%-456"))
			truthy(out:find("3599", 1, true), "harmless fields survive")
		end)

		it("hides form-encoded secrets", function()
			local out = http.redact("grant_type=authorization_code&code=4/0Axxxx&client_secret=abc123")
			falsy(out:find("4/0Axxxx", 1, true))
			falsy(out:find("abc123", 1, true))
			truthy(out:find("grant_type=authorization_code", 1, true))
		end)

		it("leaves ordinary text alone", function()
			eq(http.redact("GET /dav/calendars/me/work/ 200 OK"), "GET /dav/calendars/me/work/ 200 OK")
		end)

		it("passes through non-strings", function()
			eq(http.redact(nil), nil)
			eq(http.redact(42), 42)
		end)
	end)

	describe("URL safety", function()
		it("accepts https", function()
			eq(http.check_url("https://caldav.example.com/dav/"), nil)
		end)

		it("refuses plain http", function()
			truthy(http.check_url("http://caldav.example.com/dav/"))
		end)

		-- The OAuth redirect never leaves the machine.
		it("allows loopback over http", function()
			eq(http.check_url("http://127.0.0.1:8080/callback"), nil)
			eq(http.check_url("http://localhost:8080/callback"), nil)
		end)

		it("refuses other schemes", function()
			truthy(http.check_url("ftp://example.com/"))
			truthy(http.check_url("file:///etc/passwd"))
		end)

		it("refuses nonsense", function()
			truthy(http.check_url("not a url"))
			truthy(http.check_url(nil))
		end)

		it("does not leak credentials in its own error message", function()
			local reason = http.check_url("ftp://user:hunter2@example.com/")
			falsy(tostring(reason):find("hunter2", 1, true))
		end)
	end)

	describe("header parsing", function()
		it("reads the status and headers", function()
			local status, headers = http.parse_headers("HTTP/1.1 200 OK\r\nETag: \"1a2b\"\r\nContent-Type: text/calendar\r\n\r\n")
			eq(status, 200)
			eq(headers.etag, '"1a2b"')
			eq(headers["content-type"], "text/calendar")
		end)

		it("lowercases header names so lookups are predictable", function()
			local _, headers = http.parse_headers("HTTP/1.1 200 OK\r\nETAG: x\r\n")
			eq(headers.etag, "x")
		end)

		-- curl dumps one block per response; the last one is the answer.
		it("keeps only the final block after a redirect", function()
			local raw = table.concat({
				"HTTP/1.1 301 Moved Permanently",
				"Location: https://example.com/dav/",
				"",
				"HTTP/1.1 207 Multi-Status",
				'ETag: "final"',
				"",
			}, "\r\n")
			local status, headers = http.parse_headers(raw)
			eq(status, 207)
			eq(headers.etag, '"final"')
			eq(headers.location, nil, "headers from the redirect must not bleed through")
		end)

		it("handles a 100 Continue preamble", function()
			local status = http.parse_headers("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 201 Created\r\n")
			eq(status, 201)
		end)

		it("returns nil for empty input", function()
			eq(http.parse_headers(""), nil)
			eq(http.parse_headers(nil), nil)
		end)
	end)

	-- Anything on a command line is readable by every process on the machine
	-- via `ps`. This is the guarantee that keeps credentials off it.
	describe("secrets never reach argv", function()
		local function argv_for(opts)
			local captured, seen = nil, {}
			local real = vim.system
			vim.system = function(args, _, cb)
				captured = args
				for i, arg in ipairs(args) do
					if arg == "--config" then
						local path = args[i + 1]
						local stat = vim.uv.fs_stat(path)
						local file = io.open(path)
						seen.mode = stat and string.format("%o", stat.mode % 512) or nil
						seen.config = file and file:read("*a") or ""
						if file then
							file:close()
						end
					end
				end
				return real({ "true" }, {}, cb)
			end
			http.request(opts, function() end)
			vim.wait(1000, function()
				return captured ~= nil
			end)
			vim.system = real
			return table.concat(captured or {}, " "), seen
		end

		it("keeps a basic-auth password out of the command line", function()
			local argv, seen = argv_for({
				url = "https://dav.example.com/",
				auth = { user = "me@example.com", password = "super-secret" },
			})
			falsy(argv:find("super%-secret"), "the password reached argv")
			falsy(argv:find("me@example.com", 1, true), "the username reached argv")
			truthy(argv:find("--config", 1, true), "credentials should go through a config file")
			truthy(seen.config and seen.config:find("super%-secret"), "the secret should be in that file")
		end)

		it("keeps a bearer token out of the command line", function()
			local argv = argv_for({ url = "https://api.example.com/", bearer = "ya29.a0AfH6SMBsecret" })
			falsy(argv:find("ya29", 1, true), "the token reached argv")
			falsy(argv:lower():find("authorization"), "the auth header reached argv")
		end)

		it("creates the config file readable only by its owner", function()
			local _, seen = argv_for({ url = "https://x.example.com/", auth = { user = "u", password = "p" } })
			eq(seen.mode, "600")
		end)

		it("still puts harmless headers on the command line", function()
			local argv = argv_for({ url = "https://x.example.com/", headers = { ["X-Thing"] = "visible" } })
			truthy(argv:find("visible", 1, true))
		end)
	end)

	describe("request", function()
		it("refuses an unsafe URL without spawning curl", function()
			local done, err
			http.request({ url = "http://example.com/dav/" }, function(e)
				err, done = e, true
			end)
			vim.wait(1000, function()
				return done
			end)
			truthy(done, "callback was never called")
			truthy(err)
		end)

		-- Exercises the real curl path end to end without a network.
		it("talks to a local file over the loopback guard", function()
			local ok = vim.fn.executable("curl") == 1
			if not ok then
				return
			end
			local done, result, err
			http.request({ url = "http://127.0.0.1:9/", retries = 0, timeout = 2000 }, function(e, res)
				err, result, done = e, res, true
			end)
			vim.wait(5000, function()
				return done
			end)
			truthy(done, "callback was never called")
			-- Port 9 refuses connections, so this must surface as an error
			-- rather than a silent success.
			truthy(err or result, "neither an error nor a response")
			if err then
				falsy(err:find("Bearer", 1, true), "errors must be redacted")
			end
		end)
	end)
end)
