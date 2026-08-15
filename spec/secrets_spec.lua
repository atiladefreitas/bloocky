-- A guard against committing a real credential.
--
-- This is a public repository and the plugin handles OAuth tokens, calendar
-- passwords and client secrets. Reviewer attention is not a control: it works
-- until the one time somebody pastes a real token into a spec to debug
-- something and forgets. This fails the build instead.
--
-- The patterns are deliberately length-bounded, because that is what separates
-- a real credential from a test fixture. A genuine Google access token is 100+
-- characters; `ya29.a0AfH6SMBxxxxx` in a redaction test is not. So the rule
-- this enforces is simply: **fixtures must be obviously short and fake**.
--
-- Published specification test vectors (RFC 7636's PKCE example, for instance)
-- are not credentials and are meant to be here — they are what proves our
-- implementation matches the standard.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local PATTERNS = {
	{
		name = "Google OAuth client secret",
		-- Real ones are ~35 chars after the prefix.
		pattern = "GOCSPX%-[A-Za-z0-9_%-]{24,}",
	},
	{
		name = "Google access token",
		pattern = "ya29%.[A-Za-z0-9_%-]{40,}",
	},
	{
		name = "Google refresh token",
		pattern = "1//0[A-Za-z0-9_%-]{30,}",
	},
	{
		name = "Google OAuth client id",
		-- <digits>-<32 chars>.apps.googleusercontent.com; a placeholder like
		-- "xxxx.apps.googleusercontent.com" does not match.
		pattern = "[0-9]{8,}%-[a-z0-9]{20,}%.apps%.googleusercontent%.com",
	},
	{
		name = "private key",
		pattern = "%-%-%-%-%-BEGIN [A-Z ]*PRIVATE KEY%-%-%-%-%-",
	},
	{
		name = "AWS access key id",
		pattern = "AKIA[0-9A-Z]{16,}",
	},
	{
		name = "Slack token",
		pattern = "xox[baprs]%-[0-9A-Za-z%-]{20,}",
	},
}

-- Lua patterns have no {n,} quantifier, so expand it into an explicit run.
local function expand(pattern)
	return (pattern:gsub("(%b[])%{(%d+),%}", function(class, least)
		return class:rep(tonumber(least)) .. class .. "*"
	end))
end

local function files()
	local out = {}
	-- Exactly what would be committed, when git is available.
	local tracked = vim.fn.systemlist({ "git", "-C", root, "ls-files" })
	if vim.v.shell_error == 0 and #tracked > 0 then
		for _, name in ipairs(tracked) do
			table.insert(out, root .. "/" .. name)
		end
	end
	-- Plus anything not yet tracked, which is where a fresh mistake would sit.
	for _, name in ipairs(vim.fn.glob(root .. "/**/*.{lua,md,sh,vim,json,yml,yaml}", false, true)) do
		if not name:find("/%.git/") and not vim.tbl_contains(out, name) then
			table.insert(out, name)
		end
	end
	return out
end

local SKIP_BINARY = { png = true, jpg = true, jpeg = true, gif = true, pdf = true }

describe("no credentials in the repository", function()
	local scanned, findings = 0, {}

	for _, path in ipairs(files()) do
		local ext = path:match("%.([%w]+)$") or ""
		local stat = vim.uv.fs_stat(path)
		if not SKIP_BINARY[ext:lower()] and stat and stat.type == "file" and stat.size < 2 * 1024 * 1024 then
			local file = io.open(path, "r")
			if file then
				local content = file:read("*a") or ""
				file:close()
				scanned = scanned + 1
				local relative = path:sub(#root + 2)
				-- Do not flag this file for containing the patterns themselves.
				if relative ~= "spec/secrets_spec.lua" then
					for _, rule in ipairs(PATTERNS) do
						local found = content:match(expand(rule.pattern))
						if found then
							table.insert(findings, ("%s: possible %s (%s…)"):format(relative, rule.name, found:sub(1, 12)))
						end
					end
				end
			end
		end
	end

	it("scans the files that would be committed", function()
		truthy(scanned > 10, "only scanned " .. scanned .. " files; the walk is probably broken")
	end)

	it("finds no real credential anywhere in the tree", function()
		eq(findings, {}, "remove these before committing")
	end)

	-- If the scanner cannot recognise a credential it is decoration. These
	-- strings are fabricated to the right shape and appear nowhere else.
	describe("the scanner actually works", function()
		local samples = {
			["Google client secret"] = "GOCSPX-" .. string.rep("a", 28),
			["Google access token"] = "ya29." .. string.rep("b", 60),
			["Google refresh token"] = "1//0" .. string.rep("c", 40),
			["Google client id"] = "123456789012-" .. string.rep("d", 32) .. ".apps.googleusercontent.com",
			["private key"] = "-----BEGIN RSA PRIVATE KEY-----",
			["AWS key"] = "AKIA" .. string.rep("Z", 16),
		}
		for label, sample in pairs(samples) do
			it("catches a " .. label, function()
				local caught = false
				for _, rule in ipairs(PATTERNS) do
					if sample:match(expand(rule.pattern)) then
						caught = true
					end
				end
				truthy(caught, "the scanner would let this through: " .. sample:sub(1, 20))
			end)
		end

		-- The fixtures already in the suite must stay clearly fake, or every
		-- run would fail and the check would get switched off.
		it("leaves obviously fake test fixtures alone", function()
			for _, fixture in ipairs({
				"ya29.a0AfH6SMBxxxxx",
				"GOCSPX-abc",
				"xxxx.apps.googleusercontent.com",
				"tok-123",
				"1//0gabcdef",
			}) do
				for _, rule in ipairs(PATTERNS) do
					falsy(
						fixture:match(expand(rule.pattern)),
						("%q looks too much like a real credential; make the fixture shorter"):format(fixture)
					)
				end
			end
		end)
	end)
end)
