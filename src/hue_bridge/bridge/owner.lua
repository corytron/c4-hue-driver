-- The lifecycle the three registry-owning bridge modules share (issue #56,
-- docs/lifecycle-refactor-design.md): bridge/lights.lua, bridge/scenes.lua
-- and bridge/zone_lights.lua each keep a bridge.registry of Control4 devices
-- standing for Hue resources, and until 2026-10-25 each carried its own copy
-- of the code around it (docs/reviews/slim-scenes-zones.md rows 12-18, 25-26,
-- docs/reviews/slim-lights.md row 14). This module holds that code once:
-- configuration and state plumbing, hello / goodbye / binding changes and
-- the project-side reconcile, the busy flags and the pending resyncs, room
-- resolution, device creation, the names trio, the Attention items, the
-- relink / forget pickers, Re-link, Forget and Link Devices, and the one
-- wording of the list rows' summaries (row_summary, #325).
--
-- Mechanism (slim-scenes-zones §4 Q7): a mixin. Each module sets
-- `setmetatable(module, { __index = owner })`, so an instance (whose
-- metatable is its module) falls through module -> owner for any method its
-- module does not define. Chosen over plain functions taking self because
-- every caller (driver.lua and the specs: L:hello, S:goodbye, Z:attention)
-- keeps calling the same method names on the same objects, a module
-- overrides a shared method simply by defining it (scenes' answer_hello, the
-- zone lights' hello wrapper), which is also how the hooks below work, and
-- the alternative costs a forwarding line per method and module for nothing
-- a reader gains. Lua 5.1 resolves the two-level __index chain in the VM.
-- The module stays stateless: everything lives on the instance. It never
-- holds another bridge module (specs reload them): registry.CLEAR is read
-- through the instance's own registry (self.reg.CLEAR).
--
-- What a module provides (module table fields, read through self):
--   TAG            "lights" / "scenes" / "zone_lights": the prefix of every log line
--   DEVICE_DRIVER  the .c4z its devices run (the project reconcile asks for it)
--   BINDING, BINDING_CLASS, MAX_NAMED
--   BUSY_FLAGS     { <job flag>, "resyncing" }; the job flag ("importing", "adding") comes first
--   EARLY_HELLOS_MAX  hellos kept before load(); nil keeps every one (scenes)
--   MESSAGES       { configure, hello, goodbye, forgotten } command names
--   WORDS          the owner-facing words that differ (each module lists its own)
--   OPTIONS        booleans, absent = false: push_needs_state, hello_tells_unknown,
--                  gone_at_hello, gone_after_add, announced_follows_entry,
--                  goodbye_keeps_strangers, log_unregistered_bind, settle_without_fetch,
--                  forget_request_mine_only (the divergences below say who sets which)
-- and these hooks (methods): entry_label, creation_name, configure_params,
-- send_state, state_known, announce_gone, record_of(rid), fields_of(record),
-- hello_fields(fields, hello, rid), fetched(rid), adopted_label,
-- announcement(rid, params), conflict_label(rid), device_text(rid, entry,
-- rest, relink), room_group_of(record), add_label(record), fetch_all(cb, ...),
-- absorb, settle, relink_refusal(device_id, rid), record_label(record),
-- linked_label(rid, entry), link_candidates(bound, skip_ids),
-- unimported_named(wanted); optionally entry_caps(caps), tell, foreign,
-- refuse_hello, adoptable_hello, registered, persist_extra,
-- goodbye_unregistered, forget_sent, reconciled, reconcile_done,
-- resync_extra, room_mapping, expected_name, agreeing_names, entry_name,
-- answer_hello, forgot, told_name, relink_fields, forget_label,
-- relinked_label, link_hello, link_rid, link_adopt_hello (defaults below).
--
-- Divergences between the three copies, settled before they were merged
-- (rule 2 of the contract): today's behaviour of each module is kept behind
-- the option, word or hook named, unless marked [intended] (the four
-- behaviour changes of the contract's #56 section, docs/review-leftovers-design.md §5).
--   P1 protect, expire_stale_busy, every log line: the module's tag -> TAG.
--   P2 flush / save: scenes write their forgotten devices first -> persist_extra.
--   P3 entry(rid): lights and zone lights copy caps (min_dim default nil / 1),
--      scenes do not -> entry_caps, defined by those two only.
--   P4 the ctx defaults: identical but for the binding constants -> owner.defaults.
--   F1 send_configure: HUE_CONFIGURE / HUE_SCENE_CONFIGURE -> MESSAGES.configure;
--      lights send through tell() (never to another module's device) -> tell.
--   F2 push: lights send nothing, not even CONFIGURE, for a light without a
--      model; scenes and zone lights send CONFIGURE and wait for a known
--      state -> OPTIONS.push_needs_state with state_known (lights: a model).
--   F3 answer_hello: scenes also send the group's on/off and level -> scenes' own.
--   F4 configure_all: early hellos were { rid, params } (lights, scenes) or
--      params (zone lights) -> { rid, params } for all; the zone lights'
--      hello(rid, params) form replays them the same (an internal shape only).
--   F5 hello: zone lights also take hello(params) -> their wrapper; the early
--      queue is capped at 200 for lights and zone lights, not for scenes ->
--      EARLY_HELLOS_MAX nil; scenes refuse a forgotten device (#47 F8) ->
--      refuse_hello; the announced record is { rid, name, model } (strings
--      only, R11), { rid, name, kind } as sent, { rid, name, kind, model }
--      (strings only) -> announcement; the held-rid line names "light" /
--      "scene" / "group" -> WORDS.held; zone lights adopt only kind "group"
--      -> adoptable_hello; lights and zone lights log an unknown bound list
--      apart, scenes say "not bound" -> OPTIONS.hello_tells_unknown; lights
--      mark a registered light gone at its hello when a synced run lacks it
--      (R6) -> OPTIONS.gone_at_hello with known_missing.
--   F6 adopt: the record (model / catalogue record / cached group) and its
--      fields -> record_of, fields_of; the hello's name (and model, kind):
--      strings only in lights and zone lights (R11), as sent in scenes ->
--      hello_fields; lights refuse another module's device -> foreign;
--      scenes drop a forgotten mark -> registered; the "gone" rule (a full
--      GET / a GET of the entry's kind / the groups fetched) -> fetched; the
--      adopted line's label -> adopted_label.
--   F7 goodbye: zone lights clear `announced` only for a device they hold
--      (after the rid check), lights and scenes for any -> OPTIONS.
--      goodbye_keeps_strangers; the stranger's line -> MESSAGES.goodbye,
--      WORDS.stranger; scenes drop a stranger's forgotten mark ->
--      goodbye_unregistered; zone lights forget the colour and online sent
--      -> forget_sent; lights and zone lights drop the device's announced
--      record (R5), scenes do not -> OPTIONS.announced_follows_entry; the
--      deleted line's tail -> WORDS.goodbye_tail.
--   F8 on_binding_changed: lights log a bound device they do not hold ->
--      OPTIONS.log_unregistered_bind.
--   F9 reconcile: `created` was a set (lights, zone lights) or a list
--      (scenes) -> a set for all (owner.created_set); R5 as in F7; lights
--      warn about entries another module's device holds right after the
--      registry step -> reconciled; scenes prune conflicts and forgotten
--      marks (#47 F10, F8) after the re-links -> reconcile_done; the
--      tombstone line names the add action -> WORDS.add_action.
--   B1 busy: importing / adding -> BUSY_FLAGS; the texts -> WORDS.busy_job,
--      WORDS.busy_resync.
--   B2 pending resyncs: lights and scenes answer every caller that waited
--      once (#47 F2), zone lights kept the latest one -> every caller for all
--      [intended, §5 item 1].
--   B3 a failed fetch: lights and scenes report done(false, err); zone lights
--      settle against the group cache anyway and report done(false, err,
--      sent) -> OPTIONS.settle_without_fetch.
--   B4 the done values: scenes add the /grouped_light items -> resync_extra;
--      zone lights' resync(done, items) hands `items` to their fetch_all.
--   R1 the group a record's room comes from: the owner device's Hue room
--      ("no Hue room") / the scene's group ("not in a Hue room") / the group
--      itself -> room_group_of; the mappings: lights' own registry, the
--      others the lights' -> room_mapping (lights override).
--   R2 the refusal's label: light / scene name / group -> add_label; lights'
--      inline resolution in add_light became room_for_add (same texts).
--   K1 the pickers' device text -> device_text: lights name an entry by its
--      Hue name in Re-link but as "Desk Lamp #12" in Forget.
--   K2 an empty picker: a placeholder (lights, scenes) or an empty array
--      (zone lights, for the driver's join) -> WORDS.no_relink / no_forget.
--   C1 jobs and created records held model / scene / group -> `record`.
--   C2 the first AddDevice callback's line names the kind -> WORDS.callback_kind.
--   C3 scenes drop a forgotten mark of a new device -> registered.
--   C4 lights mark a light deleted while its AddDevice was pending gone (R6),
--      scenes push -> OPTIONS.gone_after_add [intended for zone lights, §5 item 2].
--   C5 zone lights add one device with lines of their own -> their
--      create_device keeps them and calls register_added and added();
--      lights and scenes share the chain (create) -> WORDS.created_noun.
--   C6 ids_from and dump moved here from lights.lua (lights.ids_from and
--      lights.dump stay): scenes and zone lights no longer require bridge.lights.
--   N1 the expected Composer name: the Hue name (lights) or the creation name
--      (scenes, zone lights) -> expected_name, which the lights overrode
--      until #236. Since then the creation name for all three: the lights'
--      Hue name was the light's own name while their devices are named after
--      the Hue device, so a fresh import could differ at once; the names the
--      lights compared with before agree too -> agreeing_names (lights only).
--   N2 name_differences: lights' took include_dismissed and gave no
--      `expected` -> one function with both (lights' expected was entry.name
--      until #236, N1).
--   N3 adopt_hue_names: lights walked name_differences(true), the others the
--      linked rids with the same tests -> name_differences(true) for all. The
--      scenes and zone lights now read every Composer name before the first
--      rename, as the lights did; each device is still read once, before its
--      own rename, so the renames and the texts are the same.
--   N4 the texts -> WORDS.hue_names, device_noun, name_difference.
--   N5 (security review 2026-10-25 finding 8, not a divergence) every Hue
--      name handed to Control4 is a util.display_name: new_device_name for
--      AddDevice ("Hue " .. WORDS.kind when nothing of the creation name can
--      be shown), name_differences' expected for RenameDevice, shown() for
--      the forgotten message's name; the comparisons and the name matches run
--      both sides through the same function (see name_differences).
--   A1 the gone and unbound labels: entry_label, or the plain name (zone
--      lights) -> entry_name (also the re-link text's "was").
--   A2 the claimant label -> conflict_label; A3 the words -> WORDS.kind,
--      unbound_kind, relink_or_forget, forget_action, name_kind; A4 lights put
--      new lights first and their mappings and offline lights last -> lights'
--      attention() wraps attention_items(items).
--   X1 relink: the refusal for a rid the module has no record of ("light ...
--      is not on the bridge (connect ...)", "scene ... (Refresh Scenes ...)",
--      zone lights refusing a light rid) -> relink_refusal; lights refuse
--      another module's device -> foreign; scenes clear the kind of an
--      ordinary scene -> relink_fields; the "was" label -> entry_name; the
--      new record's label -> relinked_label (zone lights: "zone Reading
--      Nook"); the colour and online sent (zone lights) -> forget_sent; R5
--      (lights, zone lights) -> OPTIONS.announced_follows_entry; the words ->
--      WORDS.relink_target, registered.
--   X2 forget: the label ("Desk Lamp #12 (device 1036)" / "Bedside Lights
--      (zone, device 1180)") -> forget_label; the tail -> WORDS.forget_tail;
--      lights only drop the entry of another module's device -> foreign;
--      scenes remember the device (#47 F8) and tell a time-based scene's base
--      name, lights let the foreign-entry warning come again -> forgot,
--      told_name; zone lights' colour and online -> forget_sent.
--   X3 forget_request: lights and scenes tell a device they do not hold
--      that it is forgotten; zone lights answer nil (the coordinator asks the
--      lights) -> OPTIONS.forget_request_mine_only; the words ->
--      WORDS.requester, registered, MESSAGES.forgotten.
--   L1 Link Devices: the candidates (lights: hue_light devices outside the
--      skip set and in the project; scenes: hue_scene devices, or the ones
--      that said hello; zone lights: hue_light devices announcing kind group
--      or nothing, outside `skip_ids` as a set or a list) -> link_candidates;
--      what a device announced (scenes: or what Forget Scene remembered) ->
--      link_hello; zone lights take a rid only from a group device's hello
--      and adopt it under its Composer name when it announced none ->
--      link_rid, link_adopt_hello; the linked label and its "(not on the
--      bridge: marked gone)" (lights: whenever no model; scenes and zone
--      lights: when the entry is gone) -> linked_label; the name match ->
--      unimported_named, record_label; the words -> WORDS.link_noun,
--      link_many, link_one, link_none, link_hint.
--   Also intended (§5 items 3 and 4): zone lights give the registry their
--   field schema (zone_lights.ENTRY_FIELDS), and refresh_fields() clears a
--   field whose value became nil (analysis R9) for the fields a module
--   lists (REFRESH_CLEARS: lights after a full GET only; id_v1 for scenes
--   and zone lights).
-- Divergences deliberately left (not this PR's to align): scenes keep no
-- early-hello cap, no R5, no R11 for hellos and no schema; zone lights mark
-- a deleted zone gone at the AddDevice answer but not at a later hello.

local log = require("common.log")
local util = require("bridge.util")
local project = require("bridge.project")

local owner = {}

-- A name a message carries to a device, which shows it in a row (the
-- forgotten message's): its display name, or nil when nothing of it can be
-- shown (C4:SendToDevice drops an empty string anyway).
local function shown(name)
	local text = util.display_name(name)
	return text ~= "" and text or nil
end
owner.shown = shown

-- Every ctx field the module's caller leaves out defaults to the real C4
-- call; `module` gives the binding (BINDING, BINDING_CLASS). Returns ctx.
function owner.defaults(ctx, module)
	ctx.send = ctx.send or function(id, command, params)
		C4:SendToDevice(id, command, params)
	end
	ctx.add_device = ctx.add_device or function(driver, room_id, name, cb)
		C4:AddDevice(driver, room_id, name, cb)
	end
	ctx.bind = ctx.bind or function(bridge_id, device_id)
		C4:Bind(bridge_id, module.BINDING, device_id, module.BINDING, module.BINDING_CLASS)
	end
	ctx.persist_get = ctx.persist_get or function(name)
		return C4:PersistGetValue(name)
	end
	ctx.persist_set = ctx.persist_set or function(name, value)
		C4:PersistSetValue(name, value)
	end
	ctx.log = ctx.log or log
	ctx.now = ctx.now or os.time
	project.defaults(ctx, module.BINDING)  -- the project calls (bridge.project)
	return ctx
end

-- Plumbing ---------------------------------------------------------------------

function owner:bridge_id()
	return self.ctx.bridge_id or C4:GetDeviceID()
end

-- pcall wrapper for callback bodies; failures are logged, not raised.
function owner:protect(what, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		self.ctx.log.error("%s: %s failed: %s", self.TAG, what, tostring(err))
	end
	return ok, err
end

-- Something changed that must reach the store at the end of this batch.
function owner:mark()
	self.dirty = true
end

-- Hook: the module's own persisted keys, written before the registry.
function owner.persist_extra() end

function owner:flush()
	self:persist_extra()
	if self.dirty then
		self.dirty = false
		self.reg:save()
	end
end

-- Save now, whatever the dirty flag.
function owner:save()
	self:persist_extra()
	self.dirty = false
	self.reg:save()
end

-- A copy of the registry entry, or nil; its caps normalised by the module's
-- entry_caps when it has one.
function owner:entry(rid)
	local entry = rid ~= nil and self.registry[rid] or nil
	if not entry then
		return nil
	end
	local out = {}
	for k, v in pairs(entry) do
		out[k] = v
	end
	if self.entry_caps then
		out.caps = self:entry_caps(entry.caps)
	end
	return out
end

function owner:count()
	local n = 0
	for _ in pairs(self.registry) do
		n = n + 1
	end
	return n
end

-- A list row's summary (Lights, Scenes, Zone Lights, Motion Sensors; one
-- wording for the four, docs/list-rows-design.md, #325): `what` is what is
-- on the bridge ("47 lights"), `new` the module's count of the resources on
-- the bridge it could add, neither imported nor deleted in Composer.
-- Imported and new always appear; missing, unbound and deleted follow in
-- that order only when not 0, so the row fits Composer's value column
-- (about 75 characters): "47 lights on bridge, 2 imported, 0 new, 45
-- deleted". Imported is every device the module holds, missing those whose
-- resource is gone, unbound those no longer bound to the bridge, deleted the
-- tombstones. With no `what` (the module has not read the bridge yet) the
-- row is "<n> imported" alone.
function owner:row_summary(what, new)
	if what == nil then
		return string.format("%d imported", self:count())
	end
	local c = self.reg:counts()
	local text = string.format("%s on bridge, %d imported, %d new", tostring(what), self:count(), tonumber(new) or 0)
	for _, part in ipairs({ { c.gone, "missing" }, { c.unbound, "unbound" }, { c.tombstones, "deleted" } }) do
		if part[1] > 0 then
			text = text .. string.format(", %d %s", part[1], part[2])
		end
	end
	return text
end

-- Messages -----------------------------------------------------------------------

-- Every message to a device goes through here (lights.lua's own refuses a
-- device another module owns).
function owner:tell(device_id, command, params)
	self.ctx.send(device_id, command, params)
	return true
end

-- Hook: whether a device belongs to another module (lights.lua's skip set).
function owner.foreign()
	return false
end

-- The configuration to a registered device, from the registry entry (which
-- the last fetch refreshed, and which is there before any fetch).
function owner:send_configure(rid)
	local entry = self.registry[rid]
	if not entry then
		return false
	end
	local params = self:configure_params(rid, entry)
	self.last_configure[rid] = util.signature(params)
	self:tell(entry.device_id, self.MESSAGES.configure, params)
	return true
end

-- True when the device has not been told its current configuration.
function owner:configure_changed(rid)
	local entry = self.registry[rid]
	if not entry then
		return false
	end
	return self.last_configure[rid] ~= util.signature(self:configure_params(rid, entry))
end

-- CONFIGURE (when asked for, or when it changed) then the full STATE once
-- the state is known: before that a guessed state would turn a lit tile off
-- (state_known). With OPTIONS.push_needs_state (lights) nothing at all is
-- sent before then.
function owner:push(rid, reason, with_configure)
	if not self.registry[rid] or (self.OPTIONS.push_needs_state and not self:state_known(rid)) then
		return false
	end
	if with_configure or self:configure_changed(rid) then
		self:send_configure(rid)
	end
	if not self:state_known(rid) then
		return false
	end
	return self:send_state(rid, reason)
end

-- Bridge startup, before any GET: the configuration to every registered,
-- bound device from its persisted entry, then the hellos that waited for
-- load(). Returns the number of configurations sent.
function owner:configure_all()
	local n = 0
	for _, rid in ipairs(self.reg:rids()) do
		if self.registry[rid].state ~= "unbound" and self:send_configure(rid) then
			n = n + 1
		end
	end
	self.configured_once = true
	local queued = self.early_hellos
	self.early_hellos = {}
	for _, h in ipairs(queued) do
		self:protect("early hello", self.hello, self, h.rid, h.params)
	end
	return n
end

-- A device left the picture (forgotten, deleted, re-linked): the conflicts
-- that named it are over.
function owner:clear_conflicts_for(device_id)
	for rid, c in pairs(self.conflicts) do
		if c.holder == device_id or c.claimant == device_id then
			self.conflicts[rid] = nil
		end
	end
end

-- Configuration and, once something is known, the full state.
function owner:answer_hello(rid)
	if self:state_known(rid) then
		return self:push(rid, "hello", true)
	end
	return self:send_configure(rid)
end

-- The "gone" rule: the bridge is known to lack the rid's resource (a fetch
-- that would list it has succeeded and it is not there).
function owner:known_missing(rid)
	return self:fetched(rid) and self:record_of(rid) == nil
end

-- The hello of a registered device. With OPTIONS.gone_at_hello (lights, R6)
-- a linked entry whose resource the bridge knows to be gone is marked gone
-- at once rather than at the next resync.
function owner:answer_device(rid)
	local entry = self.registry[rid]
	if self.OPTIONS.gone_at_hello and entry and entry.state == "linked" and self:known_missing(rid) then
		return self:mark_missing(rid, "hello")
	end
	return self:answer_hello(rid)
end

-- A linked entry whose resource is not on the bridge (the caller has
-- checked) is marked gone and its device told (announce_gone). `while_added`
-- names the case of code analysis 2026-10-22 R6 in the log: the resource was
-- deleted in Hue while its AddDevice was pending. True when marked.
function owner:mark_missing(rid, reason, while_added)
	local entry = self.registry[rid]
	if not entry or entry.state ~= "linked" or not self.reg:set_state(rid, "gone") then
		return false
	end
	self:mark()
	self:flush()
	if while_added then
		self.ctx.log.warn("%s: %s (device %d) was deleted on the bridge while its device was being added; marked gone "
			.. "(%s)", self.TAG, self:entry_label(rid, entry), entry.device_id, self.WORDS.relink_or_forget)
	else
		self.ctx.log.warn("%s: %s (device %d) is no longer on the bridge; marked gone (%s)", self.TAG,
			self:entry_label(rid, entry), entry.device_id, self.WORDS.relink_or_forget)
	end
	self:announce_gone(rid, reason)
	return true
end

-- Hello, adoption, goodbye, bindings (docs/import-design.md §4) ---------------------

-- A hello's name, kind or model as the device sent it: a non-empty string,
-- else nil (C4:SendToDevice delivers strings; code analysis 2026-10-22 R11).
function owner.hello_text(value)
	if type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

-- Hooks: a hello the module answers itself and refuses (scenes: a device
-- Forget Scene let go), and whether a hello may adopt at all (zone lights:
-- kind "group" only).
function owner.refuse_hello()
	return false
end

function owner.adoptable_hello()
	return true
end

-- A device said hello { rid?, device_id?, name?, ... }. Answers a known rid;
-- a device registered under another rid is answered with that one (its
-- persisted rid is stale after a re-link); a rid the registry lacks from
-- exactly one bound device is adopted; two devices claiming one rid change
-- nothing and go to Attention. Before load() the hello waits for
-- configure_all() (at most EARLY_HELLOS_MAX of them). Returns true when answered.
function owner:hello(rid, params)
	params = params or {}
	if type(rid) ~= "string" or rid == "" then
		rid = nil
	end
	local device_id = util.positive(params.device_id)
	if not (self.loaded or self.synced) then
		if rid or device_id then
			local max = self.EARLY_HELLOS_MAX
			if max == nil or #self.early_hellos < max then
				self.early_hellos[#self.early_hellos + 1] = { rid = rid, params = params }
			else
				self.ctx.log.warn("%s: %s from device %s before the registry was loaded: dropped (%d waiting)", self.TAG,
					self.MESSAGES.hello, tostring(params.device_id), #self.early_hellos)
			end
		end
		return false
	end
	if device_id and self:refuse_hello(device_id, rid) then
		return false
	end
	if device_id then
		self.announced[device_id] = self:announcement(rid, params)
	end

	local entry = rid and self.registry[rid] or nil
	if entry then
		if device_id and entry.device_id ~= device_id then
			self.conflicts[rid] = { holder = entry.device_id, claimant = device_id }
			self.ctx.log.warn("%s: device %d claims %s, which device %d holds; nothing changed (see Attention)", self.TAG,
				device_id, self:entry_label(rid, entry), entry.device_id)
			return false
		end
		return self:answer_device(rid)
	end
	if not device_id then
		return false
	end
	local held_rid = self.reg:by_device(device_id)
	if held_rid then
		self.ctx.log.info("%s: device %d said hello with %s; its registered %s is %s", self.TAG, device_id,
			tostring(rid), self.WORDS.held, held_rid)
		return self:answer_device(held_rid)
	end
	if not rid or not self:adoptable_hello(params) then
		return false  -- a bare device (Link Devices matches it by name), or not this module's kind
	end

	local bound, why = self.project:bound_set()
	if not bound or not bound[device_id] then
		if why == "unknown" and self.OPTIONS.hello_tells_unknown then
			self.ctx.log.info("%s: device %d announced %s, but the bound-device list is unknown; not adopted", self.TAG,
				device_id, rid)
		else
			self.ctx.log.info("%s: device %d announced %s but is not bound; not adopted", self.TAG, device_id, rid)
		end
		return false
	end
	for other_id, h in pairs(self.announced) do
		if other_id ~= device_id and h.rid == rid then
			self.conflicts[rid] = { holder = other_id, claimant = device_id }
			self.ctx.log.warn("%s: devices %d and %d both announce %s; neither adopted (see Attention)", self.TAG,
				other_id, device_id, rid)
			return false
		end
	end
	if not self:adopt(device_id, rid, params, "from its own persisted rid") then
		return false
	end
	self:flush()
	return self:answer_hello(rid)
end

-- Hook: a device was registered (adopted or created).
function owner.registered() end

-- Register a bound device for a rid the registry lacks (auto-adopt, Link
-- Devices): fields from the module's record of the rid when there is one,
-- else from what the device announced; gone at once when the bridge is known
-- to lack the rid (known_missing). A device another module owns is never
-- adopted. Returns the entry or nil.
function owner:adopt(device_id, rid, hello, how)
	if self:foreign(device_id) then
		self.ctx.log.warn("%s: not adopting device %d for %s: the device belongs to another module (a zone light)",
			self.TAG, device_id, tostring(rid))
		return nil
	end
	local fields = self:fields_of(self:record_of(rid))
	fields.device_id = device_id
	self:hello_fields(fields, hello, rid)
	local entry, err = self.reg:add(rid, fields)
	if not entry then
		self.ctx.log.warn("%s: could not adopt device %d for %s: %s", self.TAG, device_id, tostring(rid), tostring(err))
		return nil
	end
	self:registered(device_id)
	self:mark()
	if self:known_missing(rid) then
		self.reg:set_state(rid, "gone")
	end
	self.ctx.log.always("%s: adopted %s (device %d) %s", self.TAG, self:adopted_label(rid, entry), device_id, how)
	return entry
end

-- Hooks of goodbye: a device the module does not hold said goodbye; the
-- per-rid memory beyond last_configure and conflicts (zone lights: what
-- colour and online state was sent).
function owner.goodbye_unregistered() end

function owner.forget_sent() end

-- A device said goodbye { rid?, device_id }: it is being deleted in
-- Composer, and its entry becomes a tombstone. Returns the tombstone, or nil
-- when the device is not one of this module's.
function owner:goodbye(params)
	params = params or {}
	local device_id = util.positive(params.device_id)
	local rid = device_id and self.reg:by_device(device_id) or nil
	if not rid and type(params.rid) == "string" and self.registry[params.rid] then
		local entry = self.registry[params.rid]
		if not device_id or entry.device_id == device_id then
			rid = params.rid
		end
	end
	if device_id and not self.OPTIONS.goodbye_keeps_strangers then
		self.announced[device_id] = nil
	end
	if not rid then
		self.ctx.log.debug("%s: %s from %s (%s, %s)", self.TAG, self.MESSAGES.goodbye, self.WORDS.stranger,
			tostring(params.device_id), tostring(params.rid))
		self:goodbye_unregistered(device_id)
		return nil
	end
	if device_id then
		self.announced[device_id] = nil
	end
	local entry = self.registry[rid]
	local label = self:entry_label(rid, entry)
	local tomb = self.reg:tombstone(rid)
	self.last_configure[rid] = nil
	self:forget_sent(rid)
	self.conflicts[rid] = nil
	if self.OPTIONS.announced_follows_entry then
		self.announced[entry.device_id] = nil  -- also when the goodbye named the rid alone (R5)
	end
	self:clear_conflicts_for(entry.device_id)
	self:mark()
	self:flush()
	self.ctx.log.always("%s: %s (device %d) was deleted in Composer; %s", self.TAG, label, entry.device_id,
		self.WORDS.goodbye_tail)
	return tomb
end

-- OnBindingChanged for the bridge's binding: an unbound device's entry
-- becomes "unbound", a re-bound one "linked" (and is told its configuration
-- and state). Returns true when an entry changed state.
function owner:on_binding_changed(binding, class, bound, other_id)
	if tonumber(binding) ~= self.BINDING then
		return false
	end
	if class ~= nil and class ~= self.BINDING_CLASS then
		return false
	end
	local device_id = util.positive(other_id)
	if not device_id then
		return false
	end
	local rid, entry = self.reg:by_device(device_id)
	if not rid then
		if self.OPTIONS.log_unregistered_bind and (bound == true or bound == "true") then
			self.ctx.log.info("%s: device %d bound but not registered; its hello or Link Devices adopts it", self.TAG,
				device_id)
		end
		return false  -- another module's device, or one its hello or Link Devices adopts
	end
	local changed = false
	if bound == false or bound == "false" then
		if entry.state == "linked" and self.reg:set_state(rid, "unbound") then
			changed = true
			self.ctx.log.warn("%s: %s (device %d) was unbound from the bridge", self.TAG, self:entry_label(rid, entry),
				device_id)
		end
	elseif bound == true or bound == "true" then
		if entry.state == "unbound" and self.reg:set_state(rid, "linked") then
			changed = true
			self.ctx.log.info("%s: %s (device %d) is bound again", self.TAG, self:entry_label(rid, entry), device_id)
			self:answer_hello(rid)
		end
	end
	if changed then
		self:mark()
		self:flush()
	end
	return changed
end

-- Hooks of reconcile: right after the registry's step (lights: entries
-- another module's device holds), and once the re-linked entries are
-- answered (scenes: conflicts and forgotten marks of devices that left).
function owner.reconciled() end

function owner.reconcile_done() end

-- The set { [rid] = true } of a creation's `created` list, which the
-- reconcile after it leaves alone.
function owner.created_set(created)
	local out = {}
	for _, c in ipairs(created or {}) do
		out[c.record.rid] = true
	end
	return out
end

-- Step 1 of every resync, the project side (docs/import-design.md §5): the
-- bound set and the module's devices in the project decide linked / unbound
-- / tombstone per entry (bridge.registry holds the rules; a failed or empty
-- GetDevices is "unknown"). Saves unless `no_save`. A bound-device lookup
-- that failed, or answered no table (nil: unknown, issue #48 item 14),
-- changes nothing. `created` (optional, a set { [rid] = true }) names the
-- entries the caller's batch has just created: Director may not list their
-- devices or bindings yet, so they are left as they are (item 13).
function owner:reconcile(no_save, created)
	local bound, why = self.project:bound_set()
	if not bound then
		-- Unknown is expected while nothing is registered (a new install):
		-- debug then, a warning while there are entries it cannot judge.
		local note = (why == "unknown" and self:count() == 0) and self.ctx.log.debug or self.ctx.log.warn
		note("%s: reconcile skipped: the bound-device lookup %s", self.TAG,
			why == "unknown" and "answered no list" or "failed")
		return { unbound = {}, relinked = {}, tombstoned = {} }
	end
	local infos = self.project:devices_of(self.DEVICE_DRIVER)
	local present = nil
	if infos then
		present = {}
		for id in pairs(infos) do
			present[id] = true
		end
	end
	-- A tombstone keeps no device id; the device's announced rid goes with
	-- its entry (code analysis 2026-10-22 R5).
	local device_of = {}
	if self.OPTIONS.announced_follows_entry then
		for rid, entry in pairs(self.registry) do
			device_of[rid] = entry.device_id
		end
	end
	local r = self.reg:reconcile({ bound = bound, present = present, skip = created })
	if #r.unbound + #r.relinked + #r.tombstoned > 0 then
		self:mark()
	end
	self:reconciled(r)
	for _, rid in ipairs(r.tombstoned) do
		local tomb = self.reg:tombstones()[rid] or {}
		self.last_configure[rid] = nil
		self.conflicts[rid] = nil
		if device_of[rid] then
			self.announced[device_of[rid]] = nil
		end
		self.ctx.log.warn("%s: %s was deleted in Composer while the bridge was not watching; %s lists it as deleted",
			self.TAG, tostring(tomb.name or rid), self.WORDS.add_action)
	end
	for _, rid in ipairs(r.unbound) do
		local entry = self.registry[rid]
		self.ctx.log.warn("%s: %s (device %d) is not bound to this bridge", self.TAG, self:entry_label(rid, entry),
			entry.device_id)
	end
	for _, rid in ipairs(r.relinked) do
		self:answer_hello(rid)
	end
	self:reconcile_done(present)
	if not no_save then
		self:flush()
	end
	return r
end

-- Busy flags and resyncs ---------------------------------------------------------

-- A guard whose callback never came back would read Busy for ever and park
-- every resync [code analysis 2026-10-22, item 2]: it expires instead.
local BUSY_MAX = 90

function owner:expire_stale_busy()
	for _, flag in ipairs(self.BUSY_FLAGS) do
		local since = self[flag .. "_since"]
		if self[flag] and since and os.time() - since > BUSY_MAX then
			self.ctx.log.warn("%s: %s stuck for %d s; cleared", self.TAG, flag, os.time() - since)
			self[flag] = false
		end
	end
end

-- The text an action gets while a job or a resync runs, else nil.
function owner:busy_text()
	self:expire_stale_busy()
	if self[self.BUSY_FLAGS[1]] then
		return string.format("Busy: %s; try again in a moment", self.WORDS.busy_job)
	elseif self.resyncing then
		return string.format("Busy: %s; try again in a moment", self.WORDS.busy_resync)
	end
	return nil
end

-- Hook: the values a successful resync adds to its done (scenes: the
-- /grouped_light items, for the zone lights' resync).
function owner.resync_extra() end

-- After every stream connect, and from a refresh: the module's fetch, the
-- absorb and its settle steps. done(ok, err, sent, ...). A resync asked for
-- while one (or the module's job) runs waits for it, and one more resync
-- then answers every caller that waited, each once (code analysis
-- 2026-10-22 F2, #47). A failed fetch reports done(false, err), or with
-- OPTIONS.settle_without_fetch still settles and reports done(false, err,
-- sent). Extra arguments go to the module's fetch_all.
function owner:resync(done, ...)
	done = done or function() end
	self:expire_stale_busy()
	if self.resyncing or self[self.BUSY_FLAGS[1]] then
		local pending = self.resync_pending or {}
		pending[#pending + 1] = done
		self.resync_pending = pending
		return
	end
	self.resyncing, self.resyncing_since = true, os.time()
	self:fetch_all(function(res, err)
		local sent = 0
		local ok, e = true, nil
		local settle = res ~= nil or self.OPTIONS.settle_without_fetch == true
		if settle then
			ok, e = pcall(function()
				if res ~= nil then
					self:absorb(res)
				end
				sent = self:settle("resync", not self.configured_once)
			end)
			if not ok then
				self.ctx.log.error("%s: resync failed: %s", self.TAG, tostring(e))
			end
		end
		self.resyncing = false
		if not ok then
			self:protect("resync done", done, false, tostring(e))
		elseif not settle then
			self:protect("resync done", done, false, err)
		elseif res == nil then
			self:protect("resync done", done, false, err, sent)
		else
			self:protect("resync done", done, true, nil, sent, self:resync_extra(res))
		end
		self:run_pending_resync()
	end, ...)
end

-- The resync the waiting callers asked for: one, whose done answers each of
-- them in the order they asked (each pcall-wrapped on its own).
function owner:run_pending_resync()
	local pending = self.resync_pending
	self.resync_pending = nil
	if pending and #pending > 0 then
		self:resync(function(...)
			for _, done in ipairs(pending) do
				self:protect("resync done", done, ...)
			end
		end)
	end
end

-- Rooms -----------------------------------------------------------------------

-- The room mapping of a Hue group: the lights' registry holds them all
-- (lights.lua reads its own).
function owner:room_mapping(group_rid)
	local l = self.ctx.lights
	if group_rid and l and l.reg then
		return l.reg:room_mapping(group_rid)
	end
	return nil
end

-- The Control4 room a record is added to when the owner names none: the
-- mapping of its group (room_group_of). Returns room_id, room_name or nil, reason.
function owner:default_room(record, rooms)
	local group_rid, label = self:room_group_of(record)
	if not group_rid then
		return nil, label
	end
	local mapping = self:room_mapping(group_rid)
	if not mapping or not mapping.c4_room_id then
		return nil, "Hue room " .. label .. " not mapped"
	end
	local name = rooms[mapping.c4_room_id]
	if not name then
		if next(rooms) == nil then
			-- The project is unknown right now; trust the mapping.
			return mapping.c4_room_id, mapping.c4_room_name or ("room " .. tostring(mapping.c4_room_id))
		end
		return nil, "Hue room " .. label .. " mapped to a Control4 room that no longer exists"
	end
	return mapping.c4_room_id, name
end

-- The room an add goes to: `room_id` (a number, or nil for the mapped room)
-- checked against the project's rooms. Returns room_id, room_name or nil, text.
function owner:room_for_add(record, room_id, rooms)
	room_id = util.positive(room_id)
	if room_id then
		local room_name = rooms[room_id]
		if room_name then
			return room_id, room_name
		end
		if next(rooms) ~= nil then
			return nil, string.format("Not added: Control4 room %d no longer exists", room_id)
		end
		return room_id, "room " .. tostring(room_id)
	end
	local id, why = self:default_room(record, rooms)
	if not id then
		return nil, string.format("Not added: %s: %s; pick a room, or Set Room Mapping first", self:add_label(record), why)
	end
	return id, why
end

-- Device creation ---------------------------------------------------------------

-- One-line recursive dump of a Lua value, keys sorted, for log.always.
function owner.dump(value, depth)
	depth = depth or 0
	if type(value) ~= "table" then
		if type(value) == "string" then
			-- Lua 5.1's %q writes a newline as backslash-newline; keep one line.
			return (string.format("%q", value):gsub("\\\n", "\\n"))
		end
		return tostring(value)
	end
	if depth > 6 then
		return "{...}"
	end
	local keys = {}
	for k in pairs(value) do
		keys[#keys + 1] = k
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local parts = {}
	for _, k in ipairs(keys) do
		parts[#parts + 1] = tostring(k) .. "=" .. owner.dump(value[k], depth + 1)
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

-- The AddDevice callback's second argument carries "the IDs of the Proxy
-- devices and the Protocol Driver's ID" for a proxy driver. [verified on OS
-- 3.4.2] It is the parsed-XML table C4:ParseXml produces: a node { Name,
-- Value, Attributes, ChildNodes } whose children named "protocol" and "proxy"
-- carry the ids as string Values, and deviceId equals the protocol id.
local ID_ROLES = { "protocol", "proxy" }

-- "protocol" or "proxy" when name is one of them (exact) or contains one.
local function role_of(name, exact)
	if type(name) ~= "string" then
		return nil
	end
	name = name:lower()
	for _, role in ipairs(ID_ROLES) do
		if (exact and name == role) or (not exact and name:find(role, 1, true)) then
			return role
		end
	end
	return nil
end

-- { protocol = number|nil, proxy = number|nil } from the callback info: the
-- node tree first (ChildNodes recursively, names case-insensitive), then for
-- other shapes any key whose name contains "protocol" or "proxy" with a
-- positive numeric value (the pre-3.4.2 guess). Empty for nil or a non-table.
function owner.ids_from(info)
	local ids = {}
	if type(info) ~= "table" then
		return ids
	end

	local function walk_nodes(node, depth)
		if type(node) ~= "table" or depth > 8 then
			return
		end
		local role = role_of(node.Name, true)
		if role and ids[role] == nil then
			ids[role] = util.positive(node.Value)
		end
		if type(node.ChildNodes) == "table" then
			for _, child in ipairs(node.ChildNodes) do
				walk_nodes(child, depth + 1)
			end
		end
	end

	local function walk_keys(t, depth)
		if type(t) ~= "table" or depth > 4 then
			return
		end
		for k, v in pairs(t) do
			local role = role_of(k, false)
			if role and ids[role] == nil then
				ids[role] = util.positive(v)
			end
		end
		for _, v in pairs(t) do
			if ids.protocol and ids.proxy then
				return
			end
			walk_keys(v, depth + 1)
		end
	end

	walk_nodes(info, 0)
	if not (ids.protocol and ids.proxy) then
		walk_keys(info, 0)
	end
	return ids
end

-- One AddDevice callback for `job` = { record, room_id, room_name }: the
-- callback's shape logged once per run (the only way to see it on an
-- unverified OS), the protocol id bound (before the registry learns of it),
-- the entry registered and saved at once (a failure half-way must never
-- leave a created device unregistered, which the next import would double).
-- Adds { record, device_id, room_name } to `created` and returns the device
-- id; nil with the record in `failed` when it did not work.
function owner:register_added(job, device_id, info, created, failed)
	local record = job.record
	if not self.device_info_logged then
		self.device_info_logged = true
		self.ctx.log.always("AddDevice callback for %s%s: deviceId=%s info=%s", self.WORDS.callback_kind,
			tostring(record.name), tostring(device_id), owner.dump(info))
	end
	device_id = tonumber(device_id)
	if not device_id or device_id <= 0 then
		self.ctx.log.error("%s: AddDevice failed for %s (deviceId %s); skipped", self.TAG, tostring(record.name),
			tostring(device_id))
		failed[#failed + 1] = record
		return nil
	end
	local ids = owner.ids_from(info)
	if ids.protocol and ids.protocol ~= device_id then
		self.ctx.log.always("AddDevice for %s: binding protocol id %d rather than deviceId %d", tostring(record.name),
			ids.protocol, device_id)
		device_id = ids.protocol
	end
	self.ctx.bind(self:bridge_id(), device_id)
	local fields = self:fields_of(record)
	fields.device_id = device_id
	fields.proxy_id = ids.proxy
	fields.created_room_id = job.room_id
	local entry, err = self.reg:add(record.rid, fields)
	if not entry then
		self.ctx.log.error("%s: AddDevice created device %d for %s but the registry refused it: %s", self.TAG,
			device_id, tostring(record.name), tostring(err))
		failed[#failed + 1] = record
		return nil
	end
	self:registered(device_id)
	self:save()
	created[#created + 1] = { record = record, device_id = device_id, room_name = job.room_name }
	return device_id
end

-- A device was created for `rid`: told its configuration and state; with
-- OPTIONS.gone_after_add, marked gone instead when its resource was deleted
-- in Hue while the AddDevice was pending (R6: the job's record was there
-- when the job was made).
function owner:added(rid)
	if self.OPTIONS.gone_after_add and self:record_of(rid) == nil then
		return self:mark_missing(rid, "resync", true)
	end
	return self:push(rid, "resync", true)
end

-- The name AddDevice gives the device of `record`: the module's creation
-- name as a display name (finding 8), or "Hue light" / "Hue scene" / "Hue
-- zone light" when nothing of it can be shown. The zone lights' own
-- create_device names its device here too.
function owner:new_device_name(record)
	local name = util.display_name(self:creation_name(record))
	if name == "" then
		return "Hue " .. self.WORDS.kind
	end
	return name
end

-- One AddDevice per job, one at a time (the next from the previous
-- callback, so Director adds one driver at a time), each registered by
-- register_added and told by added(). jobs = { { record, room_id, room_name }
-- ... }; finish(created, failed, err) with created = { { record, device_id,
-- room_name } ... }, failed = { record ... }, err the Lua error that stopped
-- the run early, if any. The caller owns the busy flag.
function owner:create(jobs, finish)
	local total, i, created, failed = #jobs, 0, {}, {}
	local add_next

	local function on_added(job, device_id, info)
		device_id = self:register_added(job, device_id, info, created, failed)
		if device_id then
			self.ctx.log.info("%s: added %s to %s (device %d, %d of %d)", self.TAG, tostring(job.record.name),
				tostring(job.room_name), device_id, i, total)
			self:added(job.record.rid)
		end
	end

	-- Each step is its own pcall so an error stops the run cleanly, with the
	-- caller told what happened.
	local function step()
		local ok, err = pcall(add_next)
		if not ok then
			self.ctx.log.error("%s: adding %s failed: %s", self.TAG, self.WORDS.created_noun, tostring(err))
			finish(created, failed, tostring(err))
		end
	end

	add_next = function()
		i = i + 1
		local job = jobs[i]
		if not job then
			return finish(created, failed)
		end
		local name = self:new_device_name(job.record)
		self.ctx.log.info("%s: adding %s to %s (%d of %d)", self.TAG, name, tostring(job.room_name), i, total)
		self.ctx.add_device(self.DEVICE_DRIVER, job.room_id, name, function(device_id, info)
			self:protect("register " .. tostring(name), on_added, job, device_id, info)
			step()
		end)
	end

	step()
end

-- Registry refresh (analysis R9) ------------------------------------------------

-- Bring entry `rid` up to `fields` (what its record supplies now; a nil
-- value is invisible to pairs) and clear each field named in `clears` that
-- the record no longer supplies, so a stale value cannot ride along for ever
-- (code analysis 2026-10-22 R9). True when something changed (the caller marks).
function owner:refresh_fields(rid, fields, clears)
	local entry = self.registry[rid]
	local delta = {}
	for k, v in pairs(fields) do
		if entry[k] ~= v then
			delta[k] = v
		end
	end
	if clears then  -- most calls have none (an event's refresh): no empty table each time
		for _, k in ipairs(clears) do
			if fields[k] == nil and entry[k] ~= nil then
				delta[k] = self.reg.CLEAR
			end
		end
	end
	if next(delta) then
		self.reg:update(rid, delta)
		return true
	end
	return false
end

-- Names (docs/import-design.md §6, [Q 10]) --------------------------------------

-- The Composer name a linked device should carry: its creation name, the
-- name the module would give the device today (#236: the lights too). Raw:
-- name_differences makes it a display name.
function owner:expected_name(_rid, entry)
	return self:creation_name(entry)
end

-- Hook: other names (raw) a linked device may carry without differing, nil
-- for none (lights: the light's own name; bridge/lights.lua says why).
function owner.agreeing_names() end

-- Whether `name` (a display name) agrees with `expected` or one of `others`.
local function agrees(name, expected, others)
	if name == expected then
		return true
	end
	for _, other in ipairs(others) do
		if name == other then
			return true
		end
	end
	return false
end

-- Linked entries whose Composer name differs from the expected name:
-- { rid, entry, current, expected }..., without the differences the owner has
-- accepted unless `include_dismissed` (Adopt Hue Names renames those too).
-- `expected` is a display name (finding 8): what Adopt Hue Names hands to
-- RenameDevice and Accept Names As They Are records.
--
-- The Composer name, the expected name and the accepted one are compared as
-- display names, because devices created before finding 8 carry the raw
-- name AddDevice was given, and name_dismissed holds the raw expected name
-- an older build accepted. Per case after the upgrade (decided 2026-10-25):
--   - a name display_name leaves unchanged: compared exactly as before. That
--     is every name a genuine bridge gives without control characters: Hue
--     allows 32 characters (docs/edge-cases-hue.md §6), and the longest name
--     built from them, a zone scene's "<Zone> <Scene>", has 65 of NAME_MAX;
--   - an older device under a raw name display_name changes (control
--     characters, or over NAME_MAX characters), its Hue name unchanged:
--     equal, so it is not listed and Adopt Hue Names leaves it alone. Listing
--     it would report a Hue rename that never happened; renaming it unasked
--     is automation. Its raw name stays until the owner renames it;
--   - a difference the owner accepted (name_dismissed raw or display): stays
--     accepted until the Hue name changes;
--   - a Hue rename, to a long name too: listed; Adopt Hue Names renames to
--     the display name, which then compares equal;
--   - an owner's rename: listed until accepted, as before, and renamed only
--     by the owner's own Adopt Hue Names click (which renames accepted
--     differences too, as always);
--   - a difference past NAME_MAX characters or in control characters only:
--     not listed, as no Composer name could show it;
--   - a Hue name with nothing to show (only control characters or blanks):
--     never listed or renamed, as there is nothing to rename to.
-- A name of agreeing_names counts as the expected one, for the Composer name
-- and for the accepted one alike (#236): a light whose Composer name is the
-- light's own name, or whose difference was accepted against it, is not
-- listed, renamed or accepted again when the expected name became the
-- device's creation name, so no rename is reported that did not happen in Hue.
function owner:name_differences(include_dismissed)
	local out = {}
	for _, rid in ipairs(self.reg:rids("linked")) do
		local entry = self.registry[rid]
		local expected = util.display_name(self:expected_name(rid, entry))
		if entry.name and entry.name ~= "" and expected ~= "" then
			local others = {}
			for _, name in ipairs(self:agreeing_names(rid, entry) or {}) do
				local other = util.display_name(name)
				if other ~= "" then
					others[#others + 1] = other
				end
			end
			if include_dismissed or not agrees(util.display_name(entry.name_dismissed), expected, others) then
				local current = self.project:display_name(entry.proxy_id or entry.device_id)
				if current and not agrees(util.display_name(current), expected, others) then
					out[#out + 1] = { rid = rid, entry = entry, current = current, expected = expected }
				end
			end
		end
	end
	return out
end

-- Adopt Hue Names: RenameDevice(proxy_id, expected name) for every linked
-- device whose Composer name differs [verified: API 22/_32]; entries without
-- a proxy id are listed, not renamed. Returns the report text.
function owner:adopt_hue_names()
	local busy = self:busy_text()
	if busy then
		return busy
	end
	local renamed, skipped = {}, {}
	for _, d in ipairs(self:name_differences(true)) do
		local entry, current, expected = d.entry, d.current, d.expected
		if not entry.proxy_id then
			skipped[#skipped + 1] = string.format("%s (device %d): no proxy id known", current, entry.device_id)
		else
			local ok, err = self.project:call("rename", entry.proxy_id, expected)
			if ok then
				renamed[#renamed + 1] = string.format("%s → %s (device %d)", current, expected, entry.device_id)
				if entry.name_dismissed ~= nil then
					self.reg:update(d.rid, { name_dismissed = self.reg.CLEAR })
					self:mark()
				end
			else
				skipped[#skipped + 1] = string.format("%s (device %d): rename failed: %s", current, entry.device_id,
					tostring(err))
			end
		end
	end
	self:flush()
	local text
	if #renamed == 0 and #skipped == 0 then
		text = "No Composer names differ from the " .. self.WORDS.hue_names
	else
		local parts = {}
		if #renamed > 0 then
			parts[#parts + 1] = string.format("Renamed %s: %s", util.plural(#renamed, self.WORDS.device_noun),
				table.concat(renamed, ", "))
		end
		if #skipped > 0 then
			parts[#parts + 1] = string.format("not renamed %d: %s", #skipped, table.concat(skipped, ", "))
		end
		text = table.concat(parts, "; ")
	end
	self.ctx.log.always("%s: %s", self.TAG, text)
	return text
end

-- Accept Names As They Are: every current difference is recorded as
-- accepted and leaves Attention until the Hue name changes again.
function owner:accept_names()
	local busy = self:busy_text()
	if busy then
		return busy
	end
	local accepted = {}
	for _, d in ipairs(self:name_differences()) do
		self.reg:update(d.rid, { name_dismissed = d.expected })
		self:mark()
		accepted[#accepted + 1] = string.format("%s (Hue: %s)", d.current, d.expected)
	end
	self:flush()
	local text
	if #accepted == 0 then
		text = "No Composer names differ from the " .. self.WORDS.hue_names
	else
		text = string.format("Accepted %s: %s", util.plural(#accepted, self.WORDS.name_difference),
			table.concat(accepted, ", "))
	end
	self.ctx.log.always("%s: %s", self.TAG, text)
	return text
end

-- Attention (docs/import-design.md §6) ------------------------------------------

-- The name an entry goes by in the Attention items and the re-link text
-- (the zone lights: its plain name).
function owner:entry_name(rid, entry)
	return self:entry_label(rid, entry)
end

-- The items every module has, appended to `items` (a new list when nil) in
-- this order: missing from the bridge, unbound devices, two devices
-- claiming one rid, name differences. Returns the list.
function owner:attention_items(items)
	items = items or {}
	local words = self.WORDS

	local gone = self.reg:rids("gone")
	if #gone > 0 then
		local names = {}
		for _, rid in ipairs(gone) do
			local entry = self.registry[rid]
			names[#names + 1] = string.format("%s (device %d, since %s)", self:entry_name(rid, entry), entry.device_id,
				util.date_of(entry.gone_since))
		end
		items[#items + 1] = string.format("%s missing from the bridge: %s (%s)", util.plural(#gone, words.kind),
			util.some(names, self.MAX_NAMED), words.relink_or_forget)
	end

	local unbound = self.reg:rids("unbound")
	if #unbound > 0 then
		local names = {}
		for _, rid in ipairs(unbound) do
			local entry = self.registry[rid]
			names[#names + 1] = string.format("%s (device %d)", self:entry_name(rid, entry), entry.device_id)
		end
		items[#items + 1] = string.format("%s: %s (bind it to this bridge in Composer, or %s)",
			util.plural(#unbound, words.unbound_kind), util.some(names, self.MAX_NAMED), words.forget_action)
	end

	local conflict_rids = {}
	for rid in pairs(self.conflicts) do
		conflict_rids[#conflict_rids + 1] = rid
	end
	table.sort(conflict_rids)
	for _, rid in ipairs(conflict_rids) do
		local c = self.conflicts[rid]
		items[#items + 1] = string.format("2 devices claim Hue %s: %d and %d (%s on one of them)", self:conflict_label(rid),
			c.holder, c.claimant, words.forget_action)
	end

	local diffs = self:name_differences()
	if #diffs > 0 then
		local names = {}
		for _, d in ipairs(diffs) do
			names[#names + 1] = string.format("%s is %s in Hue", d.current, d.expected)
		end
		items[#items + 1] = string.format("%d %s%s differ%s from the Composer names: %s "
			.. "(Adopt Hue Names or Accept Names As They Are)", #diffs, words.name_kind, #diffs == 1 and "" or "s",
			#diffs == 1 and "s" or "", util.some(names, self.MAX_NAMED))
	end

	return items
end

-- The items joined, or "None".
function owner:attention()
	local items = self:attention_items()
	if #items == 0 then
		return "None"
	end
	return table.concat(items, "; ")
end

-- Pickers (docs/import-design.md §8): { text, value } arrays, value a string -----------

local RELINK_STATES = { "gone", "unbound" }

-- Re-link's Device: the gone and unbound entries, "<device text>, gone since
-- 10-24)". An empty array when there are none and the module has no
-- placeholder (WORDS.no_relink).
function owner:picker_relink_devices()
	local list = {}
	for _, state in ipairs(RELINK_STATES) do
		for _, rid in ipairs(self.reg:rids(state)) do
			local entry = self.registry[rid]
			list[#list + 1] = { text = self:device_text(rid, entry, string.format(", %s since %s", state,
				util.short_date_of(entry[state .. "_since"])), true), value = tostring(entry.device_id) }
		end
	end
	if #list == 0 and self.WORDS.no_relink then
		return util.empty_list(self.WORDS.no_relink)
	end
	return list
end

-- Forget's Device: every entry, its state appended when not linked.
function owner:picker_forget_devices()
	local list = {}
	for _, rid in ipairs(self.reg:rids()) do
		local entry = self.registry[rid]
		local text = self:device_text(rid, entry)
		if entry.state ~= "linked" then
			text = text .. " " .. entry.state
		end
		list[#list + 1] = { text = text, value = tostring(entry.device_id) }
	end
	if #list == 0 and self.WORDS.no_forget then
		return util.empty_list(self.WORDS.no_forget)
	end
	return list
end

-- Re-link, forget, Link Devices (docs/import-design.md §6) ---------------------

-- Hooks of forget and relink: what a forget leaves behind beyond the shared
-- bookkeeping (scenes: the forgotten mark; lights: the once-per-run
-- foreign-entry warning), the name a forgotten device is told (scenes: a
-- time-based scene's base name), what a re-link adds to the new record's
-- fields (scenes: an ordinary scene drops the kind).
function owner.forgot() end

function owner.told_name(_self, entry)
	return entry.name
end

function owner.relink_fields() end

-- How Forget's text names the entry: "Desk Lamp #12 (device 1036)".
function owner:forget_label(rid, entry, device_id)
	return string.format("%s (device %d)", self:entry_label(rid, entry), device_id)
end

-- How a re-link's text names the new record (Link Devices' "by name" too).
function owner:relinked_label(record)
	return self:record_label(record)
end

-- Re-link: the entry keeps its device, proxy, programming and name and
-- swaps the rid (§1 rule 3); the device hears its new configuration and
-- state. Returns ok, text.
function owner:relink(device_id, new_rid)
	local busy = self:busy_text()
	if busy then
		return false, busy
	end
	device_id = util.positive(device_id)
	if not device_id or type(new_rid) ~= "string" or new_rid == "" then
		return false, "Not re-linked: pick a device and " .. self.WORDS.relink_target
	end
	local old_rid, entry = self.reg:by_device(device_id)
	if not old_rid then
		return false, string.format("Not re-linked: device %d is not a registered %s", device_id, self.WORDS.registered)
	end
	if self:foreign(device_id) then
		return false, string.format("Not re-linked: device %d is a zone light; Forget Light drops its stale light entry",
			device_id)
	end
	local holder = self.registry[new_rid]
	if holder then
		if holder.device_id == device_id then
			return false, string.format("Not re-linked: device %d is already linked to %s", device_id,
				self:entry_label(new_rid, holder))
		end
		return false, string.format("Not re-linked: %s is already linked to device %d", self:entry_label(new_rid, holder),
			holder.device_id)
	end
	local record = self:record_of(new_rid)
	if not record then
		return false, self:relink_refusal(device_id, new_rid)
	end
	local was = self:entry_name(old_rid, entry)
	local fields = self:fields_of(record)
	fields.name_dismissed = self.reg.CLEAR
	self:relink_fields(fields)
	local relinked, err = self.reg:relink(old_rid, new_rid, fields)
	if not relinked then
		return false, "Not re-linked: " .. tostring(err)
	end
	self:mark()
	self.last_configure[old_rid] = nil
	self:forget_sent(old_rid)
	self:forget_sent(new_rid)
	self.conflicts[old_rid], self.conflicts[new_rid] = nil, nil
	self:clear_conflicts_for(device_id)
	if self.OPTIONS.announced_follows_entry then
		-- The rid the device announced is the old one; its next hello says the
		-- new one (code analysis 2026-10-22 R5: a stale record made false conflicts).
		self.announced[device_id] = nil
	end
	self:push(new_rid, "resync", true)
	self:flush()
	local text = string.format("Re-linked device %d (was %s) to %s", device_id, was, self:relinked_label(record))
	self.ctx.log.always("%s: %s", self.TAG, text)
	return true, text
end

-- Forget: the entry goes, the device is unbound and told it was forgotten,
-- and stays in the project for the owner to delete; the rid is listed under
-- the add action again. A stale entry whose device another module owns
-- (lights: a zone light) only loses the entry. Returns ok, text.
function owner:forget(device_id)
	local busy = self:busy_text()
	if busy then
		return false, busy
	end
	device_id = util.positive(device_id)
	if not device_id then
		return false, "Not forgotten: pick a device first"
	end
	local rid, entry = self.reg:by_device(device_id)
	if not rid then
		return false, string.format("Not forgotten: device %d is not a registered %s", device_id, self.WORDS.registered)
	end
	local label = self:forget_label(rid, entry, device_id)
	local told = shown(self:told_name(entry))
	self.reg:forget(rid)
	self:mark()
	self:forgot(rid, entry, device_id, told)
	self.last_configure[rid] = nil
	self:forget_sent(rid)
	self.conflicts[rid] = nil
	self:clear_conflicts_for(device_id)
	self.announced[device_id] = nil
	local text
	if self:foreign(device_id) then
		-- The entry goes; the device, its binding and its own module are left alone.
		text = string.format("Forgot %s: dropped the stale light entry; the device stays bound as a zone light", label)
	else
		self:tell(device_id, self.MESSAGES.forgotten, { rid = rid, name = told })
		local ok, err = self.project:call("unbind", device_id)
		if not ok then
			self.ctx.log.warn("%s: unbind of device %d failed: %s", self.TAG, device_id, tostring(err))
		end
		text = string.format("Forgot %s: unbound and left in the project for you to delete%s", label,
			self.WORDS.forget_tail)
	end
	self:flush()
	self.ctx.log.always("%s: %s", self.TAG, text)
	return true, text
end

-- A device's own Forget action { rid?, device_id }. A device the registry
-- lacks is still told it is forgotten, so its Status explains what to do;
-- with OPTIONS.forget_request_mine_only (zone lights) the answer is nil
-- instead, and the coordinator asks the lights' module. Returns ok, text.
function owner:forget_request(params)
	params = params or {}
	local device_id = util.positive(params.device_id)
	if not device_id and type(params.rid) == "string" and self.registry[params.rid] then
		device_id = self.registry[params.rid].device_id
	end
	if self.OPTIONS.forget_request_mine_only then
		if not device_id or not self.reg:by_device(device_id) then
			return nil
		end
		return self:forget(device_id)
	end
	if not device_id then
		return false, string.format("Not forgotten: the %s named no device", self.WORDS.requester)
	end
	if not self.reg:by_device(device_id) then
		self:tell(device_id, self.MESSAGES.forgotten, { rid = params.rid, name = shown(params.name) })
		self.announced[device_id] = nil
		return false, string.format("Not forgotten: device %d is not a registered %s (told it so)", device_id,
			self.WORDS.registered)
	end
	return self:forget(device_id)
end

-- The unimported records (unimported_named, the module's own candidate rule)
-- whose names match one of `names`, as util.name_key compares them (display
-- names, trimmed and case-insensitive): a device created under the display
-- name of a long Hue name matches that name (finding 8). `wanted` is keyed
-- by name_key; the modules look their records' names up the same way.
function owner:match_unimported_by_name(names)
	local wanted = {}
	for _, name in ipairs(names) do
		local key = util.name_key(name)
		if key ~= "" then
			wanted[key] = true
		end
	end
	return self:unimported_named(wanted)
end

-- Hooks of Link Devices: what a device announced (scenes: or what Forget
-- Scene remembered of it), the rid of that (zone lights: of a group
-- device's hello only), and what an adoption by that rid takes from it
-- (zone lights: its name, else the Composer name).
function owner:link_hello(id)
	return self.announced[id] or {}
end

function owner.link_rid(_self, hello)
	return hello.rid
end

function owner.link_adopt_hello(_self, hello)
	return hello
end

-- Link Devices: every bound device of this module (link_candidates) the
-- registry lacks is adopted by the rid it announced, else by an exact,
-- unique name match (Composer name or announced name) against the
-- unimported records. Two unregistered devices with one Composer name
-- cannot both be the record of that name; neither is matched by name.
-- `skip_ids` goes to link_candidates. Returns the report text.
function owner:link_devices(skip_ids)
	local busy = self:busy_text()
	if busy then
		return busy
	end
	local words = self.WORDS
	local bound, why = self.project:bound_set()
	if not bound then
		if why ~= "unknown" then
			return "Not linked: the bound-device lookup failed (see the Lua output)"
		end
		bound = {}  -- unknown (nil answered: nothing bound, API 32/_3): nothing to adopt either way
	end
	local ids, total = self:link_candidates(bound, skip_ids)
	table.sort(ids)
	if #ids == 0 then
		if total == 0 then
			return string.format("No %s are bound to this bridge", words.link_noun)
		end
		return string.format("All %d bound %s are registered", total, words.link_noun)
	end

	local names, shared = {}, {}
	for _, id in ipairs(ids) do
		names[id] = self.project:display_name(id)
		if names[id] then
			local key = util.name_key(names[id])
			shared[key] = (shared[key] or 0) + 1
		end
	end

	local linked, problems = {}, {}
	for _, id in ipairs(ids) do
		local hello = self:link_hello(id)
		local composer = names[id] or ("device " .. tostring(id))
		local rid = self:link_rid(hello)
		local who = string.format("%s (device %d)", composer, id)
		if rid and self.registry[rid] then
			local holder = self.registry[rid]
			self.conflicts[rid] = { holder = holder.device_id, claimant = id }
			problems[#problems + 1] = string.format("%s announces %s, which device %d holds (%s on one of them)", who,
				self:entry_label(rid, holder), holder.device_id, words.forget_action)
		elseif rid then
			local entry = self:adopt(id, rid, self:link_adopt_hello(hello, names[id]),
				"from its own persisted rid (Link Devices)")
			if entry then
				local label, gone = self:linked_label(rid, entry)
				linked[#linked + 1] = string.format("%s to %s by its rid%s", who, label, gone)
				self:answer_hello(rid)
			else
				problems[#problems + 1] = string.format("%s: could not register %s (see the Lua output)", who, rid)
			end
		elseif names[id] and shared[util.name_key(names[id])] > 1 then
			problems[#problems + 1] = string.format("%s: %d bound devices share that name; rename one in Composer and run "
				.. "Link Devices again", who, shared[util.name_key(names[id])])
		else
			local matches = self:match_unimported_by_name({ composer, hello.name })
			if #matches == 1 then
				local record = matches[1]
				local entry = self:adopt(id, record.rid, hello, "by its name (Link Devices)")
				if entry then
					linked[#linked + 1] = string.format("%s to %s by name", who, self:record_label(record))
					self:answer_hello(record.rid)
				else
					problems[#problems + 1] = string.format("%s: could not register %s (see the Lua output)", who, record.rid)
				end
			elseif #matches > 1 then
				problems[#problems + 1] = string.format("%s: %d unimported %s have that name; rename the device in Composer "
					.. "to one %s exact name and run Link Devices again", who, #matches, words.link_many, words.link_one)
			else
				problems[#problems + 1] = string.format("%s: no unimported %s has that name; rename the device in Composer "
					.. "to the %s exact name%s and run Link Devices again", who, words.link_none, words.link_one,
					words.link_hint or "")
			end
		end
	end
	self:flush()
	local parts = {}
	if #linked > 0 then
		parts[#parts + 1] = string.format("Linked %s: %s", util.plural(#linked, words.device_noun),
			table.concat(linked, ", "))
	end
	if #problems > 0 then
		parts[#parts + 1] = string.format("not linked %d: %s", #problems, table.concat(problems, "; "))
	end
	local text = table.concat(parts, "; ")
	self.ctx.log.always("%s: %s", self.TAG, text)
	return text
end

return owner
