-- bridge/identity.lua (#373; docs/reviews/security-2026-10-24.md, issue
-- #53, #236): the bridge's identity checked without the key, with the TLS
-- self-check inside, moved out of hue_bridge/driver.lua. bridge/http.lua
-- and bridge/tlscheck.lua are stand-ins that record each request and answer
-- when the spec says; the fake C4 (fake.install_c4) runs the 30 s retry.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local S = 1000
local PAIRED_ID = "001788fffe123abc"
local OTHER_ID = "001788fffe456def"
local IP = "10.0.2.143"

describe("bridge/identity.lua (#373)", function()
	local identity, c4, id, state, gets, tls_runs, pinned_before, remembered, rows, infos, statuses, waiting_shown
	local attention, away_calls, answers

	local function config_answer(bridgeid, modelid)
		return { ok = true, code = 200, json = { bridgeid = bridgeid, modelid = modelid or "BSB003", name = "Hue Bridge Pro",
			swversion = "1972004020", apiversion = "1.72.0" } }
	end

	-- A waiter that records its answers under `name`.
	local function waiter(name)
		return function(ok) answers[#answers + 1] = name .. "=" .. tostring(ok) end
	end

	before_each(function()
		log.sink = function() end
		c4 = fake.install_c4()
		gets, tls_runs, pinned_before, remembered = {}, {}, false, false
		package.loaded["bridge.http"] = nil
		local real_http = require("bridge.http")
		package.loaded["bridge.http"] = {
			request = function(req, callback) gets[#gets + 1] = { req = req, callback = callback } end,
			peer_text = real_http.peer_text, TEXT_ROW = real_http.TEXT_ROW, TEXT_LOG = real_http.TEXT_LOG,
		}
		package.loaded["bridge.tlscheck"] = {
			run = function(ip, callback) tls_runs[#tls_runs + 1] = { ip = ip, callback = callback } end,
			remember_pinned = function() remembered = true end,
			pinned_before = function() return pinned_before end,
		}
		package.loaded["bridge.identity"] = nil
		identity = require("bridge.identity")
		rows, infos, statuses, waiting_shown, attention, away_calls, answers = {}, {}, 0, 0, {}, {}, {}
		state = { ip = IP, address_gen = 1, creds = { bridge_id = PAIRED_ID, key = "<key>" } }
		id = identity.new({
			state = state,
			paired = function() return state.creds ~= nil end,
			prop = function(name, value) rows[#rows + 1] = name .. ": " .. tostring(value) end,
			show_bridge_info = function(info) infos[#infos + 1] = info end,
			refresh_status = function() statuses = statuses + 1 end,
			show_stream_waiting = function() waiting_shown = waiting_shown + 1 end,
			show_attention = function(text) attention[#attention + 1] = text end,
			away = {
				answered = function(_, ip) away_calls[#away_calls + 1] = "answered " .. ip end,
				other_bridge = function(_, reported) away_calls[#away_calls + 1] = "other " .. reported end,
				unreachable = function() away_calls[#away_calls + 1] = "unreachable" end,
			},
			log = log,
		})
	end)

	after_each(function()
		for _, m in ipairs({ "bridge.http", "bridge.tlscheck", "bridge.identity" }) do package.loaded[m] = nil end
		log.sink = print
	end)

	describe("the paired bridge", function()
		it("asks /api/0/config without the key, then the TLS check, then lets keyed requests go", function()
			id:verify("stream", waiter("stream"))
			assert.equal(1, #gets)
			assert.same({ ip = IP, path = "/api/0/config", timeout = 10 }, gets[1].req, "no key, no TLS table")
			gets[1].callback(config_answer("001788FFFE123ABC"))
			assert.same({ { model = "BSB003", name = "Hue Bridge Pro", sw_version = "1972004020", api_version = "1.72.0" } },
				infos)
			assert.equal(1, #tls_runs)
			assert.equal(IP, tls_runs[1].ip)
			assert.same({}, answers, "not before the TLS check")
			tls_runs[1].callback("pinned", "decoy refused")
			assert.equal("pinned", state.tls_verdict)
			assert.is_true(remembered)
			assert.is_true(state.identity_ok)
			assert.same({ "answered " .. IP }, away_calls)
			assert.equal(1, statuses)
			assert.same({ "stream=true" }, answers)
		end)

		it("skips the TLS check once it answered pinned for this start and address", function()
			state.tls_verdict = "pinned"
			state.identity_text = "Bridge at " .. IP .. " not reachable (timeout); checking again in 30 s"
			id:verify("test", waiter("test"))
			gets[1].callback(config_answer(PAIRED_ID))
			assert.same({}, tls_runs)
			assert.is_nil(state.identity_text, "an old failure text goes")
			assert.same({ "test=true" }, answers)
		end)

		it("passes an inconclusive TLS check only on a Director version that answered pinned before", function()
			pinned_before = true
			id:verify("stream", waiter("stream"))
			gets[1].callback(config_answer(PAIRED_ID))
			tls_runs[1].callback("inconclusive", "timeout")
			assert.is_nil(state.tls_verdict, "inconclusive is no verdict")
			assert.same({ "stream=true" }, answers)
		end)

		it("holds keyed requests after an inconclusive TLS check otherwise, and checks again in 30 s", function()
			id:verify("stream", waiter("stream"))
			gets[1].callback(config_answer(PAIRED_ID))
			tls_runs[1].callback("inconclusive", "timeout")
			assert.is_false(state.identity_ok)
			assert.same({ "Status: TLS check inconclusive (timeout): nothing is sent; checking again in 30 s" }, rows)
			assert.equal(state.identity_text, "TLS check inconclusive (timeout): nothing is sent; checking again in 30 s")
			assert.same({}, answers, "the waiters stay for the next check")
			c4.advance(30 * S)
			assert.equal(2, #gets)
			gets[2].callback(config_answer(PAIRED_ID))
			tls_runs[2].callback("pinned", "decoy refused")
			assert.same({ "stream=true" }, answers)
		end)

		it("stops everything keyed when the controller accepts the decoy, until the next start or address", function()
			id:verify("stream", waiter("stream"))
			gets[1].callback(config_answer(PAIRED_ID))
			tls_runs[1].callback("not_pinned", "decoy accepted")
			assert.equal("not_pinned", state.tls_verdict)
			assert.is_false(state.identity_ok)
			assert.equal(2, statuses, "the TLS check's own, and the identity check's end")
			assert.equal(1, waiting_shown)
			assert.same({ identity.TLS_ATTENTION }, attention)
			assert.equal(identity.TLS_ATTENTION, state.attention_sent)
			assert.same({ "stream=false" }, answers)
			id:verify("test", waiter("test"))
			gets[2].callback(config_answer(PAIRED_ID))
			assert.equal(1, #tls_runs, "the verdict sticks: no second TLS check")
			assert.same({ "stream=false", "test=false" }, answers)
		end)

		it("ignores a TLS answer for an earlier address, or after OnDriverDestroyed", function()
			id:verify("stream", waiter("stream"))
			gets[1].callback(config_answer(PAIRED_ID))
			state.address_gen = 2
			tls_runs[1].callback("pinned", "decoy refused")
			state.address_gen, state.destroyed = 1, true
			tls_runs[1].callback("not_pinned", "decoy accepted")
			assert.is_nil(state.tls_verdict)
			assert.same({}, answers)
		end)
	end)

	describe("a failed check", function()
		it("refuses a model without the CLIP v2 API", function()
			id:verify("stream", waiter("stream"))
			gets[1].callback(config_answer(PAIRED_ID, "BSB001"))
			assert.is_false(state.identity_ok)
			assert.same({ "Status: Bridge at " .. IP .. " is a Hue Bridge v1, round (BSB001): no CLIP v2 API; nothing "
				.. "is sent" }, rows)
			assert.same({}, tls_runs)
			assert.same({ "stream=false" }, answers)
		end)

		-- Security review 2026-11-13, N-4 (#490): the rows were written from any
		-- answer with an id, before the id was compared.
		it("writes no row from another bridge's answer, nor its model (N-4)", function()
			id:verify("stream", waiter("stream"))
			local answer = config_answer(OTHER_ID, "BSB001")
			answer.json.name = "Garage" .. string.rep(" ", 100000)
			gets[1].callback(answer)
			assert.same({}, infos, "Bridge Model, Name and Firmware untouched")
			assert.same({ "Status: Bridge at " .. IP .. " reports ID " .. OTHER_ID .. ", expected " .. PAIRED_ID
				.. "; nothing is sent until the address is corrected" }, rows)
			assert.same({ "other " .. OTHER_ID }, away_calls)
			assert.same({ "stream=false" }, answers)
		end)

		it("cuts a long model id in Status (#489)", function()
			id:verify("stream", waiter("stream"))
			gets[1].callback(config_answer(PAIRED_ID, "X" .. string.rep("y", 100000)))
			assert.is_true(#rows[1] < 200, #rows[1] .. " bytes")
		end)

		it("refuses another bridge at the address, for good", function()
			id:verify("stream", waiter("stream"))
			gets[1].callback(config_answer(OTHER_ID))
			assert.is_false(state.identity_ok)
			assert.same({ "Status: Bridge at " .. IP .. " reports ID " .. OTHER_ID .. ", expected " .. PAIRED_ID
				.. "; nothing is sent until the address is corrected" }, rows)
			assert.same({ "other " .. OTHER_ID }, away_calls)
			assert.same({ "stream=false" }, answers)
			c4.advance(10 * 60 * S)
			assert.equal(1, #gets, "a different bridge is not asked again")
		end)

		it("asks an unreachable bridge again every 30 s, keeping the waiters", function()
			id:verify("stream", waiter("stream"))
			gets[1].callback({ ok = false, err = "timeout" })
			assert.is_false(state.identity_ok)
			assert.same({ "Status: Bridge at " .. IP .. " not reachable (timeout); checking again in 30 s" }, rows)
			assert.same({ "unreachable" }, away_calls)
			assert.same({}, answers)
			c4.advance(30 * S - 1)
			assert.equal(1, #gets)
			c4.advance(1)
			assert.equal(2, #gets)
			gets[2].callback({ ok = true, code = 200, json = { name = "no id" } })
			assert.equal("Status: Bridge at " .. IP .. " not reachable (no bridge id in the answer); checking again in 30 s",
				rows[2])
			c4.advance(30 * S)
			gets[3].callback(config_answer(PAIRED_ID))
			tls_runs[1].callback("pinned", "decoy refused")
			assert.same({ "stream=true" }, answers)
		end)

		it("ignores an answer for an earlier address, after OnDriverDestroyed, or after Forget Pairing", function()
			for _, change in ipairs({
				function() state.address_gen = state.address_gen + 1 end,
				function() state.ip = "192.0.2.144" end,
				function() state.destroyed = true end,
				function() state.creds = nil end,
			}) do
				state.ip, state.destroyed, state.creds = IP, nil, { bridge_id = PAIRED_ID, key = "<key>" }
				id:reset()
				id:verify("stream", waiter("stream"))
				change()
				gets[#gets].callback({ ok = false, err = "timeout" })
			end
			assert.same({}, rows)
			assert.same({}, away_calls)
			assert.same({}, answers)
		end)
	end)

	-- Security review 2026-11-13, N-6 (#490): a 401 or 403 on the stream
	-- locked the key at once, whatever answered at the address.
	describe("recheck: a 401 or 403 before the key is locked (N-6)", function()
		before_each(function()
			state.identity_ok, state.tls_verdict = true, "pinned"
		end)

		it("holds keyed requests, then asks unkeyed from a timer, and answers the paired bridge true", function()
			local same
			id:recheck(function(ok) same = ok end)
			assert.is_nil(state.identity_ok, "nothing keyed meanwhile")
			assert.equal(0, #gets, "not inside the transfer's callback")
			c4.advance(1)
			assert.equal(1, #gets)
			assert.same({ ip = IP, path = "/api/0/config", timeout = 10 }, gets[1].req, "no key")
			gets[1].callback(config_answer(PAIRED_ID))
			assert.is_true(same)
			assert.is_true(state.identity_ok)
		end)

		it("answers false for another bridge at the address, which then gets nothing keyed", function()
			local same
			id:recheck(function(ok) same = ok end)
			c4.advance(1)
			gets[1].callback(config_answer(OTHER_ID))
			assert.is_false(same)
			assert.is_false(state.identity_ok)
			assert.same({}, infos)
			assert.same({ "other " .. OTHER_ID }, away_calls)
		end)

		it("keeps the waiter while the bridge does not answer, and answers the key first", function()
			local order = {}
			id:recheck(function(ok) order[#order + 1] = "key=" .. tostring(ok) end)
			c4.advance(1)
			gets[1].callback({ ok = false, err = "timeout" })
			id:verify("stream", function(ok) order[#order + 1] = "stream=" .. tostring(ok) end)
			gets[2].callback(config_answer(PAIRED_ID))
			assert.same({ "key=true", "stream=true" }, order)
		end)

		it("is answered by a check that starts before its timer, and starts no second one", function()
			local same
			id:recheck(function(ok) same = ok end)
			id:verify("test", waiter("test"))
			assert.equal(1, #gets)
			gets[1].callback(config_answer(PAIRED_ID))
			assert.is_true(same)
			c4.advance(1)
			assert.equal(1, #gets)
			assert.same({ "test=true" }, answers)
		end)

		it("is dropped by an address change or a reset before its timer", function()
			local same = "unanswered"
			id:recheck(function(ok) same = ok end)
			state.address_gen = 2
			c4.advance(1)
			assert.equal(0, #gets)
			state.address_gen = 1
			id:recheck(function(ok) same = ok end)
			id:reset()
			c4.advance(60 * S)
			assert.equal(0, #gets)
			assert.equal("unanswered", same)
		end)
	end)

	describe("waiters", function()
		it("answers every purpose from one check, the stream first, the latest callback of a purpose", function()
			id:verify("test", waiter("test"))
			id:verify("stream", waiter("first stream"))
			id:verify("stream", waiter("stream"))
			assert.equal(1, #gets, "joined the check in flight")
			gets[1].callback(config_answer(PAIRED_ID))
			tls_runs[1].callback("pinned", "decoy refused")
			assert.same({ "stream=true", "test=true" }, answers)
		end)

		it("starts a check at once for a new waiter during the 30 s wait", function()
			id:verify("stream", waiter("stream"))
			gets[1].callback({ ok = false, err = "timeout" })
			id:verify("test", waiter("test"))
			assert.equal(2, #gets)
			c4.advance(60 * S)
			assert.equal(2, #gets, "the retry timer went with the new check")
		end)

		it("drops the waiters and the retry on reset, and cancels the retry on cancel_retry", function()
			id:verify("stream", waiter("stream"))
			gets[1].callback({ ok = false, err = "timeout" })
			id:reset()
			c4.advance(60 * S)
			assert.equal(1, #gets)
			id:verify("test", waiter("test"))
			gets[2].callback({ ok = false, err = "timeout" })
			id:cancel_retry()
			c4.advance(60 * S)
			assert.equal(2, #gets)
			id:verify(nil, nil)
			gets[3].callback(config_answer(PAIRED_ID))
			tls_runs[1].callback("pinned", "decoy refused")
			assert.same({ "test=true" }, answers, "the waiter survived cancel_retry, not reset")
		end)
	end)
end)
