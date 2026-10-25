# Review: the two device pages, the README set and the install chapters (2026-10-24)

Read-only documentation review on branch `release-prep` (HEAD 7878e02, commit
count 221) before the 1.0 release. Reviewed against the code as it is now:

1. `src/hue_light/www/documentation.html` against `src/hue_light/driver.lua`,
   `src/hue_light/light/{caps,state}.lua`, `src/common/device.lua`,
   `src/hue_light/driver.xml`, and the bridge side that feeds the device
   (`bridge/zone_lights.lua`, `bridge/hue_model.lua`, `bridge/lights.lua`,
   `bridge/commands.lua`).
2. `src/hue_scene/www/documentation.html` against `src/hue_scene/driver.lua`,
   `src/common/device.lua`, `src/hue_scene/driver.xml` and `bridge/scenes.lua`.
3. `README.md`, `CONTRIBUTING.md`, `NOTICE`, `docs/README.md` against the code,
   `tools/build.sh`, `docs/status.md`, `docs/licensing-research.md` and the
   bridge manual's chapters 3 and 4.

Every `<code>` and backticked text was grepped in `src/`; every relative link,
image path and file path in the three Markdown files was resolved; the four
repository files were grepped for addresses, ids, keys and paths; the two README
screenshots were viewed; `luacheck src tests tools` (0 warnings, 60 files) and
`busted tests` (1124 successes) were run. Nothing was edited; no git, no build,
nothing against the controller or the bridge.

## Findings, ranked

Categories: **wrong** (says something the code does not do), **stale** (was true
of an earlier build), **missing** (a reader needs it and it is not there),
**unclear** (true but misleading or unverified), **private** (house data).
Line numbers are those of the files at HEAD.

