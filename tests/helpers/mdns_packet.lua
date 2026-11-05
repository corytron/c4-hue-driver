-- mDNS answers as a Hue bridge sends them (legacy unicast, RFC 6762 §6.7),
-- for driver-level specs of Bridges Found (#334). The same records as the
-- house's Bridge Pro answered on 2026-11-05: PTR, SRV, TXT, AAAA, A.

local M = {}

local function u16(n) return string.char(math.floor(n / 256) % 256, n % 256) end
local function u32(n) return u16(math.floor(n / 65536)) .. u16(n % 65536) end
local function ip_bytes(ip)
	local a, b, c, e = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	return string.char(tonumber(a), tonumber(b), tonumber(c), tonumber(e))
end

function M.packet(id, an, ar)
	local pieces, len, known = {}, 0, {}
	local function put(s) pieces[#pieces + 1] = s; len = len + #s end
	local function name(n)
		local parts = {}
		for label in n:gmatch("[^%.]+") do parts[#parts + 1] = label end
		for i = 1, #parts do
			local suffix = table.concat(parts, ".", i):lower()
			if known[suffix] then
				put(string.char(192 + math.floor(known[suffix] / 256), known[suffix] % 256))
				return
			end
			known[suffix] = len
			put(string.char(#parts[i]) .. parts[i])
		end
		put("\0")
	end
	put(u16(id) .. u16(0x8400) .. u16(1) .. u16(#an) .. u16(0) .. u16(#ar))
	name("_hue._tcp.local")
	put(u16(12) .. u16(1))
	local types = { A = 1, PTR = 12, TXT = 16, AAAA = 28, SRV = 33 }
	for _, rec in ipairs(an) do rec.section = "an" end
	local all = {}
	for _, rec in ipairs(an) do all[#all + 1] = rec end
	for _, rec in ipairs(ar) do all[#all + 1] = rec end
	for _, rec in ipairs(all) do
		name(rec.name)
		put(u16(types[rec.type]) .. u16(rec.section == "an" and 1 or 0x8001) .. u32(120))
		local slot = #pieces + 1
		put("\0\0")
		local start = len
		if rec.type == "PTR" then name(rec.target)
		elseif rec.type == "SRV" then put(u16(0) .. u16(0) .. u16(443)); name(rec.target)
		elseif rec.type == "TXT" then for _, item in ipairs(rec.txt) do put(string.char(#item) .. item) end
		elseif rec.type == "A" then put(ip_bytes(rec.ip))
		elseif rec.type == "AAAA" then put(string.rep("\0", 15) .. "\1") end
		pieces[slot] = u16(len - start)
	end
	return table.concat(pieces)
end

-- r: { id (the TXT bridge id), model, ips = { A records } }
function M.answer(r, query_id)
	local short = r.id:sub(-6):upper()
	local instance = "Hue Bridge - " .. short .. "._hue._tcp.local"
	local host = "001788" .. short .. ".local"
	local ar = {
		{ name = instance, type = "SRV", target = host },
		{ name = instance, type = "TXT", txt = { "bridgeid=" .. r.id:upper(), "modelid=" .. (r.model or "BSB003") } },
		{ name = host, type = "AAAA" },
	}
	for _, ip in ipairs(r.ips or {}) do ar[#ar + 1] = { name = host, type = "A", ip = ip } end
	return M.packet(query_id, { { name = "_hue._tcp.local", type = "PTR", target = instance } }, ar)
end

-- The LAN -----------------------------------------------------------------------------

-- lan.mdns: responders { id, model, ips, from (the sender, OS 4.x), garbage }
-- lan.hue[ip]: what the identity check finds there { id, model, name }
-- lan.tls[ip]: accepts 443, not a Signify chain; lan.hang[ip]: never answers

return M
