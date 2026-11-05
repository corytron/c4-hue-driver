# Simplify research: how comparable products keep setup and upkeep simple (#334)

Research file of the `comparables` agent, written 2026-11-04 against the
contract in `docs/simplify-actions-design.md` §0. Read-only research; no
code changed. Web sources are cited by URL and marked **verified** (read on
the page, or in source code fetched for this file) or **assumed** (seen only
in a search-result snippet, a page that refused the fetch, or an earlier
round's note). Forum posts are flagged as such, with their dates. Quotations
are limited to one short phrase per source; everything else is paraphrase.

## 1. Findings

1. **The best Control4 Hue drivers win on one entry point, not on fewer
   features.** Chowmain's 2026 driver pairs by itself as soon as the IP is
   set and then offers one AutoSetup action, with "select device from list"
   as the manual fallback (E3, E4). Whistle Projects' packs offer bulk import
   by Rooms, Zones or Everything (E5). Neither documents any per-family
   re-link, forget or name-review actions: they simply do not cover the
   lifecycle we cover. Our 32 actions carry real features; the lesson is to
   put them behind **one Add, one Link, one Forget, one Names and one
   Diagnostics** entry, not to drop them.
2. **"Automatic" in Apple Home and Home Assistant means device creation
   without a click; Control4 forbids exactly that.** HomeKit adds every
   accessory behind a bridge by itself (E10) and Home Assistant registers
   every Hue device and deletes it again when Hue deletes it (E7). The
   DriverWorks API says device creation should only follow a user action
   (E21). Our nearest equivalent is the **openHAB Inbox**: discoveries are
   suggestions, auto-approve is off by default (E13). So our "automatic" is
   *noticed, listed and counted automatically; created with one click*.
3. **Identity by bridge id, address as a hint, is the most-copied
   self-healing trick, and we lack it.** Home Assistant updates the stored
   host whenever mDNS sees the same bridge id at a new address and reloads
   (E8); B&O's BeoLiving driver has an "automatic host update on connection
   errors" switch (E15); Whistle Projects advertises mDNS discovery (E5),
   while Chowmain asks for a static address or reservation (E4). Our
   driver has no IP follow-up at all (`docs/design.md:1283`). A router
   reboot without a DHCP reservation is a classic Hue support story (E9,
   forum 2020).
4. **Two names, and the person's name wins.** Home Assistant keeps the
   vendor's device name and a separate user name, and a Hue room is only a
   *suggested* area at creation (E7, E11). Josh.ai imports Control4 names
   and lets aliases sit on top (E19). The products people complain about
   rename for you: Whistle Projects' devices rename themselves to the Hue
   name (E5); the Hue app's sync to Apple Home overwrote changes made in
   Home and dumped lights in a default room (E12, forum). Our Hue Name
   property plus Adopt is the right model; the two bridge-wide name actions
   can become one.
5. **Nobody auto-deletes safely.** Home Assistant deletes devices removed in
   Hue (E7), which silently breaks automations; HomeKit does not let you
   remove a single bridged accessory at all (E10); Control4 has no API to
   delete a device (`docs/edge-cases-ux.md:81`). Missing stays a visible
   state with an offered Forget.
6. **Bridge replacement is where every ecosystem breaks.** Signify's own
   upgrade guide says most integrations must reconnect and automations tied
   to them often need recreating; Sonos speakers reappear as new devices
   (E16). Home Assistant users who clicked "Add hub" got duplicate entities
   (E17, forum 2025); SmartThings users got duplicates from a second link
   method (E18, forum 2025). Our refuse-then-offer adoption by bridge id
   (`docs/edge-cases-hue.md:105`) is better than any comparable; keep it a
   click, but make it the *offered* click, not a hunt through Forget Pairing.
7. **One place that says what needs you.** Home Assistant's Repairs page
   lists issues, each with a fix button or an explanation, and badges the
   count (E14). Our `Attention` property is that place already; the simpler
   driver routes every offer through it and names the one action to click.
8. **Few settings, two levels at most.** Apple's guidelines ask for good
   defaults and as few settings as possible, and say not to ask for setup
   information the product can find itself (E22); Nielsen Norman Group warns
   that more than two disclosure levels hurt usability (E23). Home
   Assistant's Hue v2 integration has a single option (E6). For us: an
   everyday level and one Diagnostics action whose picker holds the
   support tools, since Composer cannot hide an action at runtime
   (`docs/simplify-research-composer.md`, findings 1 and 3).
9. **Events, not polls, is already our edge.** Control4's own OS 3.3 Hue
   driver polled every 30 s and was reported to miss Hue-app changes (E1,
   forum); BeoLiving warns against polling below 5 s on small systems (E15).
   Background tasks we add must ride the event stream and reconnects, not
   new timers, or we copy the weakness we beat.

## 2. Comparison table

| Product | Source | How it finds / pairs | New, renamed, removed lights | What the installer clicks | What we should take | What we should avoid |
| --- | --- | --- | --- | --- | --- | --- |
| Control4 native Hue (Extra Vegetables 2013 → OS 2.9 → OS 3.3 "Philips Hue Light (OS 3.3.0+)") | E1, E2 | IP typed in; "Link with Bridge" action | 2013: bulb address typed per driver; 2022: add a light driver, bind it in Connections, "Update Available Lights", pick from a dropdown; 30 s poll | One driver per bulb, one binding each, one dropdown each | The name shown next to the id as a check | Per-device manual binding; polling; a replaced bridge meant re-adding and remapping |
| Chowmain Philips Hue (Jan 2026, OS 3.4.3+) | E3, E4 | IP and port typed in; press the link button; linking starts by itself, Link Bridge only as a retry | AutoSetup creates all devices; manual = bind + "Select Device From List"; rename/removal not documented | Set IP, press button, AutoSetup | **Auto-pairing window after the IP is set**; one setup action | Undocumented lifecycle: what a second AutoSetup does is unknown |
| Whistle Projects Hue packs (v15) | E5 | mDNS discovery or manual IP | Bulk import by Rooms, Zones or Everything; devices rename themselves to the Hue name; two-way sync "not guaranteed" | Import action per kind | Import scoped by Hue room or zone | **Self-renaming**; advising owners to use only Control4 because sync is unreliable |
| Home Assistant Hue (2026) | E6, E7, E8, E11 | Zeroconf discovery, press the link button; host follows the bridge id | Every device registered automatically; Hue rename updates the vendor name but a user name wins; Hue room only suggests an area at creation; Hue delete removes the device | Nothing after pairing; one option (ignore availability) | **Host follows bridge id**; vendor name vs user name; room as a suggestion | **Auto-delete on Hue delete** (breaks automations); "Add hub" duplicates after a bridge swap |
| Apple Home (HomeKit HAP; Matter on Bridge Pro) | E10, E12, E20 | Scan the bridge code | Bridged accessories added automatically; room managed per accessory (new ones land in a default room); cannot remove one accessory, only the bridge; Matter route gained name and room sync in Hue app 5.50 (Sept 2025) | Nothing per light; fix rooms by hand | Bridge = one object; children follow it without per-child setup | Lights moved en masse to one room and dropped from routines (forum 2024); sync that overwrote Home edits |
| Philips Hue app and Bridge Pro transfer | E16, E24 | QR code or search; transfer to a Bridge Pro through the cloud | Room assignment at add time; transfer keeps devices, rooms, scenes; old bridge reset; most integrations must reconnect | Settings ▸ Software update ▸ Automatic update is one switch | **Background job with one switch** (auto-update); a guided transfer | Leaving every integration to rediscover on its own |
| openHAB (Inbox; Hue CLIP 2 binding) | E13 | Discovery services feed an Inbox | Each discovery is a suggestion to approve or ignore; auto-approve off by default; duplicates auto-ignored | Approve in the Inbox | **Inbox semantics**: suggestion, approve, ignore, remembered | Hue binding itself is console-and-text-file heavy |
| Hubitat Hue integration | E25 | Pick the bridge from a dropdown | Bulbs ticked from a discovery list; "Refresh Bulb Discovery" for new ones; groups found in a separate step | Tick boxes, refresh | One checklist for selection | A separate step per kind |
| SmartThings Hue | E18 | Four ways to link (cloud, LAN, Matter, Edge) | Two link methods → every bulb duplicated; routines left pointing at old copies | Delete the duplicates by hand | — | **Two identities for one bulb**; cleanup that deleted real devices |
| B&O BeoLiving Hue (legacy, deprecated Sept 2024) | E15 | Host name or IP; link button then a "create user" button | Polls lights and groups; scenes as buttons | Create user | **Automatic host update on connection errors** as a visible switch | Polling with a floor of 5 s |
| Control4 SDDP and Sonos | E26, E27 | Device announces itself; Composer's Discovered tab | Auto-add only when the installer ticks "auto add identified devices"; room connections stay manual | Double-click or tick | **Auto-add is opt-in even in Control4's own tool** | — |
| Lutron RA3 / QSX in Control4; RTI LEAP | E28 | Pair by a button on the processor | Import of areas and zones from driver actions; RTI has one "Driver Sync" button | Add Areas, Add Zones; Sync | One sync button as a safety valve | Imported keypads that look right but do nothing (forum 2025) |
| Josh.ai with Control4 | E19 | Josh driver in the project | Imports Control4 rooms and names; only what the navigator shows; aliases on top | None per device | **The integrator's names stay the source**; aliases rather than renames | — |
| Blackwire Ring (Control4) | E29 | Account authorisation | One driver per camera, picked from a dropdown of the account's devices | Add a driver per device, pick, Set | — | One driver plus one selection per device |

## 3. Evidence

Repository and SDK (read for this file):

- R1 `src/hue_bridge/driver.xml:234-559`: the 32 bridge actions, 26 with
  `CUSTOM_SELECT` parameters. **verified**
- R2 `docs/design.md:1283-1285`: no Discover Bridges action, no automatic IP
  follow-up; `docs/design.md:1301-1304` designed the follow-up by bridge id
  but it was never built. **verified**
- R3 `docs/design.md:1319`: Hue limits of about 10 light commands per second
  and 1 grouped-light command per second; `docs/status.md:392`: four
  `C4:url` transfers at once controller-wide. **verified**
- R4 `docs/edge-cases-ux.md:34-70`: the earlier round's reading of the
  Control4 native driver (2013, 2017, 2022), Chowmain and Whistle Projects,
  with its own citations. **verified** (that round read the forum pages
  this round could not; see E1)
- R5 `docs/edge-cases-hue.md:105-106` and `docs/bridge-compat-design.md:73`:
  bridge transfer gives a new bridge id; adoption by `replacesbridgeid` is
  designed but refused until Forget Pairing today. **verified**
- R6 `src/hue_bridge/www/documentation.html:57`: the driver never adds,
  renames, moves or removes a device by itself, except the one-time Map
  Rooms By Name and the re-adoption of a device announcing a known light.
  **verified**
- R7 `src/hue_bridge/www/documentation.html:173-187`: pairing today is set
  the IP, press the button, then click Pair Bridge. **verified**
- R8 `src/hue_bridge/www/documentation.html:201`: the identity and TLS
  checks run at every start and after an address change, and an
  unanswered check is retried every 30 s by itself. **verified**
- E21 `~/c4-tools/reference/docs-driverworks-api/source/includes/9_helper/_0.1-AddDevice.md:3`:
  AddDevice and AddLocation are meant to run only on a dealer's or user's
  action, because careless use can make drivers add themselves recursively.
  **verified** (paraphrased; Snap One text not quoted)

Web:

- E1 Control4's OS 3.3 Hue driver (light driver v72, bridge v849): bind each
  light driver to the bridge, set a poll interval, Hue-app changes missed
  without it. Forum thread (about 2022):
  https://www.c4forums.com/forums/topic/40329-hue-with-33-best-practices/ —
  **assumed** this round (HTTP 403 to the fetch; snippet only), **verified**
  in R4 by the earlier round.
- E2 Extra Vegetables Hue driver V8 (September 2013): linking is one action
  that only needs repeating when the bridge changes; lamp addresses were
  printed to the Lua tab and typed into each driver.
  https://res.cloudinary.com/control4/raw/upload/1697/3/Extra%20Vegetables%20Philips%20Hue%20Driver%20V8.pdf
  **verified** (PDF text read; old source).
- E3 Chowmain KB, manual setup: bind the device driver in Connections, then
  Select Device From List; AutoSetup "strongly recommended" instead.
  https://help.chowmain.software/portal/en/kb/articles/control4-philips-hue-manual-setup-of-hue-device
  **verified**
- E4 Chowmain KB, linking: IP and port typed in, link button pressed, the
  driver starts linking by itself after first setup, Link Bridge as the
  retry, then AutoSetup.
  https://help.chowmain.software/portal/en/kb/articles/control4-philips-hue-linking-to-philips-hue-bridge
  **verified**; requirements OS 3.4.3, bridge v2 or Pro:
  https://help.chowmain.software/portal/en/kb/articles/control4-philips-hue-system-requirements
  **verified**; release January 2026 and price: Connected Magazine and
  reseller snippets, **assumed**.
- E5 Whistle Projects Philips Hue Lighting Pack v15: mDNS or manual IP,
  bulk import by Rooms, Zones or Everything, self-renaming to the Hue name,
  two-way sync not guaranteed.
  https://drivercentral.io/platforms/control4-drivers/lighting/philips-hue-lighting-pack/
  **verified**; Ultimate Pack and Security Pack pages show the same import
  model and Bridge Pro support:
  https://drivercentral.io/platforms/control4-drivers/security-systems/philips-hue-ultimate-pack/
  https://drivercentral.io/platforms/control4-drivers/philips-hue-security-pack/
  **verified** (no dates on the pages).
- E6 Home Assistant Hue docs: automatic discovery, v2 event stream, scenes
  imported, room and zone lights created disabled, one v2 option.
  https://www.home-assistant.io/integrations/hue/ **verified**
- E7 Home Assistant source, `homeassistant/components/hue/v2/device.py`
  (dev branch, fetched 2026-11-04): every Hue device, room and zone is
  registered with the Hue name; a Hue room becomes a `suggested_area`; on a
  Hue delete event, and at start for anything no longer on the bridge, the
  device is removed from the registry.
  https://github.com/home-assistant/core/blob/dev/homeassistant/components/hue/v2/device.py
  **verified**
- E8 Same repository, `config_flow.py`: on zeroconf discovery the flow sets
  the bridge id as unique id and updates the stored host, reloading the
  entry, if the same bridge appears at a new address.
  https://github.com/home-assistant/core/blob/dev/homeassistant/components/hue/config_flow.py
  **verified**
- E9 Home Assistant forum, August 2020: all Hue bulbs unavailable after a
  router reboot gave the bridge a new address; fix was re-pointing and a DHCP
  reservation (before E8 existed).
  https://community.home-assistant.io/t/all-hue-bulbs-disabled-suddenly-shown-as-orphan/217236
  **verified** (forum, old)
- E10 Apple HomeKit `HMAccessory.isBridged`: accessories behind a bridge are
  added to the home automatically; adding the bridge to a room does not move
  them; a bridged accessory cannot be removed on its own, only the bridge.
  https://developer.apple.com/documentation/homekit/hmaccessory/isbridged
  **verified**
- E11 Home Assistant device registry: a vendor name and a separate user name
  per device; suggested area used when the device is created. Developer
  docs moved to https://contributors.home-assistant.io/core/integrations/device-registry/
  (not fetched); field usage **verified** in E7, precedence of the user name
  **assumed** from the registry design.
- E12 Apple Community thread, March to August 2024: 45+ Hue lights suddenly
  shown in one room in Home and dropped from routines, cause unknown,
  re-assigning by hand did not stick.
  https://discussions.apple.com/thread/255508740 **verified** (forum).
  MacRumors threads on the Hue sync overwriting Home edits and new bulbs
  landing in a default room as "Hue Color 1":
  https://forums.macrumors.com/threads/syncing-hue-lights-and-rooms-with-homekit.2407896
  **assumed** (HTTP 403; snippet only).
- E13 openHAB discovery concept: results are suggestions, approve or ignore,
  ignored stays hidden, duplicates auto-ignored, auto-approve off by default,
  background discovery per service.
  https://www.openhab.org/docs/concepts/discovery.html **verified**.
  Hue CLIP 2 binding (one `scene` channel per room/zone, keys and things set
  by console and text files):
  https://www.openhab.org/addons/bindings/hue/doc/readme_v2.html **verified**
- E14 Home Assistant Repairs: one page of issues needing input, each with a
  fix flow or instructions, count badge in the sidebar.
  https://www.home-assistant.io/integrations/repairs/ **verified**
- E15 BeoLiving Intelligence Philips Hue (Legacy), changelog to March 2023,
  deprecated from September 2024: link button then a "create user" button,
  automatic host update on connection errors, polling with a 5 s floor
  advised. https://khimo.github.io/help_drivers/philips-hue **verified**
- E16 Signify, "How to upgrade to the Hue Bridge Pro": devices, names, rooms,
  zones and scenes transfer; most partner integrations need a rediscovery or
  relink and their automations often recreating; Sonos speakers reappear as
  new devices; the old bridge is reset; the move is one-way.
  https://www.philips-hue.com/en-us/support/article/how-to-upgrade-to-the-hue-bridge-pro/000010
  **verified**
- E17 Home Assistant forum, September 2025: after the Bridge Pro transfer,
  entities survived when HA was simply restarted; one user who clicked "Add
  hub" got a second bridge with duplicate entities and restored a backup.
  https://community.home-assistant.io/t/upgrading-to-the-philips-hue-bridge-pro/927325
  **verified** (forum). Hueblog's step-by-step guide (8 September 2025):
  Apple Home connection is cut and must be rebuilt.
  https://hueblog.com/2025/09/08/step-by-step-guide-transferring-data-to-the-new-hue-bridge-pro/
  **verified**
- E18 SmartThings community, February to March 2025: every bulb duplicated
  after a second link method; cleanup deleted two real lights; routines had
  to be redone. https://community.smartthings.com/t/duplicate-philips-hue-lights/296284
  **verified** (forum). A support claim that a migrated bridge's new MAC
  makes the hub see a new device: **assumed** (snippet; not on that page).
- E19 Josh.ai, "Setting up Josh.ai and Control4" (May 2021): imports rooms,
  device names and types from the Control4 project, only what the room's
  navigator shows; aliases set in Josh.
  https://josh.ai/stories/setting-up-joshai-and-control4-av-scenes-and-aliases
  **verified**
- E20 Hueblog, Hue app 5.50 (4 September 2025): room and device names now
  sync to Apple Home over Matter, automatically and with a manual sync in
  Settings ▸ Smart Home; Bridge Pro reaches Apple Home only through Matter.
  https://hueblog.com/?p=18526 **verified**
- E22 Apple HIG, Settings (changed 10 June 2024): defaults that suit most
  people, "Minimize the number of settings you offer", and do not use
  settings to ask for what the app can detect.
  https://developer.apple.com/design/human-interface-guidelines/settings **verified**
- E23 Nielsen Norman Group, "Progressive Disclosure" (2006, still the
  standard reference): core options first, an obvious path to the rest,
  beyond two levels "typically have low usability".
  https://www.nngroup.com/articles/progressive-disclosure/ **verified** (old)
- E24 Signify bridge release notes: turn on Settings ▸ Software update ▸
  Automatic update to receive firmware as it ships; latest listed v2 release
  22 October 2026. https://www.philips-hue.com/en-us/support/release-notes/bridge
  **verified**
- E25 Hubitat Hue Bridge Integration: bulbs ticked from a discovery list,
  Refresh Bulb Discovery for new ones, groups by a separate Find Groups.
  https://docs2.hubitat.com/apps/hue-bridge-integration **assumed** (the
  page rendered empty to the fetch; snippet only)
