# Review of the owner's manual (`src/hue_bridge/www/documentation.html`), 2026-10-24

Read-only review of the Hue Bridge Documentation tab against the code on
`release-prep` (HEAD 7878e02, build 221 by commit count) before the 1.0
release. Method: every one of the manual's 659 `<code>` texts was grepped
against `src/` (307 found byte-for-byte, the rest are `string.format`
examples, each checked against its format string by hand); `driver.xml` of the
three drivers, `driver.lua`, `bridge/*.lua`, `common/device.lua`,
`hue_light/driver.lua`, `hue_scene/driver.lua`, the specs under `tests/spec`
and the 24 screenshots under `www/img/` were read in full. Line numbers are
those of the manual as it stands at 7878e02. The device pages
(`hue_light/www`, `hue_scene/www`) were read for cross-references only; they
agree with the manual on every point they share, so the findings below are
the bridge manual's alone.

## Findings, ranked

Categories: **wrong** (the text claims something the code does not do),
**stale** (true of an earlier build, not of this one), **missing** (a text or
case the owner will meet that the manual lacks), **unclear**. A finding on a
picture is never a blocker; the caption fix is given for each.

| # | Category | Chapter, line | The manual says | What the code does | Replacement text |
|---|---|---|---|---|---|
| 1 | wrong | 4, l. 171 ("Step 2: enter it in Composer") | After an invalid `Bridge IP Address` while paired, "The pairing itself is kept, so a corrected address brings everything back within seconds." | `driver.lua` `Bridge_IP_Address`: the invalid entry stops the stream (`restart_stream()` with no connection, Event Stream `Stopped`). The corrected address calls `choose_stream_address(function() restart_stream(was_running) end)` with `was_running = false` (the stream was stopped by the invalid entry), so `restart_stream` builds a new stream and does **not** start it: `Event Stream` stays `Stopped` until **Connect Event Stream** is clicked or the driver restarts. No spec covers the case (`drivers_spec` "ignores an invalid IP" tests the unpaired case only). | Either fix the code (treat a stream stopped by an invalid entry as running, so the valid entry restarts it; one flag in the property handler) and leave the text, or change the text to: "The pairing itself is kept; set a valid address again, then click **Connect Event Stream** on the Actions tab (the feed does not restart by itself after an invalid entry) and everything is back within seconds." The coordinator's call; the code fix is the better one, since the sentence describes what a reader expects. |
| 2 | wrong | 12, l. 683–684 (Event Stream rows); 4, l. 204 | `Disconnected: server closed the stream (HTTP 200). Reconnecting in 1 s`: "Once every **Stream Timeout (s)** it is the driver's own reopening; repeating within seconds means the bridge is rebooting". `transfer error 28` is explained only as "the controller's 'no answer in time'" and, repeating, "unreachable or moved". | `stream.lua` `handle_done`: a transfer that reaches its `timeout` ends with curl error 28, so the driver's own reopening every Stream Timeout reads `Disconnected: transfer error 28: Operation timed out …. Reconnecting in 1 s` (`docs/spike-checklist.md` l. 60–61 and `docs/design.md` l. 164 record exactly that on the controller). `server closed the stream (HTTP 200)` is a clean close by the bridge (reboot, firmware update), never the driver's. In a quiet house the watchdog (600 s of silence) and the stream timeout (600 s of life) race; the owner sees one or the other every ten minutes. | Row HTTP 200: "The bridge ended the feed itself (a reboot or a firmware update). Repeating within seconds means the bridge is restarting; wait." Row error 28: split into two rows: `Disconnected: transfer error 28: …. Reconnecting in 1 s`, once every **Stream Timeout (s)**: "Normal: the driver's own reopening of the feed at the end of a connection's lifetime (the controller reports it as error 28, 'Operation timed out'). Nothing to do." and `…. Reconnecting in 60 s` (repeating): as now. Chapter 4 l. 204: add "(it is also how a connection that reached **Stream Timeout (s)** ends, once every ten minutes)". |
| 3 | stale | 9.1, l. 481–490 (the whole "Scenes line" table); 4, l. 188 | `Scenes` reads `125 scenes and 15 time-based on bridge, 3 imported, 0 missing, 0 unbound, 0 deleted`, "the same fields as Lights without new", with `0 missing` and `0 unbound` rows as always shown. | `scenes.lua` `summary()` (since build 185, "properties that fit the column"): `125 + 15 time-based on bridge, 3 imported, 0 deleted`; `N missing` and `N unbound` only when not zero; `125 + ? time-based on bridge` until the first successful `/smart_scene` read. Chapter 5 l. 232 and 9.7 l. 552 already have the new wording, so the manual contradicts itself. | 9.1: "**Scenes** reads `125 + 15 time-based on bridge, 3 imported, 0 deleted`: ordinary and time-of-day scenes on the bridge (the second number is `?` until the time-of-day scenes have been read once), the devices of both kinds the bridge manages, and the devices you deleted in Composer; `1 missing` and `1 unbound` are added only when they are not zero (**Attention** lists them then)." Table rows: `125 + 15 time-based on bridge` / `3 imported` / `1 missing` (only when not zero) / `1 unbound` (only when not zero) / `0 deleted`. Chapter 4 l. 188: `125 + 15 time-based on bridge, 0 imported, 0 deleted`. |
| 4 | stale | 8.2, l. 382, 383, 386; 8.6, l. 426–427; 8.9, l. 454 | **Adopt Hue Names**, **Accept Names As They Are** and **Link Devices** results "always have two halves separated by ` \| Scenes: `"; examples end after the scenes' part. | `driver.lua` `join_texts` appends a third part, ` \| Zone lights: …`, whenever the zone-light module returns a text, and it always does (`zone_lights.lua`: `No Composer names differ from the Hue zone and room names`, `No zone light devices are bound to this bridge`, `All 2 bound zone light devices are registered`, `Renamed 1 zone light device: …`, `Accepted 1 zone light name difference: …`, `Linked 1 zone light device: …`). Since build 196. | l. 386: "their **Last Action** always has three parts, the lights' result, then ` \| Scenes: ` and the scenes', then ` \| Zone lights: ` and the zone and room lights' (8.10), for example `No Composer names differ from the Hue names \| Scenes: Renamed 1 scene device: Read → Bedside Lights Read (device 1141) \| Zone lights: No Composer names differ from the Hue zone and room names`." l. 382: `Renamed 1 device: Left Bedside Lamp → Left Bedside Light (device 1142) \| Scenes: No Composer names differ from the Hue scene names \| Zone lights: No Composer names differ from the Hue zone and room names`. l. 383: `Accepted 1 name difference: Left Bedside Lamp (Hue: Left Bedside Light) \| Scenes: No Composer names differ from the Hue scene names \| Zone lights: No Composer names differ from the Hue zone and room names`. l. 426: `All 47 bound devices are registered \| Scenes: All 2 bound scene devices are registered \| Zone lights: All 2 bound zone light devices are registered` (or `… \| Zone lights: No zone light devices are bound to this bridge`). l. 427 and l. 454: the same third part after the quoted texts. |
| 5 | wrong | 8.10, l. 461 | A zone light renamed in Hue: "**Attention** counts the difference together with the lights' (`1 Hue name differs from the Composer names: …`, 8.2)". | `zone_lights.lua` `attention_items()`: an item of its own, `1 zone light name differs from the Composer names: Bedside Lamps is Bedside Lights in Hue (Adopt Hue Names or Accept Names As They Are)`, listed after the lights' and the scenes' items; the lights' count does not include it. | "**Attention** reports it as an item of its own, after the lights' and the scenes': `1 zone light name differs from the Composer names: Bedside Lamps is Bedside Lights in Hue (Adopt Hue Names or Accept Names As They Are)`. **Adopt Hue Names** answers in its third part, `Zone lights: Renamed 1 zone light device: Bedside Lamps → Bedside Lights (device 1180)`, **Accept Names As They Are** with `Zone lights: Accepted 1 zone light name difference: Bedside Lamps (Hue: Bedside Lights)`, and the device's **Adopt Hue Name** as for a light; …" |
| 6 | stale | 12, l. 689 (Stream Address row) | `… (shared queue with commands: no octet below 8 to pad; stream timeout capped at 60 s)` and `… (shared queue with commands: self-check via … failed: …; stream timeout capped at 60 s)`. | `driver.lua` `choose_stream_address` writes `192.168.10.50 (shared queue with commands: no octet below 8 to pad)` or `… (shared queue with commands: self-check failed)`; the "via …: reason" and "stream timeout capped at 60 s" parts go to the Lua output only. Chapter 5 l. 233 has it right. | `… (shared queue with commands: no octet below 8 to pad)` or `… (shared queue with commands: self-check failed)` (the reason of a failed self-check is in the Lua output). Keep the explanation. |
| 7 | wrong | 9.5, l. 529 (Status row) | "a whole-home scene reads `in Home (bridge home)`". | `scenes.lua` `configure_params` sends the group's cached name; `hue_model.group()` leaves the `bridge_home`'s name nil (it has no metadata on the bridge, verified 2026-10-21), so the device gets no `group_name` and `hue_scene/driver.lua` `group_label()` returns nil: Status reads `Hue scene Bright in (no room)` and **Hue Room** is blank. The `(bridge home)` wording exists in the device (`scene_driver_spec` l. 323 feeds it a name) but the bridge never supplies one. The Add Scene list calls such a scene `(all lights): Bright`. | Either the text: "a whole-home scene, listed as `(all lights): Bright` in Add Scene, reads `Hue scene Bright in (no room)` with **Hue Room** blank, because Hue's whole-home group has no name" or a small bridge change (send `group_name` "Home" for a `bridge_home` group in `scenes:configure_params`), after which the manual's text is right. |
| 8 | stale (picture and caption) | 5, l. 241–242 (`bridge-actions.png`) | "the actions in the order of chapter 13's quick reference … (the picture predates Add Zone Light and Re-link Zone Light, so it shows 23 of the 25)". | The picture is a development build (116): it shows **Connection Test**, **Reload Credentials** and **Check CA Pinning**, which a release build does not carry (`tools/build.sh` strips the `DEV-ONLY` block), and lacks the two zone-light actions. A release build has 22 actions; "25" counts the three diagnostics. | Caption: "… **Pair Bridge** at the top and **Forget Pairing** at the bottom. The picture was taken on a development build before **Add Zone Light** and **Re-link Zone Light** existed: it lacks those two and shows three diagnostics (**Connection Test**, **Reload Credentials**, **Check CA Pinning**) that a release build does not have, so a release build shows 22 buttons, not 23. One click on a button runs it. …" Better: a fresh shot from build 199 or later. |
| 9 | stale (picture contradicts caption) | 9.6, l. 545–546 (`scene-actions.png`) | "**Adopt Hue Name** above **Forget This Scene**." | The picture shows **Forget This Scene** above **Adopt Hue Name**: it is from build 116, before `sort_order` was added to the scene actions (commit bc28e9c, 2026-10-22 13:58, "scene actions sorted"). The current `hue_scene/driver.xml` sorts Adopt Hue Name first, as the caption says. | Re-shoot, or caption: "A Hue Scene device's **Actions** tab (an older build; since build 130 **Adopt Hue Name** is above **Forget This Scene**, as on a Hue Light)." |
| 10 | wrong (caption) | 6, l. 299–300 (`room-audit.png`) | "**Last Action** after a **Room Audit**: one line per light that sits in a different Control4 room than its Hue room suggests, each ending in the room to drag it to. The driver only reports; you drag." | The picture shows the nothing-to-do result, `All 1 linked lights in mapped Hue rooms are in the rooms their Hue rooms map…`, in the pre-2026-10-22 wording; the current text for one light is `All 1 linked light in a mapped Hue room is in the room its Hue room maps to` (`lights.lua` `room_audit`). | Caption: "**Last Action** after a **Room Audit** with nothing to drag: every checked light is in the room its Hue room maps to (an older build's wording; today it reads `All 1 linked light in a mapped Hue room is in the room its Hue room maps to`). With differences the row holds one line per light, each ending in the room to drag it to; the driver only reports, you drag." Or re-shoot with a to-do line. |
| 11 | stale | 5, l. 219–239 (table order) | "In the order Composer shows them", with **Zone Lights** placed after **Last Event**. | `hue_bridge/driver.xml` declares **Zone Lights** right after **Scenes** (before **Stream Address**), and Composer lists properties in `driver.xml` order (every screenshot's order equals the then `driver.xml`). | Move the **Zone Lights** row between **Scenes** and **Stream Address**. The "first Properties page" list in chapter 3 (l. 140–147) is not claimed to be in order and needs no change. |
| 12 | stale (picture) | 4, l. 194–195 (`bridge-properties.png`) | "The Hue Bridge Properties page after pairing. … The exact **Stream Address** text depends on your bridge's address (chapter 5)." | Build 116, a development build: **Diagnostic Server** and **Dev Server** rows (release builds have none), no **Zone Lights** row, **Scenes** in the old wording (`125 on bridge, 2 imported, 0 missing, 0 unbound, 0 deleted`), **Stream Address** in the old wording (`… (own queue, rotating over 7 spellings; commands use …)`), **Room Mappings** as one long clipped text instead of the drop-down, **Stream Watchdog (s)** at 300 rather than the default 600. The **Bridge ID** shown (`001788fffe123abc`) looks like a real one, where the text uses the placeholder `001788fffe123abc`. | Re-shoot on a release build 199 or later (and blank the Bridge ID as the text does), or add to the caption: "The picture is from an early development build: a release build has no **Dev Server** or **Diagnostic Server** rows, has a **Zone Lights** row after **Scenes**, and words **Scenes**, **Stream Address** and **Room Mappings** as chapter 5 describes." |
| 13 | stale (picture) | 8.6, l. 431–432 (`connections.png`) | The caption describes the **Hue Bridge** input only; chapter 11 (l. 634) sends the reader to the same view for the **Top**, **Bottom** and **Toggle Button Link** rows "listed under its Control Outputs". | The picture's Control Outputs show only the proxy's **Brightness Stop Button Link** and **Color Stop Button Link**; the three Button Links of `hue_light/driver.xml` (connections 200–202, added with the keypad feature) are not in it. | Caption, add: "The picture predates the keypad feature: today the Control Outputs also list **Top Button Link**, **Bottom Button Link** and **Toggle Button Link** (chapter 11)." Or re-shoot. |
| 14 | stale (picture) | 9.2, l. 499–500 (`add-scene.png`) | "each entry is `Room: Scene`, zones marked `(zone)`, dynamic scenes marked `(dynamic)`." | No `(dynamic)` mark is visible in the picture, and it predates build 180: a current list puts each room's or zone's time-of-day scenes first, marked `(time-based)`, and marks the ordinary scenes a schedule plays `(in Golden hours)` (`scenes.lua` `picker_scenes`). | Caption: "… zones marked `(zone)`. The picture predates time-of-day scenes: today each room's or zone's time-of-day scenes come first, marked `(time-based)`, scenes a schedule plays carry `(in …)`, and a scene Hue plays as changing colours ends in `(dynamic)`." |
| 15 | wrong (minor) | 9.9, l. 559 | "The scenes' half of the Link Devices result reads `Linked 1 device: … by name`". | `scenes.lua` `link_devices`: `Linked 1 scene device: Nightlight (device 1140) to Bedside Lights (zone): Nightlight by name` (the plural is "scene device"); the zone lights' part reads `Linked 1 zone light device: …`. | `Linked 1 scene device: … by name`, `All 2 bound scene devices are registered` or `No scene devices are bound to this bridge`. |
| 16 | missing | 12, l. 703–704, 712, 718; l. 690–701 (Attention rows) | The Last Action and Attention tables list the light and scene texts only. | Zone-light texts the owner can meet (`zone_lights.lua`, `driver.lua`): `Busy: adding a zone light; try again in a moment`, `Busy: resyncing zone lights; try again in a moment`; `Not added: pick a zone or room first`; `Not re-linked: pick a device and a zone or room`; `Not re-linked: device … is not a registered zone light`, `Not forgotten: device … is not a registered zone light`; `Not added: zone or room … is not on the bridge (connect the event stream and try again)`, `Not re-linked: zone or room … is not on the bridge (connect the event stream and try again)`; Attention `1 unbound zone light device: … (bind it to this bridge in Composer, or Forget Light)`, `2 devices claim Hue zone …: … (Forget Light on one of them)`, `1 zone light name differs from the Composer names: … (Adopt Hue Names or Accept Names As They Are)`. | Add the zone-light variants to the existing rows (l. 703: the two Busy texts; l. 704: the two "pick" texts; l. 712: the two "not on the bridge" texts; l. 718: the two "not a registered zone light" texts) and three Attention rows after l. 701: unbound zone light device (connect it again, or **Forget Light**, 8.10), two devices claiming one zone (Forget one), zone light name difference (8.10). |
| 17 | missing | 7, l. 351 (Group list) | "With nothing to offer the list holds only `(no zones or rooms on the bridge)`." | `zone_lights.lua` `picker_groups`: `(no zones or rooms on the bridge)` only when the bridge has none; when every zone and room already has a device it holds `(every zone and room on the bridge is imported)`. | "When every zone and room has a device the list holds only `(every zone and room on the bridge is imported)`; with no zone or room on the bridge at all, `(no zones or rooms on the bridge)`." |
| 18 | unclear | 9.3, l. 507 and 9.11, l. 567 | "a room or zone with time-of-day scenes counts those too, `Downstairs (zone) → (unmapped) (16 scenes, 2 time-based)`". | `scenes.lua` `picker_groups` counts the kinds separately: `16 scenes` are the ordinary ones and `2 time-based` the time-of-day ones (18 in all); `imported` counts both kinds. The "nothing new" result for such a group reads `No new scenes in Downstairs (zone) (16 scenes and 2 time-based on bridge, 18 imported)`. | "a room or zone with time-of-day scenes lists them separately: `Downstairs (zone) → (unmapped) (16 scenes, 2 time-based)` means 16 ordinary scenes and 2 time-of-day ones (`, N imported` counts both kinds)"; 9.3 l. 512, add: "for a room with time-of-day scenes `No new scenes in Downstairs (zone) (16 scenes and 2 time-based on bridge, 18 imported)`". |
| 19 | unclear | 5, l. 230 (Last Action row) | "Every click ends here, whether it worked or not." | **Pair Bridge** and **Test Connection** report in **Status**, **Connect** / **Disconnect Event Stream** in **Event Stream**, **Forget Pairing** in both; chapter 13's "Reports in" column is right. | "Every click on an action with a dialog, and every list action, ends here, whether it worked or not; **Pair Bridge** and **Test Connection** report in **Status**, the two event-stream actions and **Forget Pairing** in **Event Stream** (chapter 13)." |
| 20 | stale | 5, l. 223 (Status row); 12, l. 702 | "the results of Test Connection and the diagnostics actions (chapter 12)"; "Every action except pairing needs a paired bridge first" (`Not paired` in Last Action). | A release build has no diagnostics actions besides **Test Connection** (the three others are development-only, as 3 l. 161 and 12 l. 772 say). `Not paired` in **Last Action** comes from the list actions (`driver.lua` `can()`); **Test Connection** writes it to **Status**, **Connect Event Stream** to **Event Stream**; **Forget Pairing** and the stream actions work unpaired. | l. 223: "the pairing steps of chapter 4 and the result of **Test Connection**". l. 702: "Every action that adds, links, forgets, renames or maps needs a paired bridge first." |
| 21 | unclear | 7, l. 312 | "an import that lost the bridge halfway ends in `…; stopped early: …`; wait for **Event Stream** to say `Connected since` and click again, it carries on where it stopped." | `lights.lua` `import_fetched`: the bridge is read once, before any device is created (`Import failed: …` covers a bridge that cannot be read); `stopped early` is appended when creating a device raised an error in Director (`create_lights` `step`). The devices created before the stop are kept and registered, so a second click continues. | "an import that stopped while creating devices ends in `…; stopped early: …` (the reason is in the Lua output); the devices created up to then are kept, so click again and it carries on where it stopped." |
| 22 | unclear | 4, l. 171 | "Before pairing, an invalid entry is simply ignored: Status keeps saying `Enter the bridge IP address`". | `driver.lua`: an invalid entry drops a valid address set earlier as well (`state.ip = nil`), before pairing too; Status then reads `Enter the bridge IP address` either way. | "Before pairing, an invalid entry only makes Status read `Enter the bridge IP address` (an address entered earlier is dropped); correct the text and click Set again." |
| 23 | missing (minor) | 9.11, l. 585; 9.5, l. 529 | Status of a running time-of-day scene always names the slot: `…; now Shine (from 16:00)` or `…; not running`. | `hue_scene/driver.lua` `smart_status()`: `…; running` while the schedule runs but the slot's scene is not known (a slot scene the bridge's scene list lacks, or no current slot), and the bare `Hue time-based scene Golden hours in Master Bedroom` before any state was reported. | Add after `not running`: "or `…; running` while Hue runs it but the current slot's scene is not known (for a moment after a restart, or when the slot's scene is missing from the bridge)". |
| 24 | missing (minor) | 5, l. 232 | `Scenes` reads `125 + 15 time-based on bridge, …`. | `?` in place of the time-based count until a `/smart_scene` read has succeeded (`scenes.lua` `summary()`). | Add: "(`125 + ? time-based` until the time-of-day scenes have been read once)". Also the first-page list (3, l. 144) is right as it is: `0 imported`. |
| 25 | stale (picture, minor) | 8.5, l. 419–420 (`forget-light.png`) | "every managed device as `Name #number (device number)`". | Zone and room lights follow the lights in the same list as `Bedside Lights (zone light, device 1180)` / `Master Bedroom (room light, device 1182)` (`zone_lights.lua` `picker_forget_devices`; 8.10 says so in prose). | Caption, add: "zone and room lights follow as `Name (zone light, device number)`." |
| 26 | unclear (minor) | 2, l. 85; 9.11 l. 569 | "the Composer name is yours; a difference is only pointed out in **Attention**". | True; but note for completeness that the comparison is against the name the bridge would give the device today (zone prefix, `Lights` suffix, number dropped), which 8.10 and 9.8 say and chapter 2 does not. | l. 85: "(compared with the name the bridge would give the device today: the zone's name in front for a zone scene, `Lights` after a room light's, the Hue app's number dropped)". |

