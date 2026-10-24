# Control4-side edge cases for the lights, rooms and scenes design

> **Historical research (2026-10-21)**, written before the import-ui and scenes features; "today" and `[code: …]` describe that day's code. The decisions are `docs/import-design.md` (§1–§10) and `docs/scenes-design.md`; the present is in `docs/status.md`.

What Director and Composer do to our devices behind the driver's back, and
what the driver can know about it. Written for the next design round: lights
added one at a time, moved between rooms, replaced, removed; a "pick a
detected light and a Control4 room, add it" flow with a Hue-room -> C4-room
mapping; and one Control4 switch device per Hue scene. Read with
`docs/lights-design.md` (the two-driver contract) and `docs/design.md`
("Driver structure", "Lights", "Lights: verified on hardware").

Markers on every claim:

- **[verified: API x/_y]** = `~/c4-tools/reference/docs-driverworks-api/source/includes/<x>/<_y>.md`
- **[verified: FUND x/_y]** = `~/c4-tools/reference/docs-driverworks-fundamentals/source/includes/<x>/<_y>.md`
- **[verified: PP x/_y]** = Snap One `docs-driverworks-proxyprotocol/source/includes/<x>/<_y>.md`
  (fetched from GitHub 2026-10-21 into the scratchpad; not vendored, Snap One terms)
- **[verified: sample idc_controller|idc_client|dynamic_lists]** = the SDK sample drivers
- **[verified: lib handlers.lua|lib.lua]** = `~/c4-tools/drivers-common-public/global/`
- **[verified: hardware]** = recorded in `docs/design.md` "Lights: verified on hardware"
- **[code: file]** = what our driver does today
- **[assumed]** = not documented; our best reading, to be probed
- **[community: source]** = Control4 dealer help (docs.control4.com) or forums
- **[silent]** = the docs say nothing; listed so it is tested, not guessed