- E26 Control4 Composer Pro help, Auto Discovery (SDDP): devices identified
  by a unique id so DHCP is fine; "auto add identified devices" must be
  ticked, otherwise Identify only highlights; room connections stay manual.
  https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/auto_discovery_sddp.htm
  **verified**
- E27 Sonos enabling SDDP so players are found and configured in Control4:
  https://www.soundandvision.com/content/sonos-streamlines-control4-integration
  **assumed** (HTTP 403; trade-press snippet, undated).
- E28 Lutron QSX/RA3 in Control4: areas and zones imported from driver
  actions, imported keypads without function (Reddit, June 2025, snippet);
  RTI's LEAP driver has a Driver Sync button (snippet).
  https://reddit.zackpollard.pro/r/Control4/comments/1ljlm1a/lutron_qsx_integration
  https://driverstore.rticontrol.com/driver/lutron-leap **assumed** (both
  fetches failed)
- E29 Blackwire Ring Events for Control4: one driver per doorbell or camera,
  device picked from a dropdown of the account's devices.
  https://www.cepro.com/news/control4_finally_integrates_directly_with_ring_video_doorbell_sort_of
  **assumed** (snippet only, 2017 and 2025 coverage)
- E30 zencontrol's Control4 controller driver: one setup action scans and
  creates every device, one sync action refreshes them, display toggles
  apply to all children.
  https://support.zencontrol.com/hc/en-us/articles/15467375659535-Controller-Actions
  **assumed** (HTTP 403; snippet only)

