-- Connection experiment: does C4:url let a second request to the same host
-- proceed while a streaming transfer to that host is open?
--
-- One scripted sequence, each step timed with C4:GetTime:
--   1. open a stream to the target and wait for its response headers
--   2. GET the target's ping path (15 s timeout)
--   3. two concurrent GETs of the ping path, to find the actual limit
--   4. GET a different host as a control
--   5. cancel the stream and report
-- Run it against the diagnostic server on the LAN (which logs every
-- connection it sees) and against the bridge; the two together attribute a
-- timeout to Director or to the bridge.

local log = require("common.log")
local http = require("bridge.http")

local conntest = {}

conntest.PING_TIMEOUT = 15
conntest.CONTROL_HOST = "example.com"

local function now_ms()
	local ok, t = pcall(function() return C4:GetTime() end)
	if ok and type(t) == "number" then
		return t
	end
	return os.time() * 1000
end

-- target = { name, ip (host or host:port), stream_path, ping_path,
--            headers (optional), key (optional), ca }
-- report(line) receives one line per step; done(summary) at the end, where
-- summary = { stream_ok, ping_ok, concurrent_ok (count), control_ok, lines }.
function conntest.run(target, report, done)
	local lines = {}
	local summary = { lines = lines }
	local started = now_ms()
	local stream_transfer

	local function say(fmt, ...)
		local line = string.format(fmt, ...)
		lines[#lines + 1] = line
		log.always("conntest %s", line)
		if report then report(line) end
	end

	local function elapsed()
		return now_ms() - started
	end

	local function finish()
		if stream_transfer then
			stream_transfer:Cancel()
			stream_transfer = nil
		end
		say("done in %d ms", elapsed())
		done(summary)
	end

	local function get(path, timeout, callback)
		local t0 = now_ms()
		return http.request({
			ip = target.ip, path = path, key = target.key, ca = target.ca, timeout = timeout,
		}, function(r)
			callback(r, now_ms() - t0)
		end)
	end

	local function describe(r)
		if r.ok then return "OK HTTP " .. tostring(r.code) end
		return "FAIL " .. tostring(r.err)
	end

	local function step4()
		local t0 = now_ms()
		http.request({ ip = conntest.CONTROL_HOST, path = "/", ca = { mode = "system" },
			timeout = conntest.PING_TIMEOUT }, function(r)
			summary.control_ok = r.ok or (r.code ~= nil)
			say("step 4 control GET %s: %s in %d ms", conntest.CONTROL_HOST, describe(r), now_ms() - t0)
			finish()
		end)
	end

	local function step3()
		local results, pending = {}, 2
		for i = 1, 2 do
			get(target.ping_path, conntest.PING_TIMEOUT, function(r, ms)
				results[i] = r
				say("step 3 concurrent GET #%d %s: %s in %d ms", i, target.ping_path, describe(r), ms)
				pending = pending - 1
				if pending == 0 then
					local ok = 0
					for _, res in pairs(results) do
						if res.ok then ok = ok + 1 end
					end
					summary.concurrent_ok = ok
					step4()
				end
			end)
		end
	end

	local function step2()
		get(target.ping_path, conntest.PING_TIMEOUT, function(r, ms)
			summary.ping_ok = r.ok
			say("step 2 GET %s with stream open: %s in %d ms", target.ping_path, describe(r), ms)
			step3()
		end)
	end

	say("target %s (%s), stream %s", target.name, target.ip, target.stream_path)
	local t0 = now_ms()
	local headers_seen = false
	stream_transfer = http.stream({
		ip = target.ip, key = target.key, path = target.stream_path, ca = target.ca,
		headers = target.headers, timeout = 300,
	}, {
		on_headers = function(code)
			headers_seen = true
			summary.stream_ok = code == 200
			say("step 1 stream headers: HTTP %s in %d ms", tostring(code), now_ms() - t0)
			if code == 200 then
				step2()
			else
				finish()
			end
		end,
		on_chunk = function(data)
			say("stream chunk %d bytes at %d ms", #data, elapsed())
		end,
		on_done = function(err_code, err_msg)
			stream_transfer = nil
			if not headers_seen then
				summary.stream_ok = false
				say("step 1 stream failed before headers: %d %s in %d ms", err_code, tostring(err_msg), now_ms() - t0)
				finish()
			else
				say("stream ended: %d %s at %d ms", err_code, tostring(err_msg), elapsed())
			end
		end,
	})
end

return conntest