Notes that are not findings: the bridge-properties screenshot (finding 12)
shows an IP placeholder but what looks like a real bridge ID; the release
checklist only forbids LAN addresses, keys and certificates in `src/`, so this
is a taste question for the owner, not a release blocker.

## Verified correct

Checked byte-for-byte or against the format string, and against the specs
where one exists:

- **Properties and defaults** (`hue_bridge/driver.xml`): every property name
  in chapter 5 exists with the type and default the manual gives: `Debug
  Mode` Off/On, `Stream Timeout (s)` 30–86400 default 600, `Stream Watchdog
  (s)` 0–3600 default 600 with the code's floor of 60 (`driver.lua`
  `WATCHDOG_MIN`), the five `DYNAMIC_LIST` rows (a pick snaps back; commas
  drawn as `‚`), `Dev Server` and `Diagnostic Server` only inside the
  `DEV-ONLY` block that `tools/build.sh` strips. The scene device's `Recall
  As` list and default, and the light and scene property orders in chapter 10
  and 9.5, match their `driver.xml`.
- **Actions**: the 22 release actions in chapter 13's quick reference are in
  `driver.xml` `sort_order` order with the parameter names and order the
  dialogs show (`Light`/`Room`, `Group`/`Room`, `Device`/`Light`,
  `Device`/`Group`, `Device`, `Hue Room`/`Room`, `Scene`/`Room`, `Hue Room`,
  `Device`/`Scene`); the three dev-only actions are inside the stripped
  block; the device actions `Adopt Hue Name` / `Forget This Light` /
  `Forget This Scene` exist and sort as chapter 10 and 9.6 say.
- **Status, Event Stream, Stream Address, pairing and Test Connection texts**
  (`driver.lua`, `stream.lua`, `pairing.lua`): `Enter the bridge IP address`,
  `Not paired: press the link button, then run Pair Bridge`, `Paired`,
  `Enter the bridge IP address first`, `Pairing: contacting bridge`,
  `Pairing: found BSB003 …, requesting key`, `Press the link button on the
  bridge, then run Pair Bridge again`, the three `Pairing failed:` forms,
  `Testing: GET /clip/v2/resource/bridge via …`, `Test OK: HTTP 200 via … in
  N s, bridge …`, `Test failed: key rejected (HTTP 401). Re-pair with Pair
  Bridge`, `Test failed: bridge reports ID …, expected …`, `Not paired`,
  `Waiting for IP address`, `Connecting`, `Connected since …`, `Connected
  since …, N containers, last …`, `Disconnected: <reason>. Reconnecting in N
  s` with the reasons `watchdog: no data for 600 s`, `server closed the
  stream (HTTP 200)`, `transfer error 28: …`, `HTTP 401`, `aborted`,
  `oversized line in stream`, `Stopped`; backoff 1 s doubling to 60; the
  chapter 5 `Stream Address` forms (`own queue, the only spelling` for one
  octet below 8, `spelling 1 of 7` for two, `shared queue with commands: no
  octet below 8 to pad`); Forget Pairing's clearing of Bridge ID, Bridge
  Model, Stream Address, Last Event and Events Received; the IPv4 rule
  (dotted quad, no leading zeros, 0–255, `config.lua`).
- **Lights, Room Mappings, Attention, Last Action** (`lights.lua`): the
  `Lights` summary and its `0 imported` / `47 imported` form before the first
  read; every list line form (`Kitchen: Island Pendant → device 2051`,
  `(new)`, `(missing; device N)`, `(unbound; device N)`, `(deleted from
  Composer <date>)`); the Room Mappings summary, lines, `(unmapped)`,
  `(Control4 room gone)`, `(deleted in Hue)`, `None; use Map Rooms By Name`;
  every Attention item of chapters 4, 6, 8 and 12 for lights and scenes
  including `+N more` after three names; Map Rooms By Name, Set Room Mapping
  and Room Audit texts and pickers (`(no mapping)`, `Floor / Room`, the id
  after a shared name); Import All New Lights and Add Light results,
  refusals, pickers (`(mapped room)`, the re-link hint, deleted-last order,
  `(every light on the bridge is imported)`, `(no lights fetched yet; …)`),
  the two `Busy:` texts; Re-link Device To Light, Link Devices, Forget Light,
  Adopt Hue Names and Accept Names As They Are texts and pickers (apart from
  the third part, finding 4); the one-time automatic Map Rooms By Name
  (`automap_once`, persisted flag); tombstones and the "no Hue Light left"
  exception of 8.4.
- **Zone lights** (`zone_lights.lua`, `hue_light/driver.lua`): the `Zone
  Lights` summary and list lines, the Group picker lines, Add Zone Light's
  result and every refusal quoted in chapter 7, Re-link Zone Light's picker
  and result, Forget Light's zone text, the device texts `Hue zone Bedside
  Lights (2 lights)`, `Hue room Master Bedroom (9 lights)`, `zone #2
  (b90ea7b4…)`, `Hue zone (2 lights)`, `Bedside Lights (zone)` as Hue Room,
  `Hue zone Bedside Lights has no lights; nothing to control`, `Zone deleted
  in Hue since …; re-link or Forget`, `Room deleted in Hue since …`,
  `Forgotten by the bridge (was Hue zone Bedside Lights)` with the
  instruction in Last Action (`light_driver_spec` pins them); ON = 100 % on
  every lamp, absolute slider, relative holds, colour to the group, the
  union of capabilities and the shared mirek range, the first lit lamp's
  colour, one request a second with a burst of three (`commands.lua`,
  `new_group_queue`), the `Lights` of a room light named `<Room> Lights` and
  never reported as a difference.
- **Scenes and time-of-day scenes** (`scenes.lua`, `hue_scene/driver.lua`):
  the Add Scene, Add All Scenes Of Room, Re-link Scene, Forget Scene and
  Refresh Scenes texts, pickers and refusals of chapter 9 and 12 (apart from
  findings 3, 15, 18); the list lines of chapter 5; `Hue scene Nightlight in
  Bedside Lights (zone)`, the bare name before the bridge answers, `Scene
  deleted in Hue since …; ON does nothing; re-link or Forget`, `Forgotten by
  the bridge (was Hue scene …). Delete this device …`, `#AbCd… (0f3a2b1c…)`
  and the long identifier alone for a time-of-day scene, `Hue time-based
  scene Golden hours in Master Bedroom; now Shine (from 16:00)` / `(from
  sunset)` / `; not running`, Recall As hidden on a time-of-day scene
  (`SetPropertyAttribs`), the Online rule, the two device actions' texts;
  `Recall failed: HTTP 404 (scene gone?)` in the Lua output; ON one request
  with a two-second fallback and no retry, OFF and levels through the retried
  group queue, 100 % from off as designed, a level from off as a brightness
  override, relative moves while on, one level report a second, the on rule
  persisted (`held_on`), a time-of-day scene on exactly while Hue's state is
  active, a start from off followed by the level within 1.5 s, holds from off
  at 1 % (ordinary) or from the slot's level (time-of-day), the schedule
  surviving a whole-room dim, the base-name rule (`Golden hours 4` →
  `Golden hours`, zone prefix), `(time-based)` first in each group and `(in
  …)` marks.