Not found: any public account of Control4's own driver handling a replaced
bulb, a renamed light or a replaced bridge beyond "add it again" (R4); any
comparable Control4 Hue driver documenting what happens when its bulk import
runs twice.

## 4. Lessons, in order of value

1. **Count entry points, not features.** Every well-liked integration has
   one way in per *intent*: add, sync, fix, forget. Ours has one way in per
   *intent per kind* (five Adds, four Re-links, four Forgets). Merging by
   intent removes about two thirds of the actions and loses nothing,
   because the kind becomes the first choice in the action's list (E3-E5,
   E13, R1).
2. **Notice everything automatically; create nothing without a click.**
   Control4's SDK and its own SDDP tool both keep creation behind a person
   (E21, E26). So copy openHAB's Inbox, not HomeKit's auto-add: the driver
   keeps the new, missing and suggested lists current by itself, counts
   them in Attention, and one action accepts (E13, E14).
3. **Follow the bridge by id.** Re-find a bridge that moved address, with
   the stored key and the TLS check, before telling anyone (E8, E15, R2).
   The best-maintained comparables do this (E8, E15) and we do not; a
   DHCP reservation, which Chowmain demands (E4), becomes advice, not a
   requirement.
4. **The installer's name and room are sacred; Hue's are suggestions.**
   Show the Hue name beside the Control4 name, offer adoption, never apply
   it (E5, E7, E12, R6). Map a Hue room to a Control4 room when the names
   match exactly, because a mapping only steers future imports.
