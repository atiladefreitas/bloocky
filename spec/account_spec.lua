local account = require("bloocky.sync.account")

describe("sync.account", function()
	describe("secrets", function()
		local function secret(cmd)
			account.forget_secrets()
			return account.secret({ id = "acct", password_cmd = cmd }, "password")
		end

		it("returns the command's output", function()
			eq(secret({ "echo", "hunter2" }), "hunter2")
		end)

		it("accepts a shell string", function()
			eq(secret("echo hunter2"), "hunter2")
		end)

		it("takes only the first line", function()
			eq(secret({ "printf", "hunter2\\nextra\\n" }), "hunter2")
		end)

		-- Copying a config example that names a password manager you do not
		-- have is the most likely way this fails, so the message has to name it.
		it("says plainly when the command is not installed", function()
			local value, err = secret({ "definitely-not-installed-xyz", "show", "x" })
			eq(value, nil)
			truthy(err:find("definitely-not-installed-xyz", 1, true), "the message must name the command")
			truthy(err:find("not installed", 1, true), "got: " .. err)
			falsy(err:find("ENOENT", 1, true), "a libuv errno is not an explanation")
		end)

		it("reports a non-zero exit with whatever the command said", function()
			local value, err = secret({ "sh", "-c", "echo 'no such entry' >&2; exit 2" })
			eq(value, nil)
			truthy(err:find("exited with 2", 1, true))
			truthy(err:find("no such entry", 1, true), "stderr should be surfaced: " .. err)
		end)

		it("reports empty output rather than returning an empty secret", function()
			local value, err = secret({ "sh", "-c", "true" })
			eq(value, nil)
			truthy(err:find("no output", 1, true))
		end)

		it("never returns an error with nothing after the colon", function()
			local _, err = secret({ "definitely-not-installed-xyz" })
			falsy(err:match(":%s*$"), "an error that trails off explains nothing: " .. err)
		end)

		it("prefers the command over a plain value", function()
			account.forget_secrets()
			eq(account.secret({ id = "a", password = "plain", password_cmd = { "echo", "fromcmd" } }, "password"), "fromcmd")
		end)

		it("falls back to a plain value", function()
			account.forget_secrets()
			eq(account.secret({ id = "a", password = "plain" }, "password"), "plain")
		end)

		it("caches so a keyring is not prompted on every request", function()
			account.forget_secrets()
			local acct = { id = "a", password_cmd = { "sh", "-c", "date +%s%N" } }
			eq(account.secret(acct, "password"), account.secret(acct, "password"))
		end)
	end)

	describe("validation", function()
		it("accepts a well-formed caldav account", function()
			eq(account.validate({
				id = "work",
				provider = "caldav",
				url = "https://dav.example.com/",
				username = "me",
				password_cmd = { "echo", "x" },
			}), {})
		end)

		it("rejects an unknown provider", function()
			truthy(#account.validate({ id = "x", provider = "nope" }) > 0)
		end)

		it("rejects plain http", function()
			local problems = account.validate({
				id = "x",
				provider = "caldav",
				url = "http://dav.example.com/",
				username = "me",
				password = "p",
			})
			truthy(vim.iter(problems):any(function(p)
				return p:find("https", 1, true) ~= nil
			end))
		end)

		it("warns about a plain-text password without blocking", function()
			local problems = account.validate({
				id = "x",
				provider = "caldav",
				url = "https://dav.example.com/",
				username = "me",
				password = "plain",
			})
			eq(#problems, 1)
			truthy(problems[1]:match("^WARN "), "a weak-but-working config should not be fatal")
		end)

		-- The id must be one no real token file could hold: validate consults
		-- stdpath("state"), so a developer who has authorised an account named
		-- in a spec would see that spec pass for the wrong reason.
		it("treats an unauthorised google account as fatal, not a warning", function()
			local problems = account.validate({
				id = "spec-never-authorised",
				provider = "google",
				client_id = "x.apps",
			})
			local fatal = vim.tbl_filter(function(p)
				return not p:match("^WARN ")
			end, problems)
			truthy(#fatal > 0, "syncing without a token cannot work, so it must stop the run")
			truthy(fatal[1]:find("BloockySyncAuth", 1, true), "the message must say what to do")
		end)
	end)

	describe("normalize", function()
		it("defaults a google calendar id to the username", function()
			eq(account.normalize({ id = "g", provider = "google", username = "me@gmail.com" }).calendar_id, "me@gmail.com")
		end)

		it("falls back to the primary calendar", function()
			eq(account.normalize({ id = "g", provider = "google" }).calendar_id, "primary")
		end)

		-- The REST provider builds its own endpoints; there is no URL to set.
		it("does not invent a url for a google account", function()
			eq(account.normalize({ id = "g", provider = "google" }).url, nil)
		end)

		it("leaves a caldav account alone", function()
			local acct = account.normalize({ id = "c", provider = "caldav", url = "https://x/" })
			eq(acct.url, "https://x/")
		end)
	end)

	describe("calendars", function()
		it("treats a calendar with no mode as writable", function()
			truthy(account.writable({ name = "Work" }))
			falsy(account.writable({ name = "Team", mode = "ro" }))
		end)

		it("picks the calendar marked default", function()
			eq(account.default_calendar({
				calendars = { { name = "A" }, { name = "B", default = true } },
			}).name, "B")
		end)

		it("falls back to the first writable one", function()
			eq(account.default_calendar({
				calendars = { { name = "RO", mode = "ro" }, { name = "B" } },
			}).name, "B")
		end)

		it("returns nothing when every calendar is read-only", function()
			eq(account.default_calendar({ calendars = { { name = "RO", mode = "ro" } } }), nil)
		end)
	end)
end)
