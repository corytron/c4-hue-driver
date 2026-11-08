-- Pair Bridge's pairing window (contract §1.2, action 1; #373 moved it out
-- of hue_bridge/driver.lua): the window stays open up to WINDOW_S for the
-- link button; while the bridge answers "link button not pressed", the key
-- is asked for again every RETRY_MS and Status counts down. The requests
-- themselves are bridge/pairing.lua's.
--
--   local w = pair_window.new(ctx)
--   w:open()     Pair Bridge: the window (re)opened at Bridge IP Address
--   w:close()    the window closed, its retry cancelled (Forget Pairing,
--                OnDriverDestroyed, and every end of a pairing)
--
-- A bridge id is expected while one is stored: another bridge is refused
-- until Forget Pairing (docs/bridge-compat-design.md, "Pairing another
-- bridge (#236)"). It is kept when the key is not, so it counts while Status
-- reads "Not paired". Without one, the bridge picked in Bridges Found
-- (state.pick_id, set for the one call that opens the window) is expected
-- the same way (§4 finding 4). A result that comes back for an earlier
-- Bridge IP Address is ignored, and closes the window.
--
-- ctx:
--   state               the driver's state table; read: ip, address_gen,
--                       creds, pick_id; written: pair_until (ms, the window's
--                       end), pairing_active, pair_expected_id
--   prop(name, value)   a Composer row (Status)
--   show_bridge_info(info)
--                       the bridge's model, name and firmware rows, from
--                       the probe before the key is asked for
--   on_paired(creds)    the key came: the window is closed already; what a
--                       new pairing means for the rest is the driver's
--   log
--
-- DriverWorks calls: C4:GetTime, C4:SetTimer.

local config = require("bridge.config")
local pairing = require("bridge.pairing")

local pair_window = {}
pair_window.__index = pair_window

pair_window.WINDOW_S = 120
pair_window.RETRY_MS = 3000

function pair_window.new(ctx)
	return setmetatable({ ctx = ctx, timer = nil }, pair_window)
end

function pair_window:close()
	local state = self.ctx.state
	if self.timer then
		self.timer:Cancel()
		self.timer = nil
	end
	state.pair_until = nil
	state.pairing_active = false
	state.pair_expected_id = nil
end

function pair_window:attempt(first)
	local ctx = self.ctx
	local state = ctx.state
	if first then
		ctx.prop("Status", "Pairing: contacting bridge")
	end
	state.pairing_active = true
	local gen = state.address_gen
	local function stale()
		if gen ~= state.address_gen then
			ctx.log.info("pairing result for an earlier bridge address ignored")
			self:close()
			return true
		end
	end
	local stored_id = state.creds and state.creds.bridge_id
	local paired_id = stored_id or state.pair_expected_id
	pairing.pair(state.ip, {
		on_probed = function(info)
			if stale() then return end
			ctx.show_bridge_info(info)
			if first then
				ctx.prop("Status", string.format("Pairing: found %s %s, requesting key", config.model_label(info.model),
					info.bridge_id))
			end
		end,
		on_link_button = function()
			if stale() then return end
			local left = math.ceil(((state.pair_until or 0) - C4:GetTime()) / 1000)
			if left <= 0 then
				self:close()
				return ctx.prop("Status", "Pairing window closed: press the link button on the Hue bridge, then run "
					.. "Pair Bridge again")
			end
			ctx.prop("Status", string.format("Press the link button on the Hue bridge (waiting %d:%02d)",
				math.floor(left / 60), left % 60))
			self.timer = C4:SetTimer(pair_window.RETRY_MS, function()
				self.timer = nil
				if state.pair_until then
					self:attempt(false)
				end
			end)
		end,
		on_paired = function(creds)
			self:close()
			if stale() then return end
			ctx.on_paired(creds)
		end,
		on_error = function(message)
			self:close()
			if stale() then return end
			ctx.prop("Status", "Pairing failed: " .. message)
		end,
	}, paired_id, stored_id == nil and paired_id ~= nil)
end

function pair_window:open()
	local ctx = self.ctx
	local state = ctx.state
	if not state.ip then
		ctx.prop("Status", "Enter the bridge IP address first")
		return
	end
	self:close()
	-- A bridge picked in Bridges Found (its pick sets it for this call only).
	state.pair_expected_id = state.pick_id
	state.pair_until = C4:GetTime() + pair_window.WINDOW_S * 1000
	self:attempt(true)
end

return pair_window