5. **Make the bridge swap a guided offer.** When a different bridge answers
   and declares it replaces ours, say so in Attention and offer adoption in
   one click; Signify says most partner integrations must be redone here,
   and only a restart-and-wait integration came through cleanly (E16-E18, R5).
6. **One sync button is fine; many refresh buttons are not.** RTI, Hubitat
   and zencontrol each keep a single sync or refresh (E25, E28, E30). Keep
   one Refresh All as the safety valve and run it by itself after every
   reconnect.
7. **Diagnostics one level down.** Tests, pinning checks, stream controls
   and motion logs belong in one Diagnostics action with a picker, and
   their property rows can be shown only while `Debug Mode` is on
   (E22, E23); none of the comparables shows them to an installer.
8. **Pairing should need only the button.** Chowmain starts linking by
   itself once the address is set up (E4). After the IP is set and the
   identity check passes, the driver can ask for a key every few seconds
   for a short window while Status says "press the link button"; Pair Bridge stays as the retry.
9. **No new polling.** Background tasks hang off events, reconnects and
   start-up; any timer names its request budget against R3.

## 5. Verdict hints per action

Hints only: the import, maintenance and composer files own the verdicts.
Merge targets use the names of `docs/simplify-research-import.md` §5 where
it has one. The composer file, read after this one was drafted, says the
Actions tab is static (no action hides at runtime) while property rows can
be hidden and one action's picker can hold many choices. So **MOVE to
diagnostics** here means: a choice in one Diagnostics action, with any
support-only rows shown only while `Debug Mode` is on.

