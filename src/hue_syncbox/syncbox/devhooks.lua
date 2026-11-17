-- Development builds only (#547, docs/fakebox-design.md §7): what lets a dev
-- build of the Hue Sync Box driver pair with the VM's fake sync box
-- (tools/fakebox.py), which serves HTTPS on a port other than 443 (443 needs
-- root on the VM) and announces that port in its mDNS answer. Two things,
-- and nothing else:
--
--   1. devhooks.parse_address(value): Pair Sync Box's Address takes
--      "host:port" as well as the plain address. The host is checked as a
--      release build checks the whole address (discovery.parse_ipv4), the
--      port is 1 to 65535, and ":443", the box's own, is left out. The
--      pairing stores that address, so Box Address shows it and the client
--      sends to https://host:port/api/v1: syncbox/client.lua and
--      syncbox/store.lua take an address with a port already, in every build.
--   2. devhooks.srv_address(ip, port): a search's candidate that announces an
--      SRV port other than 443 is checked and listed at "ip:port" instead of
--      being dropped (syncbox/discovery.lua).
--
-- tools/build.sh deletes this file from every release stage and refuses a
-- release stage that carries it. The driver and syncbox/discovery.lua reach
-- it through pcall(require, "syncbox.devhooks"); without it they behave
-- exactly as a release build does (tests/spec/syncbox_driver_spec.lua and
-- syncbox_discovery_spec.lua run without it). A release build that still
-- finds it, a dev build's file an update left behind, does not use it: it
-- raises at load, so that pcall fails as if it were absent, and says so once
-- (#492 I-6, as common/device.lua does with the dev loop). A driver run from
-- src/ (the specs, tests/e2e) has it, as a dev build does.

local devhooks = {}

devhooks.PORT_MAX = 65535
devhooks.BOX_PORT = 443 -- the box's own port: an address with it is written without

-- common/build_kind.lua, which tools/build.sh writes into every package:
-- "release" there means this file is a leftover. Lua 5.1's require keeps a
-- failed module marked as failed, so the line below is said once per Lua
-- state, however many modules ask.
do
	local ok, kind = pcall(require, "common.build_kind")
	if ok and kind == "release" then
		local found, log = pcall(require, "common.log")
		if found and type(log) == "table" and type(log.warn) == "function" then
			pcall(log.warn, "this release build found syncbox/devhooks.lua of an earlier dev build; not used")
		end
		error("syncbox/devhooks.lua is not used in a release build", 0)
	end
end

-- A port as a URL carries it: 1 to 5 decimal digits without a leading zero,
-- 1 to 65535 (a number, or its text); else nil.
function devhooks.port(value)
	if type(value) ~= "number" and type(value) ~= "string" then
		return nil
	end
	local text = tostring(value)
	if not text:match("^[1-9]%d?%d?%d?%d?$") then
		return nil
	end
	local n = tonumber(text)
	if n > devhooks.PORT_MAX then
		return nil
	end
	return n
end

local function joined(host, port)
	if port == devhooks.BOX_PORT then
		return host
	end
	return host .. ":" .. tostring(port)
end

-- Pair Sync Box's Address: "10.0.2.150" or "10.0.2.150:8443" (white space
-- around it ignored). Returns the address to store, or nil and why. Without
-- a ":port" the answer is discovery.parse_ipv4's, as in a release build.
-- The driver calls it only once its modules are loaded, so discovery is
-- required here, not at this module's load (discovery requires this one).
function devhooks.parse_address(value)
	local parse_ipv4 = require("syncbox.discovery").parse_ipv4
	local host, port
	if type(value) == "string" then
		host, port = value:match("^%s*(.-):(%d+)%s*$")
	end
	if not host then
		return parse_ipv4(value)
	end
	local ip, why = parse_ipv4(host)
	if not ip then
		return nil, why
	end
	local n = devhooks.port(port)
	if not n then
		return nil, "not a port (1 to " .. devhooks.PORT_MAX .. ")"
	end
	return joined(ip, n)
end

-- A search's candidate at `ip` (an address common/mdns.lua already found
-- usable) whose SRV record announced `port`: the address the identity check
-- and the Box list use, "ip" for 443, "ip:port" for any other port 1 to
-- 65535; nil for no port at all, or one no URL can carry.
function devhooks.srv_address(ip, port)
	local n = devhooks.port(port)
	if type(ip) ~= "string" or ip == "" or not n then
		return nil
	end
	return joined(ip, n)
end

return devhooks