| # | Category | Document, section, line | Text now | What the code does | Replacement |
|---|---|---|---|---|---|
| 1 | wrong | `README.md`, "Install in Composer Pro", lines 120-122 | "The **Documentation** tab of every device holds the full owner's manual (`src/hue_bridge/www/documentation.html`); its chapters 3 to 7 and 9 are the long version of this list." | Each `driver.xml` points its Documentation tab at its own `www/documentation.html`. Only the bridge's is the manual (876 lines, 13 chapters, screenshots); the Hue Light and Hue Scene tabs hold one-page device summaries that themselves say "The full manual, with pictures, is on the Hue Bridge device" (`docs/status.md`: "Documentation tab in every driver (the owner's manual on the bridge)"). A reader who selects a light to find chapter 8 finds a page without chapters. | "The **Documentation** tab of the **Hue Bridge** device holds the full owner's manual (`src/hue_bridge/www/documentation.html`); a Hue Light or Hue Scene device's Documentation tab is a one-page summary of that device. The manual's chapters 3 to 7 and 9 are the long version of this list." |
| 2 | wrong | `src/hue_light/www/documentation.html` line 77 and `src/hue_scene/www/documentation.html` line 93 (footer; the bridge manual has the same line at 873) | `<p class="caption">Hue Bridge, Hue Light and Hue Scene drivers. Private, not for distribution.</p>` | The three `driver.xml` (line 2) now say "Licensed under the Apache License, Version 2.0 (see LICENSE). Not affiliated with Signify or Snap One", `LICENSE`/`NOTICE` exist, and the pages ship inside every `.c4z` and are what a user reads in Composer. `docs/licensing-research.md` §1 (Manuals row) asks for "a one-line license and non-affiliation notice before `</body>`" in all three. | `<p class="caption">Hue Bridge, Hue Light and Hue Scene drivers for Control4. Copyright 2026 Cory Fair; licensed under the Apache License, Version 2.0 (the LICENSE and NOTICE files that come with the drivers). Philips Hue and Hue are trademarks of Signify Holding B.V.; Control4 and Composer are trademarks of Snap One, LLC. This project is not affiliated with, endorsed by or supported by Signify or Snap One.</p>` (the same line in the bridge manual at 873). |
| 3 | missing | `tools/build.sh` lines 42-62, and `README.md` "Build from source" line 97 / "License" line 272 | `cp -R "$ROOT/src/$driver" "$stage"` … `cp -R "$ROOT/src/common" "$stage/common"`; nothing copies `LICENSE` or `NOTICE`. The `driver.xml` copyright line says "(see LICENSE)". | `unzip -l build/release/hue_bridge.c4z` (build 199) and `build/hue_light.c4z` list no `LICENSE` and no `NOTICE`; a downloaded `.c4z` therefore carries a notice that points at a file it does not contain, and does not satisfy Apache §4(a)/(d) on its own. `docs/licensing-research.md` §5 item 5 and §6 step 5 ask build.sh to stage both and to check with `unzip -l`. | In `tools/build.sh`, after the `cp -R "$ROOT/src/common" "$stage/common"` line: `cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$stage/"` (the manifest loop already lists every staged file). In README "Build from source", after "set `DP3=…` if the packager lives elsewhere.": "Each `.c4z` carries the `LICENSE` and `NOTICE` files." Add "`unzip -l build/hue_bridge.c4z` lists `LICENSE` and `NOTICE`" to `docs/release-checklist.md` §0. |
| 4 | private, stale | `README.md` line 169, image `src/hue_bridge/www/img/room-mappings.png` (and `CONTRIBUTING.md` line 35, which promises demo-project screenshots) | `![The Room Mappings drop-down open on the Hue Bridge's Properties page](src/hue_bridge/www/img/room-mappings.png)` | Viewed: the drop-down lists the house's Hue rooms and zones (Basement Hallway, Basement Kitchen, Basement Living, Basement Stairwell, Dining, Foyer, Guest Bath, Kitchen, Living Room, Master Bathroom, Master Bedroom, Mud Room, Office, Patio, Study, Upstairs Hallway; zones Attic, Basement, Bedside Lights, Downstairs, Mini Bar, Upstairs, Whole House) — research finding P5 — and the property rows below it include **Diagnostic Server** and **Dev Server**, which a release build no longer has (manual chapter 3, "Release and development builds"), so the picture also shows a development build. The README's own HTML comment (lines 156-165) says it "is to be re-taken on a demo project before the repository goes public". `add-driver-menu.png` (line 167) is clean. | Re-take the screenshot on a demo project with invented room names on a release build (no Dev Server rows), or publish with `add-driver-menu.png` alone and the caption-less line removed until the demo shot exists. Keep CONTRIBUTING line 35 as the rule. |
| 5 | stale | `src/hue_scene/www/documentation.html`, "Status texts", line 88 (`Bound; waiting for the bridge` row); the bridge manual repeats it in 9.9, line 559 | "otherwise click **Link Devices** on the bridge, with the device named exactly like the scene's *plain* name (`Nightlight`, not `Bedside Lights Nightlight`); **Adopt Hue Name** afterwards adds the zone's name." | `scenes:link_devices` (`bridge/scenes.lua` 2266-2330) calls `match_unimported_by_name({ composer, hello.name })`, which (2243-2257) matches the Hue name, a time-based scene's base name **or the creation name** (`"<Zone> <Scene>"` from `scenes:creation_name`). A device called `Bedside Lights Nightlight` is therefore matched too; "not `Bedside Lights Nightlight`" is false. | "otherwise click **Link Devices** on the bridge, which matches the device by name: the scene's own name (`Nightlight`), the name the bridge would give the device (`Bedside Lights Nightlight` for a zone scene, `Golden hours` for a time-of-day scene) or the Hue app's name with its number; a device matched by the plain name gets the full one with **Adopt Hue Name**." Same change in the bridge manual 9.9. |
| 6 | missing (release time) | `README.md`, "The release", lines 82-89 | "The release is **1.0 (build N)**" with the HTML comment "At release time: replace 'build N'". | `tools/build.sh` sets `<version>` to `git rev-list --count HEAD` (221 at this HEAD, so the release build will be 222 or later after the coordinator's commits); `docs/release-checklist.md` "Naming" wants "1.0 (build N)" in the README **and** the status page, and `docs/status.md` has no "1.0" line at all. | Replace `N` with the build number of the files attached to the GitHub release (the `<version>` inside their `driver.xml`), and add to `docs/status.md`'s first line: "Release **1.0 (build N)**, tag `v1.0`." Remove the HTML comment afterwards. |
| 7 | stale | `README.md`, "Repository layout", line 240 | `src/common/        modules shared by the three drivers (dispatch, log)` | `src/common/` holds `dispatch.lua`, `log.lua`, `device.lua` (the light and scene drivers' shared plumbing, added 2026-10-24; `build.sh` lines 56-59 leave it out of the bridge package) and `devloop.lua` (dev builds only; `build.sh` line 51 removes it from release builds); `build.sh` line 62 adds `build_version.lua`. | `src/common/        shared modules: dispatch and log (all three drivers), device (what the light and scene drivers share: proxy, keypad, LEDs, binding re-check), devloop (development builds only); build.sh adds build_version.lua` |
| 8 | unclear | `README.md`, "Use it", lines 203-206 | "**Device properties** are written by the bridge: a Hue Light shows Status, Hue Light ID, Hue Name, Model, Online and Hue Room; a Hue Scene shows Hue Scene, Hue Room, Hue Scene ID and Recall As." | `Recall As` is the owner's setting (`hue_scene/driver.xml` lines 63-73, `readonly` false; the manual's "The properties you may change"), not a bridge-written row, and the scene also has Status and Online (`driver.xml` 37-42, 74-79). | "**Device properties** are written by the bridge: a Hue Light shows Status, Hue Light ID, Hue Name, Model, Online and Hue Room; a Hue Scene shows Status, Hue Scene, Hue Room, Hue Scene ID and Online, and has one setting of your own, **Recall As** (how ON plays the scene; click Set after changing it). Each device has two actions, …" |
| 9 | unclear | `README.md`, "License, trademarks and provenance", lines 288-291 (and `CONTRIBUTING.md` lines 19-24) | "the driver was written against Snap One's public DriverWorks documentation, and nothing from Snap One's SDK repositories (code, libraries or documentation text) is included here." | The research's grep (a quoted text followed by `[verified: API` or `[verified: FUND`) still finds one quoted fragment from the API reference, `docs/edge-cases-control4.md:213` ("NO before OnDriverLateInit" [verified: API 22/_25.2]), and `docs/licensing-research.md:20` quotes a doc sentence fragment as its example ("Path to the CA certificate to use for the connection…"). The other seven sentences the research listed are gone. "Public" is also a stretch: the docs are on public GitHub but their `LICENSE.md` calls them confidential and licence-bound (research §2). | Paraphrase the two fragments (`edge-cases-control4.md:213`: "both not allowed before OnDriverLateInit [verified: API 22/_25.2]"; `licensing-research.md:20`: "(three, about the CA-certificate path option)") so the sentence is literally true, and write "Snap One's DriverWorks documentation as published on GitHub" instead of "public DriverWorks documentation". |
| 10 | unclear | `README.md`, "What you need", lines 59-61 | "A **Philips Hue Bridge** (the square version 2 bridge, BSB002) or a **Hue Bridge Pro** (BSB003) on the same network as the controller" | Only a Bridge Pro has ever run it (`docs/status.md`: "Hue Bridge Pro (BSB003), paired"; every hardware verification). The README says which OS was tested but not which bridge. | Add after "but OS 4 has not been tried." (line 58): "Tested with a Hue Bridge Pro; the square version 2 bridge speaks the same CLIP v2 API and is signed by the same root certificates, but has not been tried." |
| 11 | missing | `src/hue_scene/www/documentation.html`, Properties, "Hue Scene" row, line 66 | "The scene's name in the Hue app, for example `Nightlight`." | For a time-based scene the bridge sends the base name (`bridge/scenes.lua` 699: `name = (smart and entry.name ~= nil) and name_of(entry) or entry.name`, `hue_model.base_name` strips the trailing number), so the row reads `Golden hours` while the Hue app shows `Golden hours 4`. The page says this only about the device's Composer name. | "The scene's name in the Hue app, for example `Nightlight`; a time-of-day scene's without the number the Hue app adds to its copies (`Golden hours`, not `Golden hours 4`)." |
| 12 | missing | `src/hue_scene/www/documentation.html`, Properties, "Status" row, line 65, and the "Status texts" table | Lists `…; now Shine (from 16:00)` and `…; not running`. "Other texts are explained below." | `smart_status()` (`hue_scene/driver.lua` 219-232) also produces `Hue time-based scene Golden hours in Master Bedroom; running` (Hue says it runs but has not named the slot) and the head alone, `Hue time-based scene Golden hours in Master Bedroom` (no status reported yet). Neither is explained anywhere on the page. | Append to the Status row: "`…; running` for a moment while Hue has not named the time slot, and the first part alone until the bridge has said whether the schedule runs." |
| 13 | unclear | `src/hue_light/www/documentation.html`, Actions table, lines 55-56 | Adopt Hue Name: "`Not renamed: no Hue name known yet (the bridge has not configured this light)`"; Forget This Light: "`Asked the bridge to forget this light; its answer sets Status` … On a zone or room light it works the same". | Both texts are built with `what()` (`hue_light/driver.lua` 98-106): on a zone light they read `… configured this zone light` and `Asked the bridge to forget this zone light; …`, on a room light `… this room light`. The page promises "the differences are noted where they occur" (line 28) and does not note this one. | Add to the Adopt row: "(on a zone or room light: `… has not configured this zone light` / `… this room light`)" and to the Forget row: "(`Asked the bridge to forget this zone light; its answer sets Status` on a zone light)". |
| 14 | missing | `docs/README.md`, "Reviews", lines 95-111 | Lists the four analyses and the five slim reports. | This review is not listed; `docs/README.md` is the index of the folder. | Add: "- [`reviews/manual-devices-readme-2026-10-24.md`](reviews/manual-devices-readme-2026-10-24.md): the release review of the Hue Light and Hue Scene device pages, the README set and the manual's install chapters against the code, with the corrections applied before 1.0." |
| 15 | stale | `CONTRIBUTING.md`, "Three drivers, one build", lines 57-59 | "`tools/build.sh` stages `src/common/` into each driver and stamps all three with the same build number" | `build.sh` lines 46-59: release builds drop `common/devloop.lua` (and the bridge's `devtools`, `conntest`, `pinning` modules and its DEV-ONLY xml blocks), and the bridge package leaves out `common/device.lua`. | "`tools/build.sh` stages `src/common/` into each driver (the bridge without `device.lua`; release builds without `devloop.lua` and the bridge's development modules) and stamps all three with the same build number (the commit count), so a change to a shared module is a change to all three." |
| 16 | unclear | `CONTRIBUTING.md`, "Reporting a problem", lines 89-91 | "use GitHub's private vulnerability reporting on this repository" | The feature exists only on public repositories and must be switched on (Settings ▸ Code security); the repository is private today (`gh repo view`: isPrivate true) and research §6 step 9 lists the repository settings to make at publication without naming this one. | Keep the sentence and add "enable private vulnerability reporting" to `docs/licensing-research.md` §6 step 9 (or `docs/release-checklist.md`), or soften to "use GitHub's private vulnerability reporting on this repository, if it is enabled, or contact the author privately". |
| 17 | unclear | `src/hue_light/www/documentation.html`, "In Control4", line 35 (last sentence) | "Turning a zone light off also ends any Hue scene playing in that zone, so a Hue Scene device of the same zone goes off with it (the bridge's manual, 9.4)." | By design (the bridge feeds the group's on/off to the scene devices as `HUE_SCENE_GROUP on=false`, which ends the held-on state, `hue_scene/driver.lua` 936-989), but `docs/status.md` "Open" says "Shine's tile going off on a zone OFF … not yet seen by the owner". The manual's chapter 7 hedges a sibling claim ("look rather than assume"); this page states it flat. | "Turning a zone light off also ends any Hue scene playing in that zone, so a Hue Scene device of the same zone should go off with it (the bridge's manual, 9.4; as this is written this had not yet been watched on the house system)." |
| 18 | unclear | `README.md` lines 62-64 and `CONTRIBUTING.md` lines 31-35 | README: a pair of home-router-looking `192.168.x.x` examples, one with a number below 8 and one without; CONTRIBUTING: "the RFC 5737 ranges (…) for any other example address". | The README (and the manual throughout) use home-router-looking examples, which the CONTRIBUTING rule forbids as written; research P12 rates this "None, but prefer RFC 5737". The address rule needs an octet below 8 (`bridge/altaddr.lua` 35), which `192.0.2.7`-style examples also satisfy. | Either keep the README examples and exempt them in CONTRIBUTING: "…for any other example address in code, tests and design notes (the manual and README may use home-network-looking examples)", or switch the README pair to RFC 5737 addresses (the example without a number below 8 has to come from `198.51.100.x`, since `192.0.2.x` and `203.0.113.x` always have one). First the exemption was taken (before 1.0); **resolved 2026-10-25** (#64): the README, the manual and CONTRIBUTING now use `10.0.2.143` and RFC 5737 examples, and the exemption is gone. |

Notes outside the three reviewed sets, found on the way:

- The bridge manual carries the same footer (line 873, finding 2) and the same
  Link Devices sentence (9.9, line 559, finding 5).
- `build/release/*.c4z` (build 199, installed on the house) were built before
  `build.sh` learned to strip the DEV-ONLY blocks: their `driver.xml` still has
  `Dev Server`, and `bridge/conntest.lua`, `bridge/pinning.lua` are inside. The
  files in `build/` from 18:02 are a `--dev` build (devloop, devtools, conntest,
  pinning present). Neither set is a release candidate; build fresh.
- `docs/edge-cases-control4.md:213` is the one remaining SDK quotation
  (finding 9); the seven others the licensing research listed are gone.

## Verified correct

Hue Light page (`src/hue_light/www/documentation.html`):

- Every quoted Status text exists byte for byte in `hue_light/driver.lua`:
  `Not bound to a Hue Bridge` (235), `Bound; waiting for the bridge` (239),
  `Gone from the Hue bridge since %Y-%m-%d %H:%M; re-link or Forget` (181-189),
  `Zone deleted in Hue since %Y-%m-%d; re-link or Forget` / `Room deleted …`
  (181-189), `Hue zone Bedside Lights has no lights; nothing to control`
  (191-193), `Forgotten by the bridge (was Hue light Vanity 3 #92). Delete this
  device in Composer, or bind it again and use Link Devices` (171-176, 48),
  `Forgotten by the bridge (was Hue zone Bedside Lights)` with the instruction
  in Last Action (171-176, 527), `Left Bedside Light (Hue color lamp)` and
  `Porch (unknown model)` (224-229), `Hue zone Bedside Lights (2 lights)` (224-229).
- Property texts: `Hue Light ID` `#46 (e0e51794…)` and `zone #2 (b90ea7b4…)`
  (126-141), the rid alone before the v1 id is known; `Model` `Hue zone (2
  lights)` (143-149); `Hue Room` `Bedside Lights (zone)` for a zone and the bare
  room name for a room light (`hue_model.group_label`, 983-993, via
  `group_configure_params` 1003-1024); `Online` `Online`/`Offline`/blank, Offline
  for a group without lights (`refresh_status` 231-251, `zone_lights:online_of`
  529-543); `Last Action` `Forgotten by the bridge`.
- Action texts: `Renamed device %d to %s`, `Not renamed: no Hue name known yet
  (the bridge has not configured this %s)`, `Asked the bridge to forget this %s;
  its answer sets Status`, `Not sent: not bound to a Hue Bridge` (548-574); a room
  light renamed to `<Room> Lights` (`expected_name` 539-544,
  `zone_lights.creation_name` 404-411); `All %d bound devices are registered`
  (`bridge/lights.lua` 1955).
- Keypad: tap top = preset 100 % over 250 ms, tap bottom = off, toggle flips
  (`click` 685-695, defaults 648-654); hold after 400 ms ("about half a
  second"), full range in 5 s, Hue's own relative dim (`HUE_DIM` up/down/stop,
  `start_ramp` 720-748); hold top while off = on at 1 % then up after 600 ms,
  bottom while off does nothing (`start_hold` 751-773); a click within 1 s after
  a hold's release is ignored (`CLICK_GUARD_MS` 651, `button_action` 797-830);
  LEDs blue, top lit while on, bottom lit while
  off, toggle lit while on (`common/device.lua` 62-66); the binding re-check at
  5, 15, 30 and 60 s (`RECHECK_MS` 69, cumulative); `hide_proxy_properties`
  True and the three Button Link connections 200/201/202 under Control Outputs
  (`driver.xml` 126, 170-214); the bridge's output is named `Hue Lights`
  (`hue_bridge/driver.xml` 423-437) and the device's input `Hue Bridge`.
- Zone and room lights: on while any lamp is lit with the group's average
  brightness as Hue reports it (`zone_lights:state_params` 551-580); ON = every
  lamp to 100 %; slider absolute, hold relative (`HUE_DIM` → `dimming_delta`
  with `brightness_delta` 100, `zone_lights.lua` 1352-1385); colour and colour
  temperature to the group; the tile's colour is the first lit lamp's xy, else
  the first lit lamp's mirek (`hue_model.group_color` 965-977); capabilities
  the union of the members' (`hue_model.group_caps`); the grouped queue at one
  request a second with a burst of three (`hue_bridge/driver.lua` 452-457),
  lights at ten a second (`commands.RATE_PER_SEC` 42); a hold's start and stop
  bypass the bucket (`commands.urgent` 117-126, `take_token` 298-312); a colour
  set while off is kept for the next turn-on (`state.from_color_target`
  288-291); whole percents (`to_proxy_brightness` 217-225); the unreachable
  bridge: tile shows the target after rate + 1 s (`FALLBACK_MS` 23) and the
  command is retried with backoff 0.5 s doubling to 8 s (`commands.lua` 44-45).
- The icon sentence matches `docs/status.md` (16 px custom icon in the tree
  only for devices created under a build with icons; List View standard).

Hue Scene page (`src/hue_scene/www/documentation.html`):

- Status texts byte for byte in `hue_scene/driver.lua`: `Hue scene %s in %s`
  with `(zone)` / `(bridge home)` (152-162, 233-256), `Hue time-based scene %s in
  %s; now %s (from %s)` and `; not running` (219-232), `Not bound to a Hue
  Bridge`, `Bound; waiting for the bridge` and the bare name before the bridge
  answers (`refresh_status` 233-256), `Scene deleted in Hue since %Y-%m-%d %H:%M;
  ON does nothing; re-link or Forget` (170-173), `Forgotten by the bridge (was
  Hue scene Ibiza). Delete this device in Composer, or bind it again and use
  Link Devices` (164-168); `(from sunset)` when the slot starts at sunset
  (`slot_start` "sunset", `hue_model.lua` 596-619).
- Properties: `Hue Scene ID` `#AbCdEfGhIjKlMnOp (0f3a2b1c…)` and the rid alone
  without a v1 id (138-150; a smart_scene has no `id_v1`, `hue_model.lua` 38);
  `Recall As` values `As set in Hue` / `Static` / `Dynamic` → `active` /
  `static` / `dynamic_palette` (`RECALL_ACTIONS` 47-52, `driver.xml` 63-73),
  hidden on a time-based scene with `SetPropertyAttribs` (782-800); `Online`
  rules (`refresh_status` 233-256, `blocker` 178-191); `Last Action`
  `Forgotten by the bridge` (1000).
- Actions: `Renamed device %d to %s` with the zone's name in front and the base
  name of a time-based scene (1010-1031); `Not renamed: no Hue name known yet
  (the bridge has not configured this scene)`; `Asked the bridge to forget this
  scene; its answer sets Status`; `Not sent: not bound to a Hue Bridge`
  (1033-1040).
- Behaviour: the on rule (`held_on`, persisted, cleared by the group going off,
  another scene active, or this device's OFF; 97-108, 273-290, 936-989); ON one
  request with a 2 s fallback that drops back (`FALLBACK_MS` 27, `turn_on`
  584-626), OFF reported inactive at once by the bridge while the grouped_light
  off is queued and retried (`scenes:off` 1742-1783), slider relative while on
  (`move_level` / `HUE_SCENE_LEVEL`), a level from off recalls at that
  brightness and 100 % as designed (`turn_on` 589), level reports throttled to
  one a second
  (`LEVEL_REPORT_MS` 36); a zone without lights reported off without a request
  (`scenes.lua` 1773-1776); keypad taps, 5 s holds, 1 % recall then dim, the
  1 s click guard, and the time-based variants (start then follow the slot's
  level, bottom while off does nothing; `start_hold` 1212-1259, `finish_hold`
  1260-1275); ramp time → recall `duration` (`recall_params` 458-464), none for
  a time-based start (`start_smart` 562-582); `Add Scene` lists `Master
  Bedroom: Golden hours (time-based)` and marks slot scenes `(in …)`
  (`scenes.lua` 2647-2662); a zone's device named `<Zone> <Scene>`
  (`creation_name` 399-405).
- `<minimum_os_version>3.3.0` in all three `driver.xml`; chapter references
  (9, 9.11, 11) exist in the bridge manual.

README set:

- Install steps 1-9 match the manual's chapter 3 ("Adding the drivers to the
  project") and chapter 4 ("Step 1-3") sentence for sentence, and every quoted
  text exists in the bridge code: `Not paired: press the link button, then run
  Pair Bridge`, `Pairing: contacting bridge`, `Pairing: found %s %s, requesting
  key`, `Paired` (`hue_bridge/driver.lua` 124-128, 652-656), `Connected since`
  (`stream.lua` 236, 290), `%d on bridge, %d imported, %d new, …` (`lights.lua`
  2414), `(unmapped)` (`lights.lua` 751), `(time-based)`, `Test OK: HTTP 200 via
  …` (705); the model text `Hue Bridge (CLIP v2)` and manufacturer `Philips Hue`
  (`hue_bridge/driver.xml` 4-6); the action names Pair Bridge, Add Light, Import
  All New Lights, Add Zone Light, Re-link Device To Light, Link Devices, Forget
  Light, Adopt Hue Names, Set Room Mapping, Map Rooms By Name, Add Scene, Add
  All Scenes Of Room, Test Connection are all in the release part of the bridge's
  `driver.xml`; the property names Status, Event Stream, Lights, Scenes, Zone
  Lights, Room Mappings, Last Action, Attention, Bridge IP Address, Bridge ID,
  Bridge Model, Debug Mode likewise.
- "Updating" matches the manual's "Updating to a newer build" and the two notes
  (Restart Director? → reboot from System Manager; never delete the bridge).
- Keypad setup matches the manual's chapter 11 (Use as 2 Button Keypad, Buttons
  Control Load off, the load at 100 % by programming, Top/Bottom/Toggle Button
  Link, LEDs).
- HTTPS only with the Signify roots: `http.lua` 28-35 (`ssl_verify_peer = true`,
  `ssl_cabundle = certs/hue_ca_bundle.pem`); no `http://` in release code; the key
  stored encrypted and never shown (`credentials.lua` 1-2, `PersistGetValue(…,
  true)`); the pairing `devicetype` is `c4-hue-driver#bridge` (`pairing.lua` 26),
  as the research asked; nothing polled (event stream + a silence watchdog,
  `stream.lua` 39).
- Pacing: ten light commands a second (`commands.RATE_PER_SEC` 10), one grouped
  command a second (`driver.lua` 456-457), coalescing per light (`DEBOUNCE_MS`).
- Build: `tools/build.sh` default `DP3=$HOME/c4-tools/drivers-driverpackager/dp3/driverpackager.py`
  exists at that path; the clone URL matches; `git rev-list --count HEAD` is the
  version; `--dev` adds `--allowexecute` and keeps `common/devloop.lua`;
  `luacheck src tests tools` (0 warnings in 60 files; `tools` holds no Lua) and
  `busted tests` (1124 successes, 0 failures) pass; `dkjson` is used by
  `tests/helpers/fake_c4.lua` and eight specs; `tests/helpers/fake_c4.lua`,
  `tests/fixtures/hue_resources.lua`, `tools/regress.sh`,
  `tools/composer/Composer.psm1`, `tools/make_icons.py`, `tools/gen_ca_bundle.sh`
  exist.
- Status section: build 199 (2026-10-24), OS 3.4.2, Composer Pro 3.4.2, Bridge
  Pro, two scenes, two zone lights, the keypad, the verified list and the open
  list all match `docs/status.md`.
- License wording: the trademark paragraph, the Hue Developer Program Terms
  link, the disclaimer and the provenance paragraph are the research's §5 drafts
  verbatim or extended; `NOTICE` matches its draft (with a fuller first line);
  "works with Philips Hue" / "for Philips Hue" are the allowed phrasings; no logo
  or badge; the Releases URL matches the remote `corytron/c4-hue-driver`.
- Links and paths: all 33 relative links in `docs/README.md`, the 9 in
  `README.md`/`CONTRIBUTING.md`, both image paths and every backticked file path
  resolve (`hue_*.c4z` are build outputs, gitignored, as the README says).
- Private data: the four files hold no LAN address other than the documented
  placeholders and the two `192.168.x` examples, no bridge id, no key, no e-mail,
  no absolute home-directory path, no project name, no street address; the author's name is
  the intended copyright line. `add-driver-menu.png` shows only Composer's
  Driver menu.
- `CONTRIBUTING.md` conventions match `.luacheckrc` (lua51, 120 columns, the
  entry points and `CUSTOM_SELECT` functions), `.busted` (`tests/spec`,
  `_spec`), and the "Texts users read" rule matches how the manual quotes the
  code.