| Action | Hint | Reason from the comparables |
| --- | --- | --- |
| Pair Bridge | **KEEP** | Chowmain keeps Link Bridge as the retry after an automatic pairing window opened by setting the IP (E4); add that window. |
| Test Connection | **MOVE to diagnostics** | No comparable has a test button; Status already re-checks every 30 s (R8). |
| Connection Test | **MOVE to diagnostics** | Transport test for support only. |
| Connect Event Stream | **AUTOMATIC** | The stream is managed; openHAB's Hue binding retries its event connection on a cadence (E13), HA shows no stream controls (E6). |
| Disconnect Event Stream | **MOVE to diagnostics** | Needed only for support. |
| Reload Credentials | **MOVE to diagnostics** | No comparable exposes credential plumbing. |
| Check CA Pinning | **MOVE to diagnostics** | The TLS check already runs at every start and address change (R8). |
| Forget Pairing | **KEEP** | Every comparable has an unlink; it is rare and deliberate. |
| Add Light | **MERGE into Add From Hue** | One add per intent (E13, E30). |
| Import All New Lights | **MERGE into Add From Hue** | Whistle imports by Rooms, Zones or Everything (E5): an "All new" choice inside one action. |
| Add Zone Light | **MERGE into Add From Hue** | Same intent, another kind. |
| Re-link Device To Light | **MERGE into Link Device** | Suggestions first (same Zigbee MAC, exact name), offered via Attention; nobody else offers this at all. |
| Re-link Zone Light | **MERGE into Link Device** | Same intent. |
| Link Devices | **AUTOMATIC** | It only acts on devices the installer bound by hand; run on start and after a binding change, reporting in Last Action. |
| Forget Light | **MERGE into Forget Device** | One forget for every kind; missing stays visible, never auto-deleted (E7, E10). |
| Adopt Hue Names | **MERGE into Resolve Names** | Two names, the person's wins (E7, E19). |
| Accept Names As They Are | **MERGE into Resolve Names** | The "keep" half of the same decision. |
| Set Room Mapping | **KEEP** | Rooms are the installer's choice (E10, E11). |
| Map Rooms By Name | **AUTOMATIC** | Exact-name mapping of an unmapped Hue room only steers future imports, like HA's suggested area (E7). |
| Room Audit | **AUTOMATIC** | A report: recompute on every read and show it in a row; nothing is moved. |
| Add Scene | **MERGE into Add From Hue** | Same intent. |
| Add All Scenes Of Room | **MERGE into Add From Hue** | Import scoped to a Hue room is Whistle's model (E5). |
| Re-link Scene | **MERGE into Link Device** | Same intent. |
| Forget Scene | **MERGE into Forget Device** | Same intent. |
| Refresh Scenes | **MERGE into Refresh All** | One sync button (lesson 6). |
| Refresh All | **KEEP** | The single safety valve; also run by itself after every reconnect. |
| Add Motion Sensor | **MERGE into Add From Hue** | Same intent. |
| Import All New Motion Sensors | **MERGE into Add From Hue** | "All new" of one kind. |
| Add Motion Area | **MERGE into Add From Hue** | Same intent. |
| Re-link Motion Device | **MERGE into Link Device** | Same intent. |
| Forget Motion Device | **MERGE into Forget Device** | Same intent. |
| Log Motion Diagnostics | **MOVE to diagnostics** | Support only. |
| Light: Adopt Hue Name | **KEEP** | Options in context beat options in a settings area (E22). |
| Light: Forget This Light | **KEEP** | Same; the device the installer is looking at. |
| Scene: Adopt Hue Name | **KEEP** | As for the light. |
| Scene: Forget This Scene | **KEEP** | As for the light. |
| Motion: Refresh From Bridge | **MOVE to diagnostics** | The stream keeps it current; keep for support. |
| Motion: Test: Motion / Test: No Motion | **KEEP** | Testing programming without walking past a sensor is a real installer task with no automatic equivalent. |

