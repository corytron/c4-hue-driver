# Hue edge cases: lights, rooms, zones, scenes and the bridge

> **Historical research (2026-10-21)**, written before the import-ui and scenes features; "today" means that day's code. The decisions are `docs/import-design.md` and `docs/scenes-design.md` (smart scenes: the draft `docs/smart-scenes-research.md`); the present is in `docs/status.md`.

What the Hue bridge does when the house changes (a bulb added, moved,
replaced, renamed; a room or scene edited; the bridge itself replaced), how
the driver can tell, and what it should do about it. Written before the
"pick a detected light and a Control4 room, add it" flow, the Hue-room →
Control4-room mapping and the one-switch-per-scene design, so that none of
those automate anything the owner would rather do by hand.

Guiding rule throughout: **the driver never creates, deletes, renames or
moves a Control4 device on its own.** It detects, records, and offers.
Composer (the owner) decides.

Status markers:

- **[verified: Core Concepts / CLIP API list / Discovery / HTTPS]** — Signify's
  own developer pages, saved as text by the owner.
- **[verified: hardware]** — seen on the house bridge (BSB003) through the dev
  loop (`build/dev/driver.log`) or recorded in `docs/design.md`.
- **[verified: Philips support]** — Signify's consumer support article on the
  Bridge Pro upgrade.
- **[community: aiohue]** — Home Assistant's `aiohue` library (models and
  controllers); **[community: openhue]** — the openhue OpenAPI transcription
  of Signify's CLIP v2 reference; **[community: openHAB]** — the openHAB CLIP 2
  binding thread; **[community: forum]** — other forum posts.
- **[assumed]** — not confirmed anywhere; to test on the bridge.

## 0. The facts the catalogue rests on

| Fact | Status |
| --- | --- |
| A physical bulb is a `device` that owns services: `light`, `zigbee_connectivity`, usually `entertainment`, `device_software_update`, and reference-only types such as `taurus_7455`. Services point back with `owner`. | [verified: Core Concepts]; service list [verified: hardware fixture shape, community: aiohue] |
| Every resource id (`rid`) is a UUID, `^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$`. `id_v1` (`/lights/N`, `/groups/N`, `/scenes/X`) exists only on resources that have a v1 counterpart. | [community: openhue, aiohue] |
| A `room` groups **devices** (`children` are `rtype: device`); each device is in at most one room. A `zone` groups **services** (`children` are `rtype: light`); a light can be in any number of zones. `bridge_home` groups the rooms and the devices in no room. Rooms, zones and the home each offer one `grouped_light`. | [verified: Core Concepts, CLIP API list]; zone children `rtype: light` [community: openhue] |
| `grouped_light.on` is true if any light in the group is on; `dimming.brightness` is the average of the lights that are on. | [community: openhue, aiohue] |
| A `scene` has `group` (the room or zone it belongs to), `actions[]` (one per target light, with on/dimming/color/color_temperature/gradient/effects), `metadata.name` (1–32 chars), `metadata.image` (a `public_image` rid), `speed`, `auto_dynamic`, `palette`, `status.active` in `inactive` / `static` / `dynamic_palette`, and `status.last_recall`. | [community: openhue, aiohue] |
| A `smart_scene` has `group`, `week_timeslots[]` (each a `recurrence` of weekdays and `timeslots[]` with `start_time{kind: time / sunrise / sunset}` and a `target` scene rid), `transition_duration` (default 60000 ms), `active_timeslot`, `state` in `active` / `inactive`. | [community: openhue, aiohue] |
| Scene recall is a PUT on the scene: `{"recall":{"action":"<active / static / dynamic_palette>","duration":<ms>,"dimming":{"brightness":<%>}}}`. Smart scenes: `{"recall":{"action":"<activate / deactivate>"}}`. | [community: openhue, aiohue]; `/resource/scene/{id}` PUT exists [verified: CLIP API list] |
| `zigbee_connectivity.status` is one of `connected`, `disconnected`, `connectivity_issue`, `unidirectional_incoming` (aiohue also knows `pending_discovery`); the resource carries the bulb's `mac_address`. | [community: openhue, aiohue]; the house bridge emits these updates often [verified: hardware] |
| Event stream: each SSE message is `id: <unix>:<n>` plus one `data:` JSON array of containers `{creationtime, id, type: <update / add / delete / error>, data:[partial resources]}`. At most one container per second; a property changed twice in a second reports its last value; several resources in one container. | [verified: Core Concepts, hardware] |
| `delete` items carry only the resource's `id` and `type`, not its owner or name. | [community: aiohue] |
| The bridge sends no keepalive on the stream. aiohue sends `Last-Event-ID` on reconnect and says short drops are replayed; Signify's text does not mention replay. | no keepalive [verified: hardware, community: aiohue]; replay [community: aiohue, unconfirmed] |
| `light` has GET and PUT only; deleting a bulb is `DELETE /resource/device/{id}` ("the bridge device cannot be deleted"). Rooms, zones, scenes and smart scenes have POST and DELETE. | [verified: CLIP API list] |
| Rate limits: ~10/s to `/light`, 1/s to `/grouped_light`. | [verified: Core Concepts] |
| Limits: Hue Bridge 50 lights (hard 63), 12 accessories; Bridge Pro 150+ lights (hard 186), 50+ accessories, up to 500 scenes. The square bridge's scene cap is 200 in Signify's "Bridge – Maximum Settings" page (page unreachable today, 502). | [community: Philips product pages]; 200 scenes [assumed] |