Vocabulary: *protocol id* = the Lua driver's device id (`C4:GetDeviceID()`);
*proxy id* = the light_v2 proxy device Composer shows and Navigators address
(protocol id + 1 on this controller [verified: hardware]); *rid* = Hue
resource id; *registry* = the bridge's persisted `rid -> { device_id, proxy_id,
name, model, caps }` [code: bridge/lights.lua].

Each section opens with a summary table (case, how the driver learns, the
reaction in one line) and then gives the detail per case: what
Director/Composer does, how the driver learns, the sensible reaction, and
what to test on the controller through the dev loop.

## 0. The facts everything below rests on

| Fact | Status |
| --- | --- |
| `C4:AddDevice(driver, roomId?, name?, cb)`; `cb(deviceId, tDeviceInfo)`, `deviceId` 0 on failure; room defaults to the calling driver's room; 3.2.0+; the API doc reserves it for user-initiated use | [verified: API 9/_0.1] |
| On OS 3.4.2 `deviceId` is the protocol id and `tDeviceInfo` is a parsed-XML node tree with children `protocol` and `proxy` | [verified: hardware] |
| `C4:Bind(providerDev, providerBinding, consumerDev, consumerBinding, class)`; `C4:Unbind(consumerDev, consumerBinding)`; 2.9.0+ | [verified: API 9/_1, 9/_19] |
| `OnBindingChanged(idBinding, strClass, bIsBound, otherDeviceID, otherBindingID)`; only for control-type bindings, not AV/room; the last two params were "missing" from the docs before OS 3 | [verified: API 9/_12, API 3_whats_new/_20] |
| `OnDriverDestroyed(DIT)`: on delete, update, or Director shutdown; `DIT_UPDATING` / `DIT_LOADED`; timers are killed. `OnDriverRemovedFromProject()`: called when the driver is removed from the project | [verified: API 22/_24, 22/_26] |
| `OnDriverInit`/`OnDriverLateInit(DIT)`: `DIT_ADDING`, `DIT_STARTUP`, `DIT_UPDATING` (3.2.0+). At project load every driver's `OnDriverInit` runs, then every driver's `OnDriverLateInit`; bindings are complete only at late init | [verified: API 22/_25, 22/_25.1; FUND 28/_3] |
| Not safe before `OnDriverLateInit`: `GetBoundConsumerDevices`, `GetBoundProviderDevice`, `RoomGetId`, `SendToDevice`, `SendToProxy`, `UpdateProperty`, `UpdatePropertyList`, `SetPropertyAttribs`, `RenameDevice`, `GetDevices*`, `GetProjectItems`. Safe: `PersistGetValue`/`PersistSetValue`, `AddVariable`, `ParseXml` | [verified: API 22/_25.2; FUND 28/_2] |
| `PersistSetValue` writes on its own thread that starts just before late init; a `PersistGetValue` right after a set may miss it; an empty value does not delete (use `PersistDeleteValue`); tables allowed | [verified: API 26.5/_3, 26.5/_4] |
| The persistence store is per device id: delete + re-add loses it, update-in-place keeps it | [verified: hardware, design.md "Storage"] |
| `C4:SendToDevice`: delivery is not confirmed to the sender | [verified: API 32/_19] |
| `GetBoundConsumerDevices(id, binding)` -> nil or `{ [deviceId] = name }`; `GetBoundProviderDevice` is documented with the same return text but its example prints a number | [verified: API 32/_3, 32/_4] |
| `GetBoundConsumerDevices(protocolId, 5001)` finds the light's proxy; `GetBoundProviderDevice(protocolId, 5001)` returned the protocol id itself | [verified: hardware] |
| `idc_controller` treats `GetBoundProviderDevice(clientId, 5001)` as the proxy id, the opposite of what we saw | [verified: sample idc_controller `CheckBindings`] |
| `C4:RenameDevice(proxyId or deviceId, name)`: "ComposerPro shows the Proxy Device and not the protocol driver's id ... probably not the id to be changed"; refreshes the project; late init only. `C4:GetDeviceDisplayName(id)` returns the Composer name | [verified: API 22/_32, 32/_6] |
| `C4:RoomGetId()` = room containing *this* driver; `C4:GetRoomID(proxyId)` for another device is 4.1.0+ only | [verified: API 22/_33, 9/_9.5] |
| `C4:GetDevices({C4iNames=...} or {DeviceIds=...}, locationFilter)` returns `roomId`, `roomName`, `driverFileName`, `deviceName`, plus `proxies`/`protocol` sub-tables; 2.10+. `C4:GetDevicesByC4iName("hue_light.c4z")` -> table of ids | [verified: API 22/_9, 25/_4] |
| `C4:GetProjectHierarchy(location?)` -> table keyed by location id with each location's children, name and type; **type values are not listed** | [verified: API 22/_15] [silent: values] |
| Location types used by `AddLocation`: SITE, BUILDING, FLOOR, ROOM; the project root id is 1 | [verified: API 9/_0.2] |
| System events: `C4:RegisterSystemEvent(C4SystemEvents["Name"], 0)` + `OnSystemEvent(data)`; `OnItemAdded`, `OnItemRemoved`, `OnItemNameChanged` exist (OnProjectChanged deprecated in 2.10); `OnPIP` fires when "bindings, device names, or device media has changed" | [verified: API 7/_1, 7/_4.2, 7/_5.5] |
| Event ids: 5 OnProjectLoaded, 6 OnPIP, 7 OnItemAdded, 8 OnItemNameChanged, 11 OnItemRemoved, 12 OnItemMoved, 15 OnBindingAdded, 16 OnBindingRemoved, 92 OnDeviceUserInitiatedRemove, 123 OnProjectRestored; `data` is an XML string with a `name="..."` attribute; **payload fields are undocumented** | [verified: lib handlers.lua list and `OnSystemEvent` parser] [silent: payload] |
| Light_v2 `ONLINE_CHANGED { STATE }`: "the proxy starts 'online' ... UI functionality will be disabled if the light is offline"; `LIGHT_BRIGHTNESS_CHANGED` "should always be sent ... when the driver starts and/or when the hardware comes online" | [verified: PP 66.5/_15, 66.5/_10.2] |
| `DYNAMIC_CAPABILITIES_CHANGED` can flip `dimmer` true/false at runtime (dimmer vs switch) and `supports_target`; `supports_color` and `supports_color_correlated_temperature` must change in one notify | [verified: PP 66.5/_8, 63/_30, 63/_31] |
| ALS: with `reduced_als_support` the agent sends `SET_BRIGHTNESS_TARGET`, `SET_COLOR_TARGET`, `SET_BRIGHTNESS_STOP`, `SET_COLOR_STOP`; `advanced_scene_support` needs PUSH_SCENE etc.; both false (ours) = not eligible for scenes | [verified: PP 63/22, 62.1/_1.2] [code: hue_light/driver.xml has both false] |
| Driver update keeps configuration; never add/remove a `<proxy>` or change a connection's type/definition in an update (project corruption); adding connections and properties is fine; keep events, variables, commands | [verified: FUND 14/_2] |
| Composer right-click on a device: Rename, Edit Driver, Export Driver, Update Driver, Delete; "If the driver connection IDs change, the driver will need to be connected again." No "Replace Driver": the documented way to a new driver is delete, re-add, reconfigure connections and programming | [community: docs.control4.com Composer Pro menu options; "Using a new device driver in an existing project"] |

## 1. Device lifecycle in Composer

| # | Case | Driver learns via | Reaction |
| --- | --- | --- | --- |
| 1.1 | Dealer deletes a hue_light | light callbacks; bridge: maybe `OnBindingChanged`, else nothing | GOODBYE message + reconcile; tombstone, never auto re-add |
| 1.2 | Stale registry entry | reconcile only | prune against bound/present devices at late init and after imports |
| 1.3 | SendToDevice to a dead id | nothing | harmless but wasteful; prune (1.2) |
| 1.4 | Light moved to another room | nothing; `OnItemMoved` if registered | room mapping is a creation-time default only |
| 1.5 | Light renamed in Composer | nothing; `OnItemNameChanged` if registered | Composer name wins; explicit rename action only |
| 1.6 | "Replace device" / copy-paste | fresh `DIT_ADDING` device, no rid | C4 device is the identity; rid is re-pointable; adopt bare devices |
| 1.7 | Bridge driver deleted | lights: `OnBindingChanged` false | lights show unbound/offline and keep their rid |
| 1.8 | Bridge re-added | nothing (new id, empty store) | recovery import rebuilds registry from the lights' rids |
| 1.9 | AddDevice during an import | `importing` guard | one serial creation queue for every path |
| 1.10 | AddDevice returns 0 | callback `deviceId == 0` | skip, continue, name the likely cause |
| 1.11 | Device id ranges and reuse | n/a | ids are a cache keyed by rid; never derive proxy = protocol + 1 |

**1.1 Dealer deletes a hue_light device**
- Director/Composer: the light driver gets `OnDriverRemovedFromProject` then `OnDriverDestroyed("DIT_LOADED")` [verified: API 22/_24, 22/_26]; its bindings are removed. Whether the bridge gets `OnBindingChanged(1, "HUE_BRIDGE", false, lightId, 1)` is [silent]; plausible, since it is a control binding and that is the callback's purpose [assumed]. The bridge has **no** `OnBindingChanged` handler today [code: hue_bridge/driver.lua].
- Learns: light, the callbacks above. Bridge: `OnBindingChanged` false if it fires; `OnItemRemoved` / `OnDeviceUserInitiatedRemove` system events (payload unknown); otherwise nothing, because `SendToDevice` is unconfirmed by design [verified: API 32/_19].
- Reaction: light, in `OnDriverRemovedFromProject`, sends `HUE_GOODBYE {rid}` to its bridge (the sender still exists at that point). Bridge: on GOODBYE, on `OnBindingChanged` false, and on reconcile (1.2) drop the registry entry, keep a tombstone `{rid, name}` so the picker can say "was imported, deleted", stop fan-out to that id. Never re-create the light on its own.
- Test: delete one test light in Composer; watch the bridge log for `OnBindingChanged`, GOODBYE and system events; confirm the registry shrinks and HUE_STATE for that rid stops; run Import Lights and confirm it does **not** silently re-add (today it would: "not in registry" means "new" [code: lights.lua `import_fetched`]).

**1.2 Stale registry entry (deleted light not noticed)**
- Director/Composer: nothing; the registry keeps a `device_id` that no longer exists.
- Learns: only by reconciliation: `GetBoundConsumerDevices(bridgeId, 1)` [verified: API 32/_3] or `GetDevicesByC4iName("hue_light.c4z")` [verified: API 25/_4; sample idc_controller `AddClientDrivers`].
- Reaction: reconcile at late init (+5 s, as the sample does), after every import, and from `Lights Report`; prune entries whose id is neither bound nor a hue_light device; log loudly.
- Test: `Lights Report` after a delete without a restart; then restart Director and check the registry count again.

**1.3 `SendToDevice` to a deleted or unknown id**
- Director/Composer: [silent]; expected to be dropped without an error [assumed].
- Learns: nothing.
- Reaction: harmless, but every stream event for that rid is wasted work and log noise; prune (1.2).
- Test: a dev action that calls `C4:SendToDevice(99999, "HUE_STATE", {})`; look for an error line.

**1.4 Light moved to another room**
- Director/Composer: the device's location changes; `RoomGetId()` inside the light changes; bindings are untouched (Composer's help only asks for connection work when the *system's* location changes [community: docs.control4.com "Updating connections when a location changes"]); programming untouched [assumed].
- Learns: nothing is called; `RoomGetId()` on demand in the light; in the bridge `OnItemMoved` (id 12) if registered [verified: lib handlers.lua list] [assumed it fires for devices], or `C4:GetDevices({DeviceIds=...})` for `roomId` [verified: API 22/_9].
- Reaction: the C4 room is the dealer's choice. The Hue-room -> C4-room mapping is a **default for new devices only**, never applied to existing ones. Anything showing a light's C4 room reads it on demand, no caching.
- Test: move a test light between rooms; log `RoomGetId()` from the light (dev HUE_LOG) and `GetDevices` from the bridge; see whether `OnItemMoved` arrives and what its XML carries.

**1.5 Light renamed in Composer**
- Director/Composer: Composer renames the **proxy** device; the protocol device keeps its name unless renamed too [verified: API 22/_32 note].
- Learns: nothing is called; `OnItemNameChanged` (id 8) if registered [assumed it carries the id]; `GetDeviceDisplayName(proxyId)` on demand [verified: API 32/_6].
- Reaction: Composer name wins for the C4 device (today's rule: a Hue rename is logged, Composer untouched [code: lights.lua `take_name`]). Keep the Hue name in `Hue Name` so drift is visible. Offer an explicit "Rename to Hue names" action rather than automatic renames: each `RenameDevice` refreshes the whole project [verified: API 22/_32], and the sample renames its clients' proxy ids [verified: sample idc_client `EC.AddClient`].
- Test: rename a light in Composer and in the Hue app; check neither side fights; run the future rename action on one light and confirm the proxy, not the protocol, is renamed.

**1.6 "Replace device" or copy/paste of a device**
- Director/Composer: no Replace Driver for third-party drivers; replacing means delete, add, rebind, reprogram [community: docs.control4.com]. Copy/paste of devices is not among the right-click options [community]. "Replace Legacy Control4 Device" exists for Control4 hardware only [community: search summary, unverified].
- Learns: as 1.1, plus a fresh `DIT_ADDING` device with empty persistence (no `hue_rid`).
- Reaction: design the **C4 device as the stable identity**; a light's rid is re-pointable. Give the light a `Hue Light` DYNAMIC_LIST (unregistered rids, supplied by the bridge) so a dealer can adopt a bare hue_light; and give the bridge an "adopt unbound Hue Light devices" step in import, as `idc_controller` reuses `UnconfiguredClientDrivers` with `RenameDevice` instead of adding [verified: sample].
- Test: add a hue_light by hand (bare, unbound); confirm Status "Not bound to a Hue Bridge"; bind it in Connections; today HELLO without rid gets no answer [code: lights.lua `hello`]; later the adopt path should fill it.

**1.7 Bridge driver deleted**
- Director/Composer: every light's binding 1 is unbound; lights get `OnBindingChanged(1, class, false, ...)` [assumed: control binding]; the bridge gets `OnDriverRemovedFromProject` and `OnDriverDestroyed` [verified: API 22/_24, 22/_26]; pairing and registry go with its id [verified: hardware].
- Learns: light, `OnBindingChanged` false (today: `bridge = nil`, Status "Not bound to a Hue Bridge", ONLINE false [code: hue_light/driver.lua]).
- Reaction: lights keep `hue_rid`, name and model in their own persistence (rid is kept today; add name/model). Show `Online = Offline`, drop proxy commands with that reason. Programming on the lights survives.
- Test: delete the bridge on a test project; confirm every light shows the unbound status and a disabled tile; continue with 1.8.

**1.8 Bridge re-added**
- Director/Composer: new protocol id, empty persistence: no key, no registry; lights are **not** rebound.
- Learns: nothing.
- Reaction: pair again, then a **recovery import**: `GetDevicesByC4iName("hue_light.c4z")` [verified: API 25/_4]; for each unbound device ask `HUE_WHOAMI` -> `HUE_IAM {rid, name}`; `C4:Bind`; rebuild the registry from the lights' own rids. This is why each light keeps its rid itself [code: `hue_rid`]. Dealers must still prefer Update Driver in place [verified: hardware; composer-checklist A.2].
- Test: after 1.7, re-add, pair, run import; expect 0 new devices, all old devices rebound, registry count restored.

**1.9 AddDevice while a previous import is in progress**
- Director/Composer: Director adds one driver at a time only because we chain from the callback [code: lights.lua `add_next`]; a second flow would interleave.
- Learns: the `importing` guard answers "Import already running" [code].
- Reaction: one serial creation queue for *all* device creation (import, single add, scene devices, mirror-rooms); show the queue length in `Lights`.
- Test: trigger Import Lights twice through the dev loop; the second must report "already running"; later queue an "add one light" during an import and confirm it runs afterwards.

**1.10 AddDevice returns 0**
- Director/Composer: failure; causes undocumented [silent]. Plausible: `hue_light.c4z` not in the controller's driver store (Composer "Add or update drivers" puts it there [composer-checklist A.1] [assumed]), bad room id, a rejected name, project locked [assumed].
- Learns: callback with `deviceId == 0` [verified: API 9/_0.1].
- Reaction: log, do not register, continue (today [code: `on_added`]); when every add fails, say "driver hue_light.c4z missing on controller?" in `Lights`.
- Test: call AddDevice with a misspelled driver name from a dev action; confirm 0 and a clean import report.

**1.11 Device id ranges and reuse after deletion**
- Director/Composer: ids are integers, project root = 1 [verified: API 9/_0.2]; our 47 lights got consecutive protocol/proxy pairs [verified: hardware]. Reuse after deletion: [silent]; assume ids are never reused within a project [assumed], never rely on it.
- Reaction: key by rid on the Hue side; device ids are a cache that reconciliation (1.2) repairs; store the proxy id AddDevice reported [code: `proxy_id`], never derive it.
- Test: delete a light, add another; compare ids in the AddDevice callback log.

## 2. Rooms in Composer

| # | Case | Driver learns via | Reaction |
| --- | --- | --- | --- |
| 2.1 | Room renamed | `OnItemNameChanged` if registered; hierarchy on demand | map by room id, resolve names when shown |
| 2.2 | Room deleted | `OnItemRemoved`; mapping id missing from the hierarchy | validate at use; fall back to the bridge's room; keep the stale line visible |
| 2.3 | Room added | `OnItemAdded`; picker rebuilt on demand | nothing cached |
| 2.4 | Site/building/floor levels | walk `GetProjectHierarchy`; or room devices | use `GetDevicesByC4iName("roomdevice.c4i")` for the room list |
| 2.5 | Room ids after restore | n/a | same validation as 2.2 |
| 2.6 | Hue room/zone -> C4 room | n/a | persist by ids, apply at creation only; optional mirror action |

**2.1 Room renamed**
- Director/Composer: the location's name changes; its id is the key of `GetProjectHierarchy` and stays [verified: API 22/_15] [assumed stable].
- Learns: `OnItemNameChanged` (8) if registered [assumed for rooms]; `GetProjectHierarchy()` / `GetDevices` on demand.
- Reaction: map by room id, show names only, never persist a name as a key.
- Test: rename the bridge's room; re-run the future room picker; the mapping entry still resolves.

**2.2 Room deleted**
- Director/Composer: [silent] on the devices inside; Composer normally asks to move them first [assumed]. `RoomGetId()` for a device whose room is gone: [silent].
- Learns: `OnItemRemoved` (11) if registered; a mapped id missing from `GetProjectHierarchy()`.
- Reaction: validate every mapped room id at use; fall back to the bridge's room (`C4:RoomGetId()`) and say so in `Lights`; keep the stale mapping line visible ("Kitchen -> (room 38 deleted)").
- Test: delete an empty test room that a mapping points at; run the add-light flow; confirm fallback and message.

**2.3 Room added**
- Director/Composer: a new location id.
- Learns: `OnItemAdded` (7) if registered; the picker list is rebuilt when Composer asks (CUSTOM_SELECT functions run on demand [verified: FUND 15/_4]).
- Reaction: nothing to cache.
- Test: add a room; open the picker; it appears without a Director restart.

**2.4 Floors and buildings in the hierarchy**
- Director/Composer: `GetProjectHierarchy()` returns the whole tree, location id -> { children, name, type } [verified: API 22/_15]; the `type` strings are [silent], likely the SITE/BUILDING/FLOOR/ROOM set `AddLocation` uses [verified: API 9/_0.2] [assumed same spelling, perhaps lower case].
- Learns: walk the tree recursively and keep room-typed nodes.
- Reaction: a type-free alternative: `C4:GetDevicesByC4iName("roomdevice.c4i")` -> `{ [roomId] = roomName }` [verified: lib lib.lua `HideProxyInAllRooms`; undocumented in the API]. Use it for the room list and `GetProjectHierarchy` only for floor names in picker text.
- Test: dev action dumping `GetProjectHierarchy()` and `GetDevicesByC4iName("roomdevice.c4i")` with `lights.dump`; record the real `type` strings in design.md.

**2.5 Room ids after a project restore**
- Director/Composer: Load Project clears the controller and loads the saved project [community: docs.control4.com Back Up / Load Project]; ids come from the saved project, so they should be unchanged [assumed].
- Reaction: 2.2's validation covers the case where they are not.
- Test: part of 3.6.

**2.6 Hue room/zone -> C4 room mapping**
- Hue side: rooms are `/clip/v2/resource/room` with `children` device rids; zones group lights across rooms; a light is in one room and any number of zones [verified: Hue CLIP v2 core concepts, as cited in design.md].
- Reaction: persist `{ [hue_room_rid] = c4_room_id }` in the bridge; apply only at creation (1.4); unmapped Hue room -> bridge's room. A "Mirror Hue rooms" action may create missing C4 rooms with `C4:AddLocation(floorId, name, "ROOM")` [verified: API 9/_0.2] only when asked: AddLocation is 3.2.0+ and user-initiated like AddDevice.
- Test: set one mapping, add one light, confirm it lands in the mapped room.

## 3. Director lifecycle

| # | Case | Driver learns via | Reaction |
| --- | --- | --- | --- |
| 3.1 | Light late init before bridge late init | lost HELLO (error in dispatch) | `configure_all` covers it; queue early HELLOs |
| 3.2 | Bridge late init before light late init | CONFIGURE before the light's late init | light buffers until `late_init_done` |
| 3.3 | Registry vs light's persisted rid disagree | HELLO rid vs registry | registry arbitrates; re-point if the other device is gone |
| 3.4 | Driver update in place | `DIT_UPDATING` | keep `PersistSetValue`; never touch proxy/binding types |
| 3.5 | Reinstall after deletion | `DIT_ADDING`, empty store | 1.6 / 1.8 |
| 3.6 | Project restore from backup | `OnProjectRestored`, `DIT_STARTUP` | recovery import; mirror registry into `PersistData` |
| 3.7 | Controller replacement | `DIT_STARTUP` on the new box | expect to re-pair; recovery import |
| 3.8 | OS upgrade 3.x -> 4.x | n/a | nothing we use changes; optional 4.x helpers behind a version check |

**3.1 Restart ordering: a light's late init before the bridge's**
- Director/Composer: all `OnDriverInit` first, then all `OnDriverLateInit` in an unspecified order [verified: FUND 28/_3]. A light's `HUE_HELLO` can reach the bridge before `state.lights` exists: the handler errors inside dispatch's pcall and the hello is lost [code: hue_bridge/driver.lua `HUE_HELLO`; common/dispatch.lua].
- Reaction: it self-heals today because `configure_all()` at the bridge's late init sends `HUE_CONFIGURE` to every registered light from persisted caps [code: lights.lua]. Make it explicit: queue hellos that arrive before late init and answer them after `configure_all`; or have the light retry HELLO once after 10 s without a CONFIGURE.
- Test: restart Director; count error lines for HUE_HELLO in the bridge log; confirm every light ends configured (Lights Report, Navigator).

**3.2 The bridge's late init before a light's**
- Director/Composer: `HUE_CONFIGURE` arrives while the light is pre-late-init; its handler calls `UpdateProperty` and `SendToProxy`, both not before OnDriverLateInit (paraphrased) [verified: API 22/_25.2]; delivery of `ExecuteCommand` that early is [assumed].
- Reaction: the light buffers messages until `late_init_done`, then applies the last CONFIGURE/STATE; its own HELLO fetches a fresh copy anyway.
- Test: restart with debug on; look in a light's Lua output for a CONFIGURE before its late-init line.

**3.3 Bridge registry vs a light's persisted rid**
- Director/Composer: both persist: registry rid -> id in the bridge, `hue_rid` in the light [code]; they can disagree after 1.6 or 1.8.
- Learns: a HELLO with rid X from device D where `registry[X].device_id ~= D`.
- Reaction: the light's rid is a claim, the registry is the arbiter: if registry[X]'s device is gone or unbound, re-point the entry to D (recovery); if both exist, refuse and flag "duplicate light" in both Statuses.
- Test: set a wrong `hue_rid` on one light through a dev action, restart, watch the resolution.

**3.4 Driver update in place**
- Director/Composer: `OnDriverDestroyed("DIT_UPDATING")`, then `OnDriverInit`/`LateInit("DIT_UPDATING")` [verified: FUND 28/_3]; properties, `PersistSetValue` values and bindings survive [verified: FUND 14/_2; hardware]; `PersistData` too [verified: FUND 24/_1]. A LuaJIT load failure falls back to PUC Lua with properties lost for the moment (paraphrased) [verified: FUND 14/_2].
- Reaction: keep `PersistSetValue` (immediate "state database") over `PersistData` (round-robin save) [verified: API 22/_5]; never remove the light_v2 `<proxy>` or change binding 1's type in a future hue_light; add bindings only [verified: FUND 14/_2]; log the DIT at late init.
- Test: update both drivers in place; `Lights` count and pairing unchanged; every light re-hellos.

**3.5 Reinstall after deletion**: new id, empty persistence [verified: hardware]; `OnDriverLateInit("DIT_ADDING")` with no registry; see 1.8 (bridge) and 1.6 (light).

**3.6 Project restore from backup**
- Director/Composer: the backup is the project file (media/personal info optional) and Load Project replaces the controller's project [community: docs.control4.com]. `PersistData` survives a project save or backup, per the fundamentals (paraphrased) [verified: FUND 24/_1]; whether the `PersistSetValue` state database is in the backup is [silent]; sandbox files (SQLite) are **not** backed up [verified: FUND 3_whats_new/_17].
- Learns: `OnProjectRestored` (123) / `OnProjectLoaded` (5) [verified: lib list]; `DIT_STARTUP`.
- Reaction: keep the recovery import (1.8) cheap enough to run after any restore; keep re-pairing one click (`Pair Bridge`); consider mirroring the registry into `PersistData`, the store documented as backed up [assumed useful].
- Test: back up, delete a light, restore; check whether the registry and the key came back; record which store survived.

**3.7 Controller replacement / migration**
- Director/Composer: the Controller Migration Wizard moves the project; third-party drivers tied to the controller MAC must be re-authorised [community: docs.control4.com]. Encrypted persisted values (`PersistSetValue(..., true)`) may be keyed to the controller [assumed].
- Reaction: expect to re-pair (one action); ids and bindings should travel with the project [assumed]; otherwise the recovery import rebuilds the registry.
- Test: cannot be tested here; note it in the Composer checklist.

**3.8 OS upgrade 3.x -> 4.x**
- Director/Composer: documented changes: 4.0 adds `GetBoundPartner`, `GetProtocolDeviceById`, MQTT, deprecates `GetText`; 4.1 adds `GetRoomID`, dynamic commands/conditionals; 4.2 `GetDriverConfigInfoById` [verified: API 3_whats_new/_5, _6, _7]; release notes remove `io.popen` and deprecate LuaSocket [community: OS 4.0 release notes, via search summary]. Nothing documented changes bindings, persistence or AddDevice.
- Reaction: we use none of the removed pieces. Optional, behind `C4:GetVersionInfo()`: `GetProtocolDeviceById(proxyId)` to cross-check registry proxy ids. Nesting lights under the bridge in the Composer tree (`nesting_driver_is_parent` / `nested_driver_is_child` plus `VAR_C4_NESTING_PARENTS_CHILD_DEVICES`) is 3.4.2+ [verified: PP 63/_39, 63/_40], above our 3.3.0 minimum.
- Test: re-run the Composer checklist after the upgrade; compare the AddDevice callback shape (`lights.dump` log line).

## 4. Bindings

| # | Case | Driver learns via | Reaction |
| --- | --- | --- | --- |
| 4.1 | What `OnBindingChanged` delivers | the callback | enumerate at late init and 1 s after any callback |
| 4.2 | Rebind a light to another bridge | false then true | new bridge looks the rid up and adopts or rejects |
| 4.3 | Auto-bind | n/a | tempting for hand-added lights; decide with the scene design |
| 4.4 | Class mismatch | `OnBindingValidate` | accept only `HUE_BRIDGE` |
| 4.5 | Return shapes | n/a | accept table or number; ask the right side |
| 4.6 | Light bound to nothing | `GetBoundProviderDevice` nil | unbound status, ONLINE false |

**4.1 What `OnBindingChanged` delivers**
- Director/Composer: `(idBinding, strClass, bIsBound, otherDeviceID, otherBindingID)` for control bindings [verified: API 9/_12]; fires on Composer binds/unbinds and on `C4:Bind`/`Unbind` (the sample relies on it after `C4:Bind` [verified: sample idc_controller]) [assumed for Unbind]. At Director startup for already-bound bindings: [silent]; the "until bindings are restored by Director" note suggests no [verified: FUND 28/_2 AddDynamicBinding row] [assumed].
- Reaction: never depend on a startup callback: enumerate at late init (`GetBoundConsumerDevices`) as `idc_controller` does with a 5 s timer, and again 1 s after any `OnBindingChanged` [verified: sample]; add the missing handler to the bridge.
- Test: restart Director; log every `OnBindingChanged` in both drivers with all five params; bind/unbind one light in Composer and log again.

**4.2 Rebinding a light to a different bridge**
- Director/Composer: Composer unbinds then binds: the light gets false then true [assumed]; old bridge false, new bridge true if the provider side fires.
- Reaction: light, HELLO to the new bridge with its rid. New bridge: a HELLO for an unknown rid is only debug-logged today [code: `HUE_HELLO`]; it should look the rid up on **its** Hue bridge and adopt if found, else set the light's Status via `HUE_CONFIGURE { error = "not on this bridge" }`. Multiple bridges are out of v1 scope, but this is also the single-bridge re-add path (1.8).
- Test: two bridge drivers on the test project, one unpaired; move a light's binding between them.

**4.3 Auto-bind**
- Director/Composer: `<autobind>True</autobind>` on a class (optionally `<idautobind>`) binds to the first provider of that class when the device is added [verified: FUND 11/_1]; `<dependencies>` with `auto_bindings` add and bind dependent drivers when the parent loads [verified: FUND 18/_2].
- Reaction: tempting for hue_light so a hand-added light binds without Connections; harmless with one bridge, wrong with two. Scene devices share the class, so decide once at the scene design.
- Test: add `<autobind>True</autobind>` to a dev build of hue_light; add one by hand; see whether it binds.

**4.4 Binding class mismatch**
- Director/Composer: Composer only offers matching classes [assumed]; `C4:Bind` with a wrong class: [silent]. `OnBindingValidate(idBinding, strClass)` lets a driver reject a binding before Director makes it [verified: API 32/_26].
- Reaction: implement `OnBindingValidate` on the bridge to accept only `HUE_BRIDGE`.
- Test: `C4:Bind` with class "WRONG" from a dev action; observe.

**4.5 Return shapes of the bound-device queries**
- Director/Composer: `GetBoundConsumerDevices` -> table or nil [verified: API 32/_3; hardware]; `GetBoundProviderDevice` documented as a table, used as a number by the example and the sample [verified: API 32/_4; sample idc_client]; on hardware `GetBoundProviderDevice(protocolId, 5001)` returned the protocol id itself, because the protocol *provides* 5001 and the question was malformed [verified: hardware].
- Reaction: keep accepting both shapes (the light does [code: `bound_bridge`]); for the light's proxy id use AddDevice's info or `GetBoundConsumerDevices(protocolId, 5001)` [verified: hardware]; on 4.x `GetProtocolDeviceById` goes the other way [verified: API 9/_8.5].
- Test: already observed; re-run after any OS update.

**4.6 A light bound to nothing**: binding 1 empty; `GetBoundProviderDevice(id, 1)` nil at late init; Status "Not bound to a Hue Bridge", ONLINE false, commands dropped with that reason [code: hue_light/driver.lua]. Keep it: a disabled tile is the honest Navigator view. Test: add a bare hue_light; check Status and tile.

## 5. Proxies

| # | Case | Driver learns via | Reaction |
| --- | --- | --- | --- |
| 5.1 | Proxy id vs protocol id | AddDevice info; `GetBoundConsumerDevices(protocolId, 5001)` | store both; proxy for rename/lookup, protocol for messages |
| 5.2 | Navigator view of an unbound light | n/a | `ONLINE_CHANGED false` early; brightness on first state |
| 5.3 | ONLINE_CHANGED semantics | n/a | online = bound + configured + Zigbee connected + stream alive |
| 5.4 | ALS/programming reference a deleted light | n/a | never delete to replace; `reduced_als_support` now |
| 5.5 | Scene devices as switches | n/a | separate `hue_scene.c4z`, dimmer False |
| 5.6 | Scene deleted/renamed in Hue | stream `delete` / rename | keep device, offline, re-point list |
| 5.7 | Hide a scene device in some rooms | n/a | `SET_DEVICE_HIDDEN_STATE` to room devices |

**5.1 Proxy id vs protocol id**
- Director/Composer: two devices per light: protocol (our Lua) and light_v2 proxy; Composer shows and renames the proxy; programming, ALS and Navigators address the proxy ("Bound Call, aka SendToDevice") [verified: API 22/_32 note; PP 64/_0]. Proxy = protocol + 1 here [verified: hardware], not a rule.
- Learns: AddDevice info, `GetBoundConsumerDevices(protocolId, 5001)`, `C4:GetProxyDevices()` inside the light [verified: API 25/_1; sample idc_client].
- Reaction: store both (done [code]); proxy id for `RenameDevice`, `GetDevices` lookups and the dev `Proxy Command`; protocol id for `SendToDevice` messages.
- Test: `Lights Report` prints both; cross-check one light in Composer (hover shows the id).

**5.2 Navigator view of an unbound or unconfigured light**
- Director/Composer: the proxy starts "online" [verified: PP 66.5/_15]; with no `LIGHT_BRIGHTNESS_CHANGED` ever sent the tile shows 0/off [assumed].
- Reaction: send `ONLINE_CHANGED { STATE=false }` at late init when unbound or unconfigured (done [code: `report_online`]) so the tile is disabled rather than lying; send `LIGHT_BRIGHTNESS_CHANGED` as soon as the first HUE_STATE arrives [verified: PP 66.5/_10.2].
- Test: Composer checklist: a bare light's tile; bind it and watch it enable.

**5.3 ONLINE_CHANGED semantics**
- Director/Composer: `STATE` true/false; "UI functionality will be disabled if the light is offline" [verified: PP 66.5/_15]; ALS/programming behaviour on an offline member: [silent].
- Reaction: online = bound and configured and Zigbee connected (done [code: `is_online`]). Add: when the bridge's stream is dead longer than the watchdog, send `HUE_STATE { online=false }` to all lights so a dead bridge disables every tile; back on resync.
- Test: unplug the bridge's network for two minutes; tiles disable, then recover.

**5.4 ALS scenes and programming that reference a deleted or replaced light**
- Director/Composer: scenes and programming reference the proxy id [verified: PP 64/_0 model] [assumed for ids]; on delete Composer removes or orphans them [silent] [community: nothing found]; a re-added light has a new id, references do not follow [community: docs.control4.com "re-configure ... any associated programming"].
- Reaction: "replace the bulb" must **not** be a device replacement: keep the C4 device and re-point its rid (1.6, 3.3). Tell dealers never to delete a Hue Light to fix it. To join ALS at all we must set `reduced_als_support=true` and handle `SET_BRIGHTNESS_STOP`/`SET_COLOR_STOP` [verified: PP 63/22]; today both ALS flags are false [code: hue_light/driver.xml].
- Test: Composer: put a test light in an ALS scene, delete the light, open the scene; record what Composer shows; re-add and check whether the scene picked it up (expect not).

**5.5 Scene devices as switches**
- Director/Composer: `DYNAMIC_CAPABILITIES_CHANGED dimmer=false` turns a light_v2 into a switch at runtime; a switch has only variable 1000 (Light State); events Light On 5100 / Off 5101 [verified: PP 66.5/_8, 66/_0, 65/_0].
- Reaction: one `hue_scene.c4z` (light_v2 proxy, `<dimmer>False</dimmer>`, consumer binding 1 `HUE_BRIDGE`) per scene; same message pattern with `rid` = scene rid: ON -> `PUT /clip/v2/resource/scene/<rid> {"recall":{"action":"active"}}`; `status.active` from the stream -> `LIGHT_BRIGHTNESS_CHANGED` 100/0. Do not reuse `hue_light.c4z` with dimmer flipped: a driver must not change its proxy type across updates and a dealer could flip it back [verified: FUND 14/_2].
- Test: prototype one scene device through the dev loop before designing the picker.

**5.6 Scene deleted or renamed in Hue**
- Hue side: a stream `delete` container for the scene rid; a rename in `metadata.name`, as for lights today [code: `on_container`].
- Reaction: keep the C4 scene device (programming survives), send `ONLINE_CHANGED false`, Status "Scene deleted in Hue"; let the dealer re-point it through a `Hue Scene` DYNAMIC_LIST; never auto-delete C4 devices (no documented API deletes a device anyway [silent]).
- Test: delete a scene in the Hue app; observe the device.

**5.7 Hiding a scene device from rooms it does not belong to**
- Director/Composer: rooms accept `SET_DEVICE_HIDDEN_STATE { PROXY_GROUP, DEVICE_ID, IS_HIDDEN }` via `SendToDevice(roomId, ...)` [verified: lib lib.lua `HideProxyInAllRooms`; undocumented in the API].
- Reaction: optional polish; rooms from 2.4.
- Test: try on one scene device; confirm the Navigator hides it.

## 6. Dynamic UI on OS 3.x

| # | Case | Driver learns via | Reaction |
| --- | --- | --- | --- |
| 6.1 | `UpdatePropertyList` limits | n/a | no commas in display strings; prefer CUSTOM_SELECT |
| 6.2 | LIST changes and `OnPropertyChanged` | user picks only | rebuild lists at late init; reset after use |
| 6.3 | Read-only vs editable | n/a | never retype a property in an update |
| 6.4 | Hide/show at runtime | n/a | `SetPropertyAttribs` after late init |
| 6.5 | Property not in driver.xml | n/a | declare everything |
| 6.6 | Actions as pickers | `ExecuteCommand` LUA_ACTION | CUSTOM_SELECT params for lights and rooms |

**6.1 `UpdatePropertyList` limits**
- Director/Composer: `C4:UpdatePropertyList(name, "a,b,c", default)`, comma-delimited, default optional since OS 3 [verified: API 24/_6]. Escaping of commas and quotes, maximum length: [silent]. The vendor wrapper just `table.concat`s with "," and refuses names not in `Properties` [verified: lib handlers.lua `UpdatePropertyList`].
- Reaction: build display strings without commas (`name:gsub(",", " ")`), dedupe with a suffix, keep a `display -> rid` map in memory, never parse a display string back. Keep lists to one bridge's lights (~50 names, ~1 KB); probe the length before relying on more. Prefer **CUSTOM_SELECT** action params for pickers: `{ text=, value= }` pairs, folders, deferred fill, no comma problem [verified: FUND 15/_4; used in action params by sample idc_controller driver.xml].
- Test: dev action: `UpdatePropertyList` with a name containing a comma and a quote, then a 4 KB list; paste what Composer shows.

**6.2 Does a LIST/DYNAMIC_LIST change fire `OnPropertyChanged`?**
- Director/Composer: `OnPropertyChanged` fires only on a user change, not on `UpdateProperty` [verified: API 24/_3]; the vendor wrapper calls `OnPropertyChanged` by hand after `UpdatePropertyList` when asked [verified: lib handlers.lua], so list updates do not fire it either [assumed]. A user pick in a DYNAMIC_LIST does fire it [verified: FUND 15/_2]. DYNAMIC_LIST items are **not persisted**: rebuild at init [verified: FUND 15/_2]. The Fundamentals say `UpdatePropertyList` "may be called within OnDriverInit" while the safe-usage table says no [verified: FUND 15/_2 vs API 22/_25.2]; use late init.
- Reaction: rebuild every dynamic list in `OnDriverLateInit` and after each import/resync; treat the selected value as a one-shot command and reset it to "" after acting, as the sample does [verified: sample dynamic_lists/driver.lua `OPC`].
- Test: restart Director; the list is still populated; pick an item; the handler runs once.

**6.3 Read-only vs editable**: `<readonly>` per property [verified: FUND 15/_1]; "be careful about retyping properties" across updates [verified: FUND 14/_2]; toggling read-only at runtime: [silent]. Status-only properties read-only; pickers editable; add a new property rather than change a type.

**6.4 Hiding and showing properties at runtime**
- Director/Composer: `C4:SetPropertyAttribs(name, 1)` hides, `0` shows [verified: API 24/_4; lib handlers.lua `SetPropertyVisible` uses `visible and 0 or 1`]; not before late init [verified: API 22/_25.2]; whether Composer refreshes without reopening the device: [silent].
- Reaction: hide the pickers until paired; hide `Hue Light` on a light once configured and show it again on error.
- Test: toggle from a dev action with Composer open; note whether the page refreshes live.

**6.5 A property not declared in driver.xml**
- Director/Composer: `Properties` holds the driver.xml properties [verified: API 24/_1]; `UpdateProperty` on an undeclared name: [silent]; the vendor wrapper refuses it [verified: lib handlers.lua].
- Reaction: declare everything (the dev-only bridge actions deliberately live outside driver.xml and are command-only [code]); a property added in a later driver.xml appears after Update Driver [verified: FUND 14/_2 "You may add"].
- Test: dev action `UpdateProperty("Nonexistent", "x")`; look for an error.

**6.6 Actions as the picker UI**
- Director/Composer: actions arrive as `LUA_ACTION` with `ACTION` = name plus the params [verified: API 5/_1; code: dispatch.lua]; param types STRING, LIST, RANGED_*, COLOR_SELECTOR [verified: FUND 15/_6]; CUSTOM_SELECT and DEVICE_SELECTOR in commands and, per the sample, in action params [verified: FUND 9/_1; sample idc_controller driver.xml]; `sort_order` 3.3.0+ [verified: FUND 15/_6].
- Reaction: "Add Hue Light" = action with two CUSTOM_SELECT params (unregistered lights by name; rooms grouped by floor) with the Hue-room default pre-selected; "Map Hue rooms" = folder-style CUSTOM_SELECT. Static LIST params cannot change at runtime, so avoid them for lights and rooms.
- Test: build the action in a dev-build driver.xml (one Composer update), then drive `ExecuteCommand` with chosen values through the dev loop.

## Top ten cases that must shape the design

1. **The Control4 device is the stable identity; the rid is re-pointable** (1.6, 3.3, 5.4). Replacing a bulb or a scene must never mean deleting the C4 device, or programming and ALS membership die with the proxy id. Both drivers need an adopt / re-point path.
2. **The bridge must learn about deleted lights** (1.1, 1.2, 4.1). Add `OnBindingChanged` to the bridge, a `HUE_GOODBYE` from `OnDriverRemovedFromProject`, and a reconcile against `GetBoundConsumerDevices` / `GetDevicesByC4iName` at late init and after imports; tombstone, never auto re-add.
3. **Bridge re-add must be recoverable from the lights** (1.7, 1.8, 3.6, 3.7). Each light keeps its own rid, name and model; a recovery import binds and rebuilds the registry from `HUE_IAM` answers instead of creating duplicates.
4. **One serial creation queue for every AddDevice path** (1.9): import, single add, scene devices, mirror-rooms.
5. **Room mapping is a creation-time default, keyed by room id, validated at use** (1.4, 2.1, 2.2, 2.6). Moves and renames in Composer are never undone by the driver.
6. **Rooms come from `GetDevicesByC4iName("roomdevice.c4i")` first; `GetProjectHierarchy` types are unknown until probed** (2.4).
7. **Startup races are covered by `configure_all` plus buffering** (3.1, 3.2): the bridge queues early HELLOs; lights buffer early CONFIGURE/STATE until late init.
8. **Scene devices are a separate `hue_scene.c4z` with a light_v2 switch proxy, not a flipped hue_light** (5.5, 5.6); same binding class, same message pattern, offline-not-deleted on Hue-side removal.
9. **Pickers are CUSTOM_SELECT action params, not comma lists** (6.1, 6.6); any DYNAMIC_LIST is rebuilt at late init and reset after use (6.2).
10. **ALS eligibility is a driver.xml decision to make now** (5.4): `reduced_als_support=true` plus `SET_*_STOP` handling, before dealers build scenes on devices that cannot join them.

## Hardware probes to run first (dev loop, in this order)

1. Log all five `OnBindingChanged` params in both drivers (the bridge has no handler today); restart Director: does it fire at startup? Then bind/unbind one light in Composer.
2. Delete a test light in Composer; watch the bridge log for `OnBindingChanged(false)`; run `Lights Report`, then Import Lights: does the import re-create it?
3. Register `OnItemAdded`, `OnItemNameChanged`, `OnItemRemoved`, `OnItemMoved`, `OnDeviceUserInitiatedRemove` and `OnPIP` in the bridge; print the raw `data` XML while renaming, moving and deleting a light and a room.
4. Dump `C4:GetProjectHierarchy()` and `C4:GetDevicesByC4iName("roomdevice.c4i")` with `lights.dump`; record the `type` strings and whether floors appear.
5. `SendToDevice(99999, "HUE_STATE", {})` and `UpdateProperty("Nonexistent", "x")`: errors or silence?
6. Add a bare hue_light by hand: Status, tile state (`ONLINE_CHANGED false`), and the rid-less `HUE_HELLO` at the bridge.
7. `UpdatePropertyList` with commas and quotes in names and a 4 KB list; `SetPropertyAttribs` toggled while the Properties page is open.
8. With `reduced_als_support=true` in a dev build, put a light in an ALS scene, delete the light, reopen the scene in Composer; then re-add and compare.
9. Back up the project, delete one light, Load Project: do the registry count and the pairing come back, and from which store?
10. Prototype one `hue_scene` switch device end to end (recall, `status.active` -> tile) before designing the scene picker.