- **Keypads and LEDs** (`hue_light/driver.lua`, `hue_scene/driver.lua`,
  `common/device.lua`): hold after 400 ms ("about half a second"), the
  defaults 100 % / 250 ms / 5 s, blue LEDs with the bottom button lit while
  off, the one-second click guard after a hold, hold-from-off at 1 % then up
  after 600 ms, toggle semantics, the binding re-check at 5, 15, 30 and 60 s,
  `hide_proxy_properties` in both device `driver.xml`,
  `reduced_als_support` / `supports_brightness_stop` for Advanced Lighting
  Scenes, the Button Link connections 200–202.
- **Command queue** (`commands.lua`): ten a second for lights, retries at
  0.5 s doubling to 8 s on 429/5xx/transport errors, latest value wins, a
  tap's level shown after the ramp plus one second (`FALLBACK_MS`).
- **Chapter structure**: the table of contents, the thirteen `h2` ids, the
  glossary, and every numbered cross-reference (8.1–8.10, 9.1–9.11, the
  named sections of chapters 3, 7 and 11) resolve to an existing heading; the
  `minimum_os_version` 3.3.0 and the three file names match `driver.xml` and
  `tools/build.sh`; the build number as `Driver Version` with the
  `build_version` fallback; the development-build description (two
  properties, three actions) matches the `DEV-ONLY` blocks.
