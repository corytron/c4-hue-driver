-- Connection experiment: does C4:url let a second request to the same host
-- proceed while a streaming transfer to that host is open?
--
-- One scripted sequence, each step timed with C4:GetTime:
--   1. open a stream to the target and wait for its response headers
--   1b. wait 1 ms: a transfer started from inside OnHeaders fails with curl
--       error 2 "Failed initialization", so step 2 runs from a timer and the
--       experiment measures the connection limit, not re-entrancy
--   2. GET the target's ping path (15 s timeout)
--   3. two concurrent GETs of the ping path, to find the actual limit
--   4. GET a different host as a control
--   5. end the stream and report. Cancel() does not stop a streaming
--      transfer on OS 3.4.2, so the next chunk's callback returns true, which
--      does abort it.
-- Run it against the diagnostic server on the LAN (which logs every
-- connection it sees) and against the bridge; the two together attribute a
-- timeout to Director or to the bridge. Dev builds only (bridge/devtools.lua).

local log = require("common.log")
local http = require("bridge.http")

local conntest = {}

conntest.PING_TIMEOUT = 15
conntest.CONTROL_HOST = "example.com"

-- TLS options for the targets that are not the bridge (the bridge uses the
-- driver's bundle, bridge/http.lua): the diagnostic server's self-signed
-- certificate goes unverified, the control host is checked against the
-- platform's CAs.
conntest.TLS_INSECURE = { ssl_verify_peer = false, ssl_verify_host = false, ssl_cabundle = false }
conntest.TLS_SYSTEM = { ssl_verify_peer = true, ssl_verify_host = true, ssl_cabundle = false }

local function c4_time()
	return C4:GetTime()
end

local function now_ms()
	local ok, t = pcall(c4_time)
	if ok and type(t) == "number" then
		return t
	end
	return os.time() * 1000
end

-- target = { name, ip (host or host:port), stream_path, ping_path,
--            headers (optional), key (optional), tls (optional ssl_* options
--            on top of the bundle's, see http.options; ssl_cabundle = false
--            means the system CAs) }
-- report(line) receives one line per step; done(summary) at the end, where
-- summary = { stream_ok, ping_ok, concurrent_ok (count), control_ok, lines }.
function conntest.run(target, report, done)
	local lines = {}
	local summary = { lines = lines }
	local started = now_ms()
	local stream_transfer
	local finished, abort_reported = false, false

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
		finished = true
		if stream_transfer then
			-- Unreliable on OS 3.4.2; on_chunk returns true from now on, which
			-- is what actually ends the stream.
			stream_transfer:Cancel()
			stream_transfer = nil
		end
		say("done in %d ms", elapsed())
		done(summary)
	end

	local function get(path, timeout, callback)
		local t0 = now_ms()
		return http.request({
			ip = target.ip, path = path, key = target.key, tls = target.tls, timeout = timeout,
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
		http.request({ ip = conntest.CONTROL_HOST, path = "/", tls = conntest.TLS_SYSTEM,
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
		ip = target.ip, key = target.key, path = target.stream_path, tls = target.tls,
		headers = target.headers, timeout = 300,
	}, {
		on_headers = function(code)
			headers_seen = true
			summary.stream_ok = code == 200
			say("step 1 stream headers: HTTP %s in %d ms", tostring(code), now_ms() - t0)
			if code ~= 200 then
				finish()
				return true -- abort the stream here; Cancel() alone may not
			end
			-- Not step2() directly: we are inside OnHeaders (see 1b above).
			say("step 1b deferring 1 ms before step 2")
			C4:SetTimer(1, function()
				if not finished then
					step2()
				end
			end)
		end,
		on_chunk = function(data)
			if finished then
				if not abort_reported then
					abort_reported = true
					say("stream aborted on next chunk at %d ms", elapsed())
				end
				return true
			end
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
