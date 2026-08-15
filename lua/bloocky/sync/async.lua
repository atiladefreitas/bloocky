-- Coroutine plumbing, so the sync engine reads as a sequence.
--
-- A sync is a dozen dependent network calls: discover, then list, then query,
-- then push each change, then pull. Written with callbacks that nests a dozen
-- deep and the error path has to be repeated at every level. Written as a
-- coroutine it reads top to bottom, and one pcall at the boundary catches
-- everything.

local M = {}

-- Suspend until `fn`'s callback fires, then return whatever it was given.
-- Only valid inside M.run.
function M.await(fn)
	local co = coroutine.running()
	assert(co, "await must be called inside async.run")

	local results = nil
	local yielded = false

	fn(function(...)
		results = { n = select("#", ...), ... }
		-- The callback may fire before we ever yield — an argument check that
		-- fails, or a cached value. Resuming a coroutine that is still running
		-- is an error, so only resume if we actually suspended.
		if yielded then
			local ok, err = coroutine.resume(co)
			if not ok then
				vim.schedule(function()
					error(err, 0)
				end)
			end
		end
	end)

	if results == nil then
		yielded = true
		coroutine.yield()
	end
	return unpack(results, 1, results.n)
end

-- Run `body` as a coroutine. `done(err)` is called once, with a message if the
-- body threw and nil if it finished.
function M.run(body, done)
	done = done or function(err)
		if err then
			vim.notify("Bloocky sync: " .. tostring(err), vim.log.levels.ERROR)
		end
	end

	local co = coroutine.create(function()
		local ok, err = pcall(body)
		done(ok and nil or err)
	end)

	local ok, err = coroutine.resume(co)
	if not ok then
		done(err)
	end
end

-- Run `fn` over each item in turn, collecting results. Sequential on purpose:
-- CalDAV servers rate-limit, and a burst of parallel PUTs is the fastest way
-- to get an account throttled.
function M.map(items, fn)
	local out = {}
	for i, item in ipairs(items) do
		out[i] = fn(item, i)
	end
	return out
end

return M
