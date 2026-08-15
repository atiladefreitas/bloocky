-- Just enough XML to read a CalDAV multistatus.
--
-- Not a general parser and not trying to be: no validation, no DTDs, no
-- namespace resolution. WebDAV replies are a shallow, predictable shape, and
-- the one thing that genuinely matters is that namespace prefixes vary between
-- servers — <d:href>, <D:href> and <href> are all the same element. So
-- elements are matched on their local name, case-insensitively, and the prefix
-- is ignored rather than resolved.

local M = {}

local NAMED = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'" }

-- One pass over every entity form. Two passes would let a decoded "&" combine
-- with following text into a second, unintended entity.
local function decode(text)
	return (text:gsub("&(#?%w+);", function(entity)
		if entity:sub(1, 1) == "#" then
			local hex = entity:match("^#[xX](%x+)$")
			local code = hex and tonumber(hex, 16) or tonumber(entity:sub(2))
			-- Bounded to Unicode: nr2char throws past INT_MAX, and nothing a
			-- server sends may be able to throw. NUL is excluded on purpose.
			if code and code > 0 and code <= 0x10FFFF then
				return vim.fn.nr2char(code, 1)
			end
			return "&" .. entity .. ";"
		end
		return NAMED[entity:lower()] or ("&" .. entity .. ";")
	end))
end

-- The local name, lowercased: "D:getetag" -> "getetag"
local function local_name(tag)
	return (tag:match("[^:]+$") or tag):lower()
end

-- A ">" inside a quoted attribute value does not end the tag.
local function find_tag_end(text, from)
	local quote = nil
	for i = from + 1, #text do
		local char = text:sub(i, i)
		if quote then
			if char == quote then
				quote = nil
			end
		elseif char == '"' or char == "'" then
			quote = char
		elseif char == ">" then
			return i
		end
	end
	return nil
end

local function parse_attrs(inner)
	local attrs = {}
	for key, _, value in inner:gmatch("([%w%-%._:]+)%s*=%s*([\"'])(.-)%2") do
		attrs[local_name(key)] = decode(value)
	end
	return attrs
end

local function append_text(node, chunk)
	node.text = (node.text or "") .. chunk
end

function M.parse(text)
	local root = { name = "#document", children = {} }
	local stack = { root }
	local pos, len = 1, #text

	while pos <= len do
		local lt = text:find("<", pos, true)
		if not lt then
			break
		end
		if lt > pos then
			append_text(stack[#stack], decode(text:sub(pos, lt - 1)))
		end

		if text:sub(lt, lt + 3) == "<!--" then
			local stop = text:find("-->", lt, true)
			pos = stop and stop + 3 or len + 1
		elseif text:sub(lt, lt + 8) == "<![CDATA[" then
			local stop = text:find("]]>", lt, true)
			append_text(stack[#stack], text:sub(lt + 9, (stop or len + 1) - 1))
			pos = stop and stop + 3 or len + 1
		elseif text:sub(lt, lt + 1) == "<?" then
			local stop = text:find("?>", lt, true)
			pos = stop and stop + 2 or len + 1
		elseif text:sub(lt, lt + 1) == "<!" then
			local stop = text:find(">", lt, true)
			pos = stop and stop + 1 or len + 1
		else
			local gt = find_tag_end(text, lt)
			if not gt then
				break
			end
			local inner = text:sub(lt + 1, gt - 1)

			if inner:sub(1, 1) == "/" then
				-- Pop to the matching open tag. Being lenient about mismatched
				-- markup beats throwing away an otherwise usable response.
				local closing = local_name(inner:sub(2):match("^([%w%-%._:]+)") or "")
				for depth = #stack, 2, -1 do
					if stack[depth].name == closing then
						for _ = depth, #stack do
							table.remove(stack)
						end
						break
					end
				end
			else
				local self_closing = inner:sub(-1) == "/"
				if self_closing then
					inner = inner:sub(1, -2)
				end
				local tag = inner:match("^([%w%-%._:]+)")
				if tag then
					local node = {
						tag = tag,
						name = local_name(tag),
						attrs = parse_attrs(inner:sub(#tag + 1)),
						children = {},
					}
					table.insert(stack[#stack].children, node)
					if not self_closing then
						table.insert(stack, node)
					end
				end
			end
			pos = gt + 1
		end
	end

	return root
end

--------------------------------------------------------------------------
-- Navigation
--------------------------------------------------------------------------

function M.text(node)
	if not node then
		return nil
	end
	return (node.text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

-- Direct children with the given local name
function M.children(node, name)
	local out = {}
	if not node then
		return out
	end
	name = name:lower()
	for _, child in ipairs(node.children or {}) do
		if child.name == name then
			table.insert(out, child)
		end
	end
	return out
end

-- First descendant with the given local name, depth first
function M.find(node, name)
	if not node then
		return nil
	end
	name = name:lower()
	for _, child in ipairs(node.children or {}) do
		if child.name == name then
			return child
		end
		local found = M.find(child, name)
		if found then
			return found
		end
	end
	return nil
end

-- Every descendant with the given local name
function M.find_all(node, name, out)
	out = out or {}
	if not node then
		return out
	end
	name = name:lower()
	for _, child in ipairs(node.children or {}) do
		if child.name == name then
			table.insert(out, child)
		end
		M.find_all(child, name, out)
	end
	return out
end

-- Text of the first matching descendant, or nil
function M.find_text(node, name)
	return M.text(M.find(node, name))
end

-- The numeric code out of a WebDAV "<status>HTTP/1.1 404 Not Found</status>"
function M.status_code(node)
	local text = M.find_text(node, "status")
	return text and tonumber(text:match("HTTP/[%d%.]+%s+(%d+)")) or nil
end

return M