With these hints the bridge's everyday list would read Pair Bridge, Add
From Hue, Link Device, Resolve Names, Set Room Mapping, Forget Device,
Refresh All, Forget Pairing, plus one Diagnostics entry: nine instead of 32.

New behaviours the comparables suggest (for the maintenance and scheduler
files): **follow the bridge by id** after a connection failure (AUTOMATIC,
on reconnect failure, within the discovery endpoint's rate limit, Status
"Bridge moved to … ; reconnected"); an **automatic pairing window** after the
IP is set (AUTOMATIC, one key request every few seconds for at most a couple
of minutes, Status says "press the link button"); **adopt a replacement
bridge** (OFFERED through Attention when `replacesbridgeid` names ours).

## 6. Risks and open questions for the owner

1. **Should the driver re-find the bridge at a new address by itself?**
   Recommended: **yes**, keyed by the stored bridge id and the existing TLS
   check, with a setting to switch it off; every comparable that is liked
   does it (E8, E15).
2. **Should pairing start by itself once the address is set?** Recommended:
   **yes**, for a short window with Status asking for the button; Pair
   Bridge stays (E4).
3. **Should a Hue delete ever remove a Control4 device?** Recommended:
   **no**; show it as missing and offer Forget. HA's auto-delete is the
   pattern that breaks automations (E7), and Control4 cannot delete a
   device anyway (R4).
4. **Should Hue renames ever apply by themselves?** Recommended: **no**;
   keep them offered (E5, E12).
5. **Should bulk import ever run unattended?** Recommended: **no**, even as
   an opt-in setting: the SDK says creation follows a person (E21), and the
   house's bridge carries over a hundred scenes (`docs/list-rows-design.md:18`).
6. **Risk: merged actions with long lists.** One Add From Hue list for
   lights, zones, scenes and sensors may be long; group by kind and put
   suggested and new items first. Depends on what Composer's custom-select
   lists can show (composer file).
7. **Risk: evidence gaps.** Control4 forum pages refused every fetch this
   round (HTTP 403); the native driver's behaviour rests on the earlier
   round's reading (R4) and snippets (E1). Chowmain's 2026 manual PDF was
   not readable, so its AutoSetup re-run behaviour is unknown. Recommended:
   accept; none of the verdicts depends on those details.
