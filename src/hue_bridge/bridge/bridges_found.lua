-- The Bridges Found row (owner's answer D5; discovery research §2.4; #373
-- moved it out of hue_bridge/driver.lua): the bridges that answered on the
-- local network, never the internet, as a list row (bridge/rows.lua).
-- Searched for at the first load and again after Forget Pairing (3 s,
-- 1 min, 5 min, then every 15 min until paired) and on "Search again"; a
-- pick sets Bridge IP Address and runs Pair Bridge, which then pairs the
-- picked bridge only. The searches themselves are bridge/discovery.lua's.
--
--   local found = bridges_found.new(ctx)
--   found:show()                  the row from the last search: the summary
--                                 names the paired bridge's model and address
--   found:search(subnet, asked)   one search, all of mDNS (or with `subnet`
--                                 the offered sweep of the /24 networks);
--                                 `asked`: the owner picked it, so the result
--                                 goes to Last Action, else to the log only
--   found:schedule(i)             the first-load searches from the i-th on
--                                 (none while paired)
--   found:restart()               Forget Pairing: the first-load searches again
--   found:paired()                a pairing succeeded: the searches end and
--                                 the row reads "Paired with ..."
--   found:offer()                 the paired bridge does not answer at an
--                                 address typed by hand: one search per address
--   found:on_pick(value)          the Bridges_Found property handler
--   found:heard_elsewhere()       where the last search heard the paired
--                                 bridge, when not at Bridge IP Address
--   found:stop()                  OnDriverDestroyed: the search timer cancelled
--
-- ctx:
--   state             the driver's state table; read: ip, creds,
--                     bridge_model, discovery (bridge/discovery.lua, nil
--                     before late init), last_good_ip, address_gen,
--                     pair_until; written: offer_gen, pick_id, pair_expected_id
--   paired()          true while the driver holds a key
--   rows              the driver's bridge/rows.lua instance
--   last_action(text) a result the owner asked for
--   refresh()         the owner-facing rows (Attention offers the paired
--                     bridge's address, bridge/away.lua)
--   set_address(ip)   Bridge IP Address set, its handler run
--   pair()            Pair Bridge
--   log

local config = require("bridge.config")
local discovery = require("bridge.discovery")
local rows = require("bridge.rows")

local bridges_found = {}
bridges_found.__index = bridges_found

bridges_found.ROW = "Bridges Found"
bridges_found.SEARCH_AGAIN = "Search again"
bridges_found.FIRST_SEARCH_MS = { 3000, 60000, 300000 }
bridges_found.SEARCH_EVERY_MS = 900000

function bridges_found.new(ctx)
	return setmetatable({
		ctx = ctx,
		items = {},       -- the bridges the last search heard (bridge/discovery.lua's list items)
		by_label = {},    -- the labels shown -> an item, "search" or "subnet"
		searching = false,
		timer = nil,      -- the next first-load search
	}, bridges_found)
end

-- The offered search of every address, naming the networks find_subnet
-- searches, in its order (§4 finding 12): the /24 of Bridge IP Address
-- first, then the controller's when it differs (bridge/discovery.lua).
function bridges_found:subnet_item()
	local state = self.ctx.state
	if not state.discovery then
		return nil
	end
	return discovery.subnet_label(state.discovery:subnet_nets(state.ip))
end

function bridges_found:show()
	local state = self.ctx.state
	local paired_id = state.creds and state.creds.bridge_id or nil
	local labels, by_label = {}, {}
	local function add(label, value)
		label = rows.commaless(label)
		labels[#labels + 1] = label
		by_label[label] = value
	end
	for _, item in ipairs(self.items) do
		if paired_id and item.id == paired_id then
			add(discovery.item_label(item, paired_id), item)
		end
	end
	for _, item in ipairs(self.items) do
		if not (paired_id and item.id == paired_id) then
			add(discovery.item_label(item, paired_id), item)
		end
	end
	local n = #self.items
	local summary
	if self.searching then
		summary = "Looking for Hue bridges on the network..."
	elseif self.ctx.paired() and state.ip then
		local model = state.bridge_model
		if model == nil or model == "" then
			model = state.creds.model
		end
		local label = config.model_label(model)
		summary = label ~= "" and string.format("Paired with %s at %s", label, state.ip)
			or string.format("Paired with the bridge at %s", state.ip)
	elseif n > 0 then
		summary = string.format("%d Hue bridge%s found: pick one and click Set to pair", n, n == 1 and "" or "s")
	else
		summary = "No Hue bridge answered: type its address in Bridge IP Address"
	end
	add(bridges_found.SEARCH_AGAIN, "search")
	local subnet = self:subnet_item()
	if subnet and not self.searching and n == 0 then
		add(subnet, "subnet")
	end
	self.by_label = by_label
	self.ctx.rows:list(bridges_found.ROW, summary, labels)
end

-- `asked`: a search the owner picked (Search again, the subnet search)
-- reports in Last Action; the automatic ones write the row and the log
-- only, so the owner's last result stays (§4 finding 3).
function bridges_found:search(subnet, asked)
	local ctx = self.ctx
	local state = ctx.state
	if not state.discovery then
		return
	end
	self.searching = true
	self:show()
	local function found(list, detail)
		self.searching = false
		self.items = type(list) == "table" and list or {}
		self:show()
		local text = detail and detail.text
		if asked and text then
			ctx.last_action("Bridges Found: " .. tostring(text))
		else
			if text then
				ctx.log.info("Bridges Found (automatic search): %s", tostring(text))
			end
			ctx.refresh() -- Attention's offer of the paired bridge's address (bridge/away.lua)
		end
	end
	if subnet then
		state.discovery:find_subnet(found, state.ip)
	else
		state.discovery:find_all(found)
	end
end

function bridges_found:schedule(i)
	i = i or 1
	if self.timer then
		self.timer:Cancel()
		self.timer = nil
	end
	if self.ctx.paired() then
		return
	end
	self.timer = C4:SetTimer(bridges_found.FIRST_SEARCH_MS[i] or bridges_found.SEARCH_EVERY_MS, function()
		self.timer = nil
		if self.ctx.paired() then
			return self:show()
		end
		self:search(false)
		self:schedule(i + 1)
	end)
end

-- Forget Pairing starts the first-load searches again (§4 finding 2).
function bridges_found:restart()
	self:schedule(1)
end

-- Pairing succeeded: the row reads "Paired with ..." at once, and the
-- first-load searches end (§4 finding 2).
function bridges_found:paired()
	if self.timer then
		self.timer:Cancel()
		self.timer = nil
	end
	self:show()
end

-- The paired bridge does not answer at an address typed by hand (one it
-- never answered at): one automatic search per address, so that Bridges
-- Found lists where it does answer and Attention offers it (discovery
-- research §2.5: such an address is the installer's and never rewritten).
function bridges_found:offer()
	local state = self.ctx.state
	if not (self.ctx.paired() and state.ip) or state.ip == state.last_good_ip or state.offer_gen == state.address_gen then
		return
	end
	state.offer_gen = state.address_gen
	self:search(false)
end

-- Where the last search heard the paired bridge, when not at Bridge IP Address.
function bridges_found:heard_elsewhere()
	local state = self.ctx.state
	local id = state.creds and state.creds.bridge_id
	for _, item in ipairs(self.items) do
		if id and item.id == id and item.ip and item.ip ~= state.ip then
			return item.ip
		end
	end
	return nil
end

function bridges_found:pick(item)
	local ctx = self.ctx
	local state = ctx.state
	local paired_id = state.creds and state.creds.bridge_id or nil
	local where = string.format("%s at %s", config.model_label(item.model), tostring(item.ip))
	if item.supported == false then
		return ctx.last_action(where .. " is a first-generation bridge without the CLIP v2 API: this driver cannot use it")
	end
	if ctx.paired() and paired_id then
		if item.id ~= paired_id then
			if item.replaces == paired_id then
				return ctx.last_action(where .. " replaces the paired bridge: run Forget Pairing, then pick it here again")
			end
			return ctx.last_action("Not changed: " .. where .. " is another bridge; to pair it instead, run Forget "
				.. "Pairing first")
		end
		if item.ip == state.ip then
			return ctx.last_action("Already paired with this bridge at " .. tostring(item.ip))
		end
		ctx.set_address(item.ip)
		return ctx.last_action(string.format("Bridge IP Address set to %s, where the paired bridge answers", item.ip))
	end
	-- The picked bridge is the one expected (§4 finding 4): another bridge
	-- answering at its address during the pairing window is refused, as Pair
	-- Bridge refuses one while a bridge id is stored. On a never-paired
	-- driver the address change opens the window itself, with this id.
	state.pick_id = item.id
	ctx.set_address(item.ip)
	ctx.last_action("Bridge IP Address set to " .. tostring(item.ip) .. ": press the link button on the Hue bridge")
	if state.pair_until then
		state.pair_expected_id = item.id -- a window open at this address now waits for this bridge only
	else
		ctx.pair()
	end
	state.pick_id = nil
end

function bridges_found:on_pick(value)
	local pick = self.by_label[tostring(value)]
	if pick == nil then
		return -- the summary itself, or a list that changed meanwhile
	end
	self.ctx.rows:list_reset(bridges_found.ROW) -- the row snaps back to its summary
	if pick == "search" then
		self:search(false, true)
	elseif pick == "subnet" then
		self:search(true, true)
	else
		self:pick(pick)
	end
	self:show()
end

function bridges_found:stop()
	if self.timer then
		self.timer:Cancel()
		self.timer = nil
	end
end

return bridges_found
