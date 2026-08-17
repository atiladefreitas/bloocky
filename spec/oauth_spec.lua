local http = require("bloocky.sync.http")
local oauth = require("bloocky.sync.oauth")

describe("sync.oauth", function()
	describe("PKCE", function()
		-- RFC 7636 Appendix B. If this ever fails, every authorization breaks.
		it("derives the S256 challenge exactly as the RFC does", function()
			eq(
				oauth.challenge_for("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
				"E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
			)
		end)

		it("produces a verifier of a legal length", function()
			local verifier = oauth.new_verifier()
			truthy(#verifier >= 43 and #verifier <= 128, "got " .. #verifier .. " characters")
		end)

		it("uses only unreserved characters", function()
			for _ = 1, 20 do
				eq(oauth.new_verifier():match("^[%w%-%._~]+$") ~= nil, true)
			end
		end)

		it("never repeats a verifier", function()
			local seen = {}
			for _ = 1, 50 do
				local verifier = oauth.new_verifier()
				falsy(seen[verifier], "a verifier repeated")
				seen[verifier] = true
			end
		end)

		it("emits base64url, not base64", function()
			for _ = 1, 30 do
				local encoded = oauth.base64url(oauth.random_bytes(32))
				falsy(encoded:find("[+/=]"), "found a character base64url forbids: " .. encoded)
			end
		end)

		it("draws randomness of the requested length", function()
			eq(#oauth.random_bytes(16), 16)
			eq(#oauth.random_bytes(32), 32)
		end)
	end)

	describe("query building", function()
		it("percent-encodes reserved characters", function()
			eq(oauth.encode("a b&c=d/e"), "a%20b%26c%3Dd%2Fe")
		end)

		it("leaves unreserved characters alone", function()
			eq(oauth.encode("aZ0-._~"), "aZ0-._~")
		end)

		it("encodes scope lists so the space separator survives", function()
			local query = oauth.query({ scope = "https://a/b https://a/c" })
			truthy(query:find("%%20"), "the separating space must be encoded")
		end)
	end)

	describe("parsing the redirect", function()
		it("reads code and state", function()
			local params = oauth.parse_redirect("GET /?code=4%2F0Axyz&state=abc HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
			eq(params.code, "4/0Axyz")
			eq(params.state, "abc")
		end)

		it("reads an error response", function()
			eq(oauth.parse_redirect("GET /?error=access_denied HTTP/1.1\r\n\r\n").error, "access_denied")
		end)

		it("copes with a request that has no query", function()
			eq(oauth.parse_redirect("GET /favicon.ico HTTP/1.1\r\n\r\n"), {})
		end)

		it("returns nil for something that is not a request", function()
			eq(oauth.parse_redirect("garbage"), nil)
		end)
	end)

	-- The listener is the part that touches the network stack, so it is worth
	-- driving for real rather than mocking.
	describe("the loopback listener", function()
		it("binds an ephemeral port and receives the redirect", function()
			local received, err
			local port = oauth.listen(5000, function(params, listen_err)
				received, err = params, listen_err
			end)

			truthy(port and port > 0, "no port was allocated")

			local client = vim.uv.new_tcp()
			client:connect("127.0.0.1", port, function()
				client:write("GET /?code=test-code&state=test-state HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
			end)

			vim.wait(3000, function()
				return received ~= nil or err ~= nil
			end)
			pcall(function()
				client:close()
			end)

			eq(err, nil)
			eq(received.code, "test-code")
			eq(received.state, "test-state")
		end)

		it("allocates a different port each time", function()
			local first = oauth.listen(1000, function() end)
			local second = oauth.listen(1000, function() end)
			neq(first, second, "a fixed port would be a predictable target")
		end)

		it("gives up rather than listening forever", function()
			local err
			oauth.listen(150, function(_, listen_err)
				err = listen_err
			end)
			vim.wait(2000, function()
				return err ~= nil
			end)
			truthy(err, "the listener should have timed out")
			truthy(err:find("timed out", 1, true))
		end)
	end)

	describe("token storage", function()
		it("keeps the token file out of the config directory", function()
			truthy(oauth.path():find(vim.fn.stdpath("state"), 1, true), "tokens belong in stdpath('state')")
		end)
	end)

	describe("redaction of OAuth material", function()
		it("hides every secret the token endpoint exchanges", function()
			local body = table.concat({
				"grant_type=authorization_code",
				"code=4/0AeanSxyz",
				"code_verifier=dBjftJeZ4CVP",
				"client_secret=GOCSPX-abc",
			}, "&")
			local out = http.redact(body)
			for _, secret in ipairs({ "4/0AeanSxyz", "dBjftJeZ4CVP", "GOCSPX%-abc" }) do
				falsy(out:find(secret), "leaked: " .. secret)
			end
			truthy(out:find("grant_type=authorization_code", 1, true), "harmless fields should survive")
		end)

		it("hides the token in a revoke call", function()
			falsy(http.redact("token=1//0gabcdef"):find("1//0gabcdef", 1, true))
		end)
	end)

	describe("scopes", function()
		-- The narrow pair, per the security decision in CALENDARS.md.
		it("asks for the least it can, by default", function()
			local scopes = oauth.scopes({ provider = "google" })
			truthy(vim.tbl_contains(scopes, "https://www.googleapis.com/auth/calendar.events"))
			falsy(
				vim.tbl_contains(scopes, "https://www.googleapis.com/auth/calendar"),
				"the broad scope can delete entire calendars and must never be the default"
			)
		end)

		it("can be overridden per account, for testing what a server accepts", function()
			eq(oauth.scopes({ provider = "google", scopes = { "custom" } }), { "custom" })
		end)
	end)
end)