## 1. Light lifecycle

| Case | What Hue does | How the driver sees it | Driver reaction | Open questions / tests |
| --- | --- | --- | --- | --- |
| **New bulb added in the Hue app** | New `device` with its services; the app puts it in a room during setup, so `room.children` grows too. | `add` containers for the device, light, zigbee_connectivity, entertainment [assumed: one `add` item per resource, possibly across several containers]; an `update` on the room. Also found by the next resync (rid not in registry). | Log once; put it in the **Detected lights** list (name, model, Hue room, rid) that the add-one-light action reads from. Never `AddDevice` on an event. | Order of the `add` items (device before light?) and whether they share a container. Does the light's `add` already carry `owner`? Does the room `update` come in the same second? Test with a spare bulb while `log.debug` dumps whole containers. |
| **Bulb added but left in no room** | The app allows "no room"; the device appears only under `bridge_home.children`. | Light and device `add`; no room update. Resync: device rid not in any `room.children`. | Detected list shows "(no room)"; the Control4 room is the owner's pick anyway, so no blocker. | None. |
| **Bulb deleted in the Hue app** | The device and its services disappear; `room.children` shrinks; every scene in that room loses the light's action (`last_actions_update.source = autogrow` [community: aiohue]); zones drop the light rid. | `delete` items for device, light, zigbee_connectivity, entertainment [assumed: one per resource]; `update` on the room, zones and scenes. Resync: registry rid missing from GET `/light`. | Mark the registry entry `gone` (keep the Control4 device and its rid); send `ONLINE_CHANGED false`; light `Status` = "Deleted on the bridge". Offer **Relink** (pick a detected light for this Control4 device) and **Forget** (drop the registry entry; the owner deletes the device in Composer). Never auto-delete. | Does a device delete produce deletes for each service, or only the device? Resolve `delete` items for a light through the cached device → services map (the item has no owner). |
| **Deleted bulb re-added** (factory reset, or Zigbee re-join after the app forgot it) | A new device and light with **new rids** [assumed: UUIDs are minted per device record; nothing says they are reused]. `id_v1` may reuse a freed `/lights/N` [assumed, v1 habit]. The bulb's `zigbee_connectivity.mac_address` is the radio's IEEE address and should be unchanged [assumed]. | `add` items as for a new bulb; the old rid stays `gone`. | Detected list flags "looks like <old name> (same Zigbee MAC)" so Relink is one click, but it is still a click. Store `mac_address` in the registry for this; never key on `id_v1`. | Confirm the new rid and the unchanged MAC with the spare bulb: note rids and MAC, delete in the app, re-add, compare. |
| **Bulb replaced by a different bulb** (same socket, new hardware) | As above but a new MAC and often a new model/capabilities. | New rids, no MAC match. | Relink by hand; on relink send `HUE_CONFIGURE` with the new caps (the light_v2 proxy gets a fresh `DYNAMIC_CAPABILITIES_CHANGED`). The Composer name stays. | Does Composer/Navigator cope with a light losing colour support after relink (colour → CCT-only)? Verify the capability notify updates the UI. |
| **"Replace light" in the Hue app** | No such feature was found; replacing is delete + add in the app [assumed]. | — | Nothing special beyond Relink. | Check the current app for a replace/transfer option on a light. |
| **Bulb unreachable** (unpowered, out of range) | `zigbee_connectivity.status` → `connectivity_issue` / `disconnected` / `unidirectional_incoming`; the `light` resource itself does not change (the bridge's representation lags, minutes) [verified: Core Concepts "Representations"]. | `update` on zigbee_connectivity (the house bridge sends many of these) [verified: hardware]. | `HUE_STATE online=false` → `ONLINE_CHANGED`; keep the last known level. Treat anything but `connected` as offline (current behaviour). | Observe what the bridge reports when a bulb comes back: `connected` first, then a light update with its real state? |
| **Bulb renamed in the Hue app** | The app renames the **device**; for a single-light device the light's `metadata.name` follows [assumed; see §6]. | `update` with `metadata.name` on device and/or light. | Update the registry name (done today); Composer name untouched; log. Offer a **Sync names from Hue** action for the owner to run. | Does renaming emit updates on both resources, and in which order? Rename through `Hue Request` PUT on the device and watch. |
| **Bulb firmware update** | `device_software_update` state changes; `device.product_data.software_version` changes; new features may appear on the light (effects, gradient). | `update` items on device_software_update and device. | Nothing live; the resync refreshes `caps` from `/light` (colour, CCT range, min_dim). | None. |
| **Device with several light services** (e.g. a lamp with a front and a back light) | One device, two `light` services with `service_id` 0 and 1; each light has its own `metadata.name` and `product_data.name` ("only available for devices with multiple lightservices") [community: aiohue, openhue]. | Two light rids with the same `owner`. | Import is already per light rid; name such lights by `light.metadata.name` (not the device name); one `zigbee_connectivity` covers both, so one offline event fans out to two devices (current code does this). | Confirm on hardware if the house ever gets such a product; none today [verified: hardware list has 47 single lights]. |
| **Bulb whose owner device has no `zigbee_connectivity`** (Matter / Wi-Fi products, Friends-of-Hue) | `online` cannot be derived from Zigbee. | No connectivity rid for the device. | Report online unknown ("" in the `Online` property), never offline. | Out of scope; make sure the fan-out tolerates a missing service. |

## 2. Rooms and zones

| Case | What Hue does | How the driver sees it | Driver reaction | Open questions / tests |
| --- | --- | --- | --- | --- |
| **Light moved from room A to room B** | Room membership is a property of the **device**, not the light: A's `children` loses the device, B's gains it. A's scenes drop the light's action and B's scenes gain one (autogrow) [community: aiohue]. The light resource does not change at all. | `update` on room A and room B (full `children` arrays [assumed: the array is sent whole, since partial arrays make no sense]); `update` on affected scenes. Resync: GET `/room`. | Re-derive device → room from the room cache; show it in the light's **Hue Room** property. **Never move the Control4 device**: Composer owns room placement and DriverWorks has no documented call for it [assumed: none]. If a room mapping drives anything (grouped control, scene lists), re-derive it from `children` each time. | Are both rooms in one container? Is `children` complete or a delta? Test with `Hue Request` PUT `/room/<B>` `{"children":[...]}` and watch. |
| **Room renamed** | `room.metadata.name` changes; its grouped_light and scenes keep their rids. | `update` on the room. | Mapping must be keyed by room **rid**; refresh the label only. | None. |
| **Room deleted** | Devices fall back to "no room" (`bridge_home.children`); the room's grouped_light disappears; the room's scenes are deleted with it [assumed, scenes belong to the group]. | `delete` for room, grouped_light and each scene [assumed]; `update` on bridge_home. | Mapping entry → "deleted on bridge" (keep it, let the owner re-point or remove it); any scene switch for that room → orphaned (see §3). Lights are unaffected as devices. | Test with a throwaway room created and deleted via `Hue Request` (POST `/room`, DELETE `/room/<id>`). |
| **Room created** | New room, usually empty, with a new grouped_light. | `add` for room and grouped_light. | Appears in the room-mapping dropdown on the next refresh. | None. |
| **Zone created / light added to several zones** | Zone `children` are light rids; a light may be in many zones; each zone has a grouped_light and its own scenes. | `add` for zone and grouped_light; `update` on zone children. | Treat zones exactly like rooms for grouped control and scene lists, but never use a zone to infer a Control4 room (a light can be in three zones). | None. |
| **Zone deleted** | Its grouped_light and scenes go; lights untouched. | `delete` items. | As room deleted. | Same test with POST/DELETE `/zone`. |
| **Room/zone with no lights** (sensors only) | Room exists with a grouped_light that controls nothing. | GET shows no light-owning devices. | Hide from the mapping dropdown or show "(no lights)". | None. |
| **bridge_home** | One resource; children are rooms plus room-less devices; its grouped_light is "all lights" (`id_v1 /groups/0`). | GET `/bridge_home`. | Useful only for an "All Hue lights" grouped control; its scenes (if any) live under `group: bridge_home` [community: aiohue]. | None. |
| **Grouped control of a room/zone** | PUT on the grouped_light; the bridge then emits per-light updates and grouped_light updates. 1 request/s limit. | Containers full of `grouped_light` items after every change [verified: hardware: four grouped_light items after each light change]. | Separate 1/s token bucket; ignore grouped_light updates for state (lights report themselves) unless a room device is built later. | None. |

## 3. Scenes and smart scenes

| Case | What Hue does | How the driver sees it | Driver reaction | Open questions / tests |
| --- | --- | --- | --- | --- |
| **Scene created in the app** | New `scene` with `group` = a room or zone, `actions` for every light in the group, `metadata.image`, `auto_dynamic`, `palette`. | `add` for the scene. Resync: GET `/scene`. | Appears in the **Available scenes** list (name, group name, dynamic yes/no). **No switch device is created automatically**; the owner adds one through an action. | None. |
| **Scene edited** (colours, brightness, dynamics) | `actions`/`palette`/`speed` change; rid stable. | `update` with the changed fields. | Nothing to do for a switch device. | None. |
| **Scene renamed** | `metadata.name` changes. | `update`. | Registry label refresh; Composer name untouched; include in Sync names. | None. |
| **Scene deleted** | Resource gone. Also happens when its room/zone is deleted (§2). | `delete` with only id and type. Resync: rid missing from `/scene`. | Switch device → orphaned: `Status` "Deleted on the bridge", pressing it logs and does nothing. Offer Relink to another scene and Forget. Never delete the device. | None. |
| **Scene copied to another room** (app "Copy to…") | A **new** scene rid under the other group. | `add`. | Appears in the Available list as a different scene. | None. |
| **Light added to / removed from the scene's group** | The bridge rewrites `actions` itself (`last_actions_update.source = autogrow`). | `update` on the scene. | Nothing; recall still works. | Observe once so the design does not confuse this with a user edit. |
| **Recall from Control4** | PUT `/scene/<rid>` with `recall.action`: `active` (runs the actions; starts dynamics if `auto_dynamic`), `static` (actions only, no dynamics), `dynamic_palette` (start the palette animation); optional `duration` (ms, 100 ms steps, max 6 000 000 [community: aiohue]) and `dimming.brightness` override. | HTTP 200 with the scene's ResourceIdentifier; then light, grouped_light and scene `update`s. | Switch ON → `active` (or `dynamic_palette` when the owner marked the switch "dynamic"); switch OFF → either nothing, or turn the group's grouped_light off (owner's choice per switch). Brightness override is a separate programming command, not the default. | Confirm the body on hardware with `Hue Request` PUT; confirm `duration` behaves like `dynamics.duration`. |
| **Scene becomes active** (from Control4, the app, a Hue switch, an automation) | `status.active` → `static` or `dynamic_palette`; `status.last_recall` set; the previously active scene in the same group goes `inactive`. | `update` on the scene, in the same container as the grouped_light updates [verified: hardware 2026-10-21 21:42:37: `grouped_light×4, scene`, then `smart_scene` one second later]; the openHAB thread confirms the scene is named in the event [community: openHAB]. | Mirror onto the switch: ON for `static`/`dynamic_palette`, OFF for `inactive`. This gives two-way scene state almost for free. | One Fibaro developer reports no scene event when a scene is set from the app [community: forum], contradicting the above; test from the app, from a Hue dimmer and from the API. |
| **Scene becomes inactive** | Any light in the group changed by hand (dimmed, switched, recoloured) flips the scene to `inactive` [community: openHAB]; another scene recalled in the same group does too. | `update` on the scene with `status`. | Switch OFF. Do not fight it: a switch that is ON only while every light matches the scene is the honest state. | Does turning one light off also deactivate? Does recalling the same scene twice emit two updates? |
| **Scenes in several groups active at once** | Status is per group; a room scene and a zone scene overlapping the same light can both read `static` until the next change [assumed]. | Separate scene updates. | Nothing; each switch mirrors its own scene. | None. |
| **Dynamic scenes** | `dynamic_palette` keeps running on the lights (`light.dynamics.status = dynamic_palette`); light updates arrive continuously, one container per second at most. | Steady stream of light updates. | The light drivers report what arrives; nothing to throttle on the receive side. Recall with `static` when the owner wants no animation. | Event volume during a dynamic scene with 20 lights; watch the SSE parser and the 47 `SendToDevice` fan-outs per second. |
| **Smart scene** (24 h scene) | A schedule over regular scenes: `week_timeslots` targets are scene rids; `state` active/inactive; `active_timeslot` tells which slot is running. Recall `activate` starts it, `deactivate` stops it (lights stay as they are [assumed]). | `update` on the smart_scene (`state`, `active_timeslot`); the target scenes' own status updates as slots change [verified: hardware shows smart_scene updates following a recall]. | One switch per smart scene too: ON = `activate`, OFF = `deactivate`, state mirrored from `state`. List them separately from plain scenes. | Confirm `deactivate` leaves lights alone; confirm which slot's scene shows `static` while a smart scene runs. |
| **Scene with brightness override** | `recall.dimming.brightness` applies the scene's colours at another brightness; the stored scene is unchanged. | Normal recall updates. | Expose as a programming command with a brightness parameter; not on the switch. | Does `status.active` still become `static` after an overridden recall? |
| **`auto_dynamic`** | When true, `recall.action = active` starts the dynamic palette; `static` never does. | Field on the scene. | Show "dynamic" in the Available list; default the switch to `active` and let the owner choose `static`. | None. |
| **Scene images** | `metadata.image` is a `public_image` rid; images are bridge-internal. | Field only. | Ignore. | None. |
| **Scenes under other groups** | `group` can be `bridge_home`, `service_group` or `private_group` [community: aiohue]. | Scenes whose group rid is not a room or zone. | List them under "(other)"; recall works the same. | None. |
| **Scene limits** | 200 scenes on the square bridge [assumed], 500 on the Pro [community: Philips]. Hue app scene galleries create many. | Long `/scene` GET. | Available list may hold a few hundred entries: filter by group in the UI. | Measure the GET size on the house bridge. |

## 4. Bridge-level

| Case | What Hue does | How the driver sees it | Driver reaction | Open questions / tests |
| --- | --- | --- | --- | --- |
| **Bridge replaced via the app's transfer** (Bridge → Bridge Pro) | Devices, rooms, zones, scenes, entertainment areas and automations move for the first bridge; third-party apps "may need relinking"; the old bridge is factory-reset afterwards [verified: Philips support]. Reader reports say Home Assistant kept working without re-adding, and one integration developer says the first migrated bridge keeps device, group and scene ids [community: forum] — suggesting app keys and rids can survive. The new bridge has a **new bridge id**; `/api/0/config` on it reports `replacesbridgeid` [verified: Discovery page shows the field]. | Stored IP stops answering or answers with a different `bridgeid`; the certificate CN changes (we do not check hostnames, so TLS still passes). | On a bridge-id mismatch: if `replacesbridgeid` equals the stored id, offer **Adopt replacement bridge**; try the stored key first, re-pair on 403. Then run a reconciliation: rids that still exist keep their devices, the rest go to `gone` with MAC-based Relink hints. Never wipe the registry. | Everything here is to confirm on the day it happens; the owner just did this transfer (BSB003), so the current registry is already post-migration. |
| **Bridge factory reset** (no transfer) | All keys, rooms, scenes and rids are gone; bulbs must be re-added. | 403 `unauthorized user` on every call; after re-pairing, nothing in the registry matches. | Status "Application key rejected; re-pair"; stream stopped; registry kept; after re-pair, every light is `gone` and the Detected list is full of MAC-match hints. Relink one by one (or a "Relink all MAC matches" action that still needs one confirmation). | None beyond the MAC assumption in §1. |
| **Application key revoked** | Historically possible from the meethue.com account page; today in practice only by factory reset [community: forum]. | HTTP 403, body `{"errors":[{"description":"unauthorized user"}]}` [community: aiohue raises Unauthorized on 403; body text from the v1 era]. | Stop the stream and the command queue; `Status` property says so; keep everything persisted; a **Pair** action restarts the link-button flow. | Confirm the exact status and body by calling with a bogus key through `Hue Request`. Answered 2026-10-25 (#44, house Bridge Pro, software 2071524040): an unknown key gets HTTP 403 with an HTML body, not JSON, on `GET /clip/v2/resource/bridge` and on `/eventstream/clip/v2`; a revoked key is assumed to get the same. The driver goes by the status code (`docs/design.md`, "A rejected key"). |
| **Bridge firmware update / reboot** | Bridge offline for minutes; the stream closes; rids are stable across reboots [community: every integration keys on them]. Button resources may emit ghost events at reboot [community: aiohue]. | Stream `OnDone` or watchdog; GETs fail; then reconnect. | Existing behaviour: backoff reconnect, full resync on connect. Keep `ONLINE` as last known during the outage; report bridge state in the `Event Stream` property. | None. |
| **Bridge IP change** | DHCP gives a new address; the bridge id is unchanged. | Connect failures. | Existing design: discovery endpoint (≤ 1/15 min) for the stored bridge id, then `/api/0/config` check. | None. |
| **Two bridges** (out of scope) | Separate UUID namespaces; collisions are practically impossible but the registry should be keyed `(bridge id, rid)` if a second bridge driver ever exists. | — | Keep the bridge id in the registry record now; cheap. | None. |
| **rid stability** | rids survive reboots, firmware updates and app re-pairing [community]; they change when a device is deleted and re-added [assumed] and may or may not survive a bridge transfer [community, contradictory]. | — | rid is the primary key; `mac_address` the recovery key; `id_v1` and names are display only. | — |

## 5. Event stream specifics and the resync

- **Container semantics.** `update` items carry only changed properties (plus
  `id`, `type`, `owner`, `id_v1`); `add` items are complete resources
  [assumed: as complete as a GET]; `delete` items are bare identifiers
  [community: aiohue]; `error` containers exist but their shape is
  undocumented [verified: Core Concepts lists the type]. Several resource types
  can share a container, and several containers can share one SSE message
  (the `data:` line is an array) [verified: Core Concepts, hardware].
- **Does a light delete come with device/service deletes?** Not documented.
  The driver must cope with any subset: a light `delete` alone, a device
  `delete` alone (resolve its light rids from the cached device record), or
  all of them. Act on the light rid, idempotently.
- **Ordering.** Within one second the bridge coalesces, so a move-and-rename
  can arrive as one container with items of several types in an undocumented
  order [assumed]. Apply every item of a container, then re-derive the
  mappings once; never depend on order.
- **Payload size.** A scene recall touching many lights produces one very long
  `data:` line (openHAB hit a 4096-byte limit) [community: openHAB]. Our parser
  allows 1 MB per line [verified: `sse.lua` `MAX_LINE`]; fine.
- **What a reconnect misses.** Anything emitted while the stream was down,
  including `add`/`delete`. The abandoned `C4:url` transfer may still deliver
  one stale chunk after the new stream connects [verified: hardware]; the
  resync after connect makes that harmless. Whether `Last-Event-ID` replays
  anything is unconfirmed; do not design around it, but sending the header
  costs nothing.
- **Resync set.** Today: `/light`, `/device`, `/zigbee_connectivity`. For the
  planned features add `/room`, `/zone`, `/bridge_home`, `/scene`,
  `/smart_scene` (and `/grouped_light` if room devices come later). Either
  eight serial GETs or one `GET /clip/v2/resource` returning everything
  [verified: CLIP API list; aiohue does the single GET]. The single GET is
  simpler and one transfer; measure its size on the house bridge first.
- **Reconciliation after every resync**, in this order:
  1. Lights: registry rid not in GET → mark `gone`, `ONLINE_CHANGED false`,
     surface; rid back again → clear `gone`. New rids → Detected list, with a
     MAC-match hint against `gone` entries. Caps/name/model refresh as today.
  2. Devices → rooms: rebuild device → room from `room.children`; light →
     zones from `zone.children`; update each light's Hue Room property and
     the mapping labels.
  3. Scenes/smart scenes: registry rid missing → orphan the switch; new →
     Available list; `status.active` / `state` → switch state.
  4. Only then send the per-light full `HUE_STATE` (reason `resync`).
- **Event volume.** 47 lights means a scene recall fans out ~47
  `SendToDevice` calls plus grouped_light items; a dynamic scene keeps that up
  at 1 container/s. Measured so far: 47 state messages in 270 ms [verified:
  hardware]. Fine, but scene-status mirroring must not add a GET per event.

## 6. Naming

| Topic | Hue | Driver |
| --- | --- | --- |
| Which name the user sees | The Hue app shows the **device** name; the `light.metadata` block is marked "Deprecated, use metadata on device level" [community: openhue reproducing Signify's reference]. For single-light devices both names are the same [assumed]; for multi-service devices each light has its own name [community: aiohue]. | Import uses `light.metadata.name` today; switch to the device name when `service_id == 0` and the device has one light, else the light's own name. Record both. |
| Limits | `metadata.name` 1–32 characters on device, room, scene and smart scene [community: openhue]; UTF-8 allowed [assumed]. | Composer names have their own rules; truncate nothing, just copy. |
| Duplicates | Nothing prevents two lights or two scenes with the same name, and scenes with the same name in different rooms are the norm ("Relax" everywhere) [assumed]. | Lists must show "name (room)" and carry the rid behind the label; `C4:UpdatePropertyList` entries must be unique strings, so append the short rid when two labels collide. |
| Renames | Device/light/scene/room renames are plain `update`s; rid unchanged. | Registry label refresh; Composer untouched; **Sync names from Hue** action renames bound devices with `C4:RenameDevice` only when the owner runs it. |
| Default names | New bulbs come as "Hue color lamp 1" etc. until renamed in the app. | Show as is in the Detected list; nothing to normalise. |

## 7. Control4-side counterparts

The same "detect, record, offer" rule seen from Composer. All DriverWorks
facts here are from `docs/design.md` and `docs/lights-design.md` unless
marked.

| Case | What happens | Driver reaction |
| --- | --- | --- |
| **Owner deletes a Hue Light device in Composer** | The binding disappears: `C4:GetBoundConsumerDevices` no longer lists the id and no `HUE_HELLO` ever comes [verified: hardware for the listing]. The registry still maps the rid to a dead device id. | At startup and after each import/resync, compare registry device ids with the bound set; entries whose device is gone become `unbound` (not deleted) and the rid returns to the Detected list. A **Forget unbound** action drops them. Never re-create the device. |
| **Owner re-adds a light for a rid that is `unbound`** | The add-one-light action creates a fresh device with a new device id and proxy id. | Replace the registry entry's ids; send `HUE_CONFIGURE` and full state. |
| **Owner deletes a scene switch in Composer** | Same as a light: the switch registry entry points at nothing. | Same `unbound` handling for the scene registry. |
| **Bridge driver updated in place** | Persisted values survive, the device id does not change [verified: hardware]. | Nothing; registries reload at late init. |
| **Bridge driver deleted and re-added** | New device id, new sandbox, all persisted values lost [verified: hardware]; the light devices remain bound to a binding that no longer exists. | On a fresh bridge with lights already bound (`GetBoundConsumerDevices` non-empty but registry empty), rebuild from the lights: each light answers `HUE_HELLO` with its own persisted `hue_rid`, so the registry can be reconstructed rid by rid [assumed: the light's `hue_rid` survives, since the light's device id is unchanged]. Pairing has to be redone (the key is gone). Document "update in place, never delete" prominently. |
| **Light driver updated in place** | The light keeps its device id and persisted `hue_rid`. | It greets with `HUE_HELLO rid`; the bridge answers as today. |
| **Owner moves a Control4 light to another Composer room** | Nothing on the Hue side. | Nothing. The Hue Room property is informational; the two room systems are allowed to disagree. |
| **Owner renames a Control4 light** | Nothing on the Hue side. | Nothing. A future **Push names to Hue** action could PUT `metadata.name` on the device, but only on request. |
| **Programming references a scene switch or light that is later orphaned** | Composer programming keeps the device; commands reach a driver whose rid is `gone`. | The driver logs "<name>: deleted on the bridge; command ignored" once per minute at most, and the `Status` property says so. |

## 8. What the registry must record

Fields the cases above need, per light (`hue_lights`) and per scene switch
(`hue_scenes`), in addition to what exists today:

| Field | Needed by | Source |
| --- | --- | --- |
| `rid` (key), `device_id`, `proxy_id` | everything | today |
| `bridge_id` | §4 bridge replacement, two bridges | `/api/0/config` |
| `device_rid` | §1 deletes that arrive as device deletes; §2 room derivation | `light.owner.rid` |
| `mac_address` | §1 re-add detection, §4 factory reset | `zigbee_connectivity.mac_address` of the owner device |
| `name` (light), `device_name` | §6 naming, Sync names | `light.metadata.name`, `device.metadata.name` |
| `service_id` | §1 multi-service devices | `light.service_id` |
| `model`, `caps` | `HUE_CONFIGURE`, limits | today |
| `hue_room_rid` (derived, not persisted) | §2 Hue Room property, mapping | `room.children` |
| `state`: `bound` / `gone` / `unbound`, with a timestamp | §1, §4, §7 | reconciliation |
| scene switch: `rid`, `group_rid`, `group_type`, `kind` (`scene`/`smart_scene`), `recall_action` (`active`/`static`/`dynamic_palette`), `off_behaviour` (`none`/`group_off`), `name`, `state` | §3 | `/scene`, `/smart_scene`, owner's choices |

The Detected-lights and Available-scenes lists are not persisted: they are
rebuilt from the last resync and shown through `C4:UpdatePropertyList`, with
labels "name (room) [short rid]" when two labels collide.

## 9. Tests to run through the dev loop

All through `devctl.py run "Hue Request" Method=... Path=... Body=...` with
whole-container debug logging switched on, plus a spare bulb for the
physical cases.

1. Spare bulb: add in the app → record every container for 60 s; delete in
   the app → same; re-add → compare rids and `mac_address`.
2. Rename a light via PUT `/device/<id>` and via PUT `/light/<id>`; see which
   resources update and whether the app shows each.
3. Move a device between two rooms with PUT `/room/<id>` `{"children":[…]}`;
   check both rooms' events and the scenes' `last_actions_update`.
4. POST a throwaway zone with two lights, create a scene in it via POST
   `/scene`, recall it with each `action`, change one light by hand, recall
   another scene, then DELETE the zone; log the scene `status` events and
   the delete cascade.
5. Recall a scene from the Hue app and from a Hue dimmer; confirm the scene
   `status` update arrives either way.
6. Activate and deactivate a smart scene; watch `state`, `active_timeslot`
   and the target scenes' status.
7. Call with a bogus key: record status code and body.
8. Measure `GET /clip/v2/resource` size and time on the house bridge.
9. Run a dynamic scene on the largest room for five minutes; watch SSE line
   lengths, fan-out timing and Director's log volume.

## 10. The ten cases that must shape the design

1. **Deleting a bulb produces new rids on re-add.** The registry needs a
   `gone` state, a Relink action, and `zigbee_connectivity.mac_address`
   stored per light as the recovery key. No auto-create, no auto-delete.
2. **Room membership lives on the device, not the light, and changes
   silently.** The Hue room is an add-time hint for the Control4 room and a
   live property afterwards; the driver never moves Control4 devices. The
   mapping is keyed by room rid.
3. **Scenes belong to a room or zone and die with it.** Scene switches need
   the same orphan/Relink/Forget handling as lights; the Available list is
   grouped by room/zone with rids behind the labels.
4. **Scene status is pushed by the bridge** (`static`/`dynamic_palette`/
   `inactive`, and `inactive` when any light in the group changes). Mirror
   it onto the switch; expect it in the same container as grouped_light
   updates; verify the app and Hue-switch trigger paths.
5. **Recall is a PUT with `recall.action`** (`active` honours
   `auto_dynamic`; `static` never animates; `dynamic_palette` always does),
   optional `duration` and `dimming.brightness`. Smart scenes use
   `activate`/`deactivate` and report `state`.
6. **Deletes are bare ids; adds may be split; order is undocumented.** Every
   event handler must be idempotent and resolve relationships through the
   cache, and the resync after every connect is the real source of truth.
7. **The resync must grow** to rooms, zones, bridge_home, scenes and smart
   scenes, with an explicit reconciliation pass (gone / new / moved /
   orphaned) before state fan-out. Consider the single
   `GET /clip/v2/resource`.
8. **Bridge replacement may keep rids and keys or may not.** Detect it via
   bridge id and `replacesbridgeid`, offer adoption, then reconcile; never
   wipe the registry on a mismatch.
9. **Names are display only, 1–32 chars, duplicates allowed, device name is
   the one users know.** Never key on names or `id_v1`; renames in Composer
   happen only through an explicit Sync names action.
10. **Group operations have their own rate limit (1/s) and grouped_light
    events accompany every change.** Scene-status mirroring and any room
    device must consume what the stream already carries and never add GETs
    or grouped PUTs per event.
