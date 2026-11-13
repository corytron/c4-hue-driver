# Hue automation audit and remedy: the contract (#280)

Status: contract, 2026-11-09, written against `main` at 4910aa3 (release
1.4 "Maarva", build 565). Nothing here is built. It closes **#280** and
supersedes the draft notes of PR #285 where they disagree. Target release:
1.5, with no controller reboot of its own (section 9).
Current (2026-11-13, #478): built and released in 1.5 "Kenari", build 609
(2026-11-10): the modules of section 6.1, the Hue Automations row and the
tenth bridge action (`docs/status.md`).

## 1. Summary

The owner's north star (#280, 2026-10-26): **Control4 is the source of truth
for automations, not the Hue app.** Hue keeps automations of its own on the
bridge: Wake up, Go to sleep, Lighting schedules, Timers, Coming home,
Leaving home, Mimic presence, and the set-ups of switches, motion sensors
and MotionAware areas. When one of them moves a light that Control4 also
programs, the two fight.

What 1.5 adds, on the Hue Bridge driver only:

1. **An audit that runs by itself and only reads.** After every full read of
   the bridge and on every automation event, the bridge works out which Hue
   automations act on lights Control4 controls. It lists every automation on
   a new list row, **Hue Automations**, and puts the ones that fire on their
   own on **Attention**.
2. **A remedy that is only offered.** One new action, **Hue Automations**,
   disables a chosen automation in Hue with one click (`enabled` false, the
   Hue app's own on/off switch). It never deletes. It records what it
   disabled in the bridge driver's persistent store, which survives a driver
   update and a controller reboot. A matching **Restore** turns it back on.
3. **Hue app steps where the API cannot help.** Switch, sensor and
   MotionAware set-ups cannot be switched off through the API. For those the
   action writes the exact Hue app steps into Last Action. For MotionAware
   the recommended way is the one already verified on the house: keep the
   area on and set its automation to **Do nothing** on motion and on no
   motion.
4. **An ignore list.** **Keep on the Hue side** marks an automation the
   owner wants to keep. It leaves Attention until it starts acting on other
   Control4 lights.

This changes decision D7 of [motion-design.md](motion-design.md) ("no writes
to Hue") for automations only: one field, on a click, recorded, reversible
(D2).

## 2. Findings

Markers: **[verified: …]** = read in code (`file:line`), an SDK doc file, a
recorded house diagnostics run, or code that parses real bridges;
**[community: …]** = an issue, forum post or PR description, plausible but
not shown by code or a dump; **[assumed]** = not shown anywhere yet. The full
public-source research, with every URL, is
[`hue-automations-research.md`](hue-automations-research.md) (cited below as
HAR §n); its lifecycle draft is
[`edge-cases-automations.md`](edge-cases-automations.md) (EAD).

### 2.1 Hue's automation model (CLIP v2)

| # | Finding | Status |
| --- | --- | --- |
| F1 | Every automation the Hue app makes, and every switch, sensor or MotionAware set-up, is a `behavior_instance`: one configured copy of a `behavior_script` that ships with the bridge firmware. Clients cannot add scripts. | [verified: HAR §1.1, openhue and aiohue models] |
| F2 | `behavior_instance` fields: `id`, `script_id`, `enabled`, `status` (`initializing`, `running`, `disabled`, `errored`), `last_error`, `configuration` (shape per script, no public schema), `dependees[]` (`{target {rid, rtype}, level critical or non_critical}`), `metadata.name`, optional `state`, `migrated_from` (a v1 path such as `/resourcelinks/12`), `id_v1`. | [verified: HAR §1.3, aiohue `behavior_instance.py`] |
| F3 | `behavior_script` fields: `id`, `metadata.name`, `metadata.category` (`automation`, `accessory`, `entertainment`, `other`; empty on older firmware), `description`, schema file names (never the schema), `version`, `max_number_instances`. The same script id names the same script on every bridge. | [verified: HAR §1.2, openHAB and Home Assistant dumps] |
| F4 | A PUT on an instance accepts `enabled`, `configuration`, `metadata.name` and `trigger` (start/stop for run-on-demand scripts). POST exists; DELETE is in no public model. | [verified: HAR §1.3; DELETE assumed] |
| F5 | `{"enabled": false}` works on `automation`-category instances with a toggle in the app: Home Assistant and openHAB write it. | [verified: HAR §6.1; Home Assistant `homeassistant/components/hue/switch.py`, read 2026-11-09 via the GitHub API: `is_user_automation` keeps only Hue-app automations] |
| F6 | On `accessory` and `entertainment` instances the bridge refuses `enabled`, or accepts it and the device keeps working. Home Assistant removed its switches for them for that reason. | [verified: Home Assistant PR #177671, merged 2026-08-01, read 2026-11-09] |
| F7 | Play/stop automations (Mimic presence; Timers) start and stop through `trigger`; their `enabled` is a setting the Hue app does not show. | [community: HAR §6.1, Home Assistant PR #177691] |
| F8 | `status` is not a reliable on/off: a disabled instance read `initializing` in one dump. `enabled` is the flag to read. | [verified: HAR §1.3] |
| F9 | `dependees` mix triggers (a switch's device and buttons, a sensor, an area) with targets (rooms, zones, lights, scenes). Deleting a critical dependee deletes the instance. | [verified: HAR §1.5, aiohue docstrings]; the cascade [assumed, by analogy with smart scenes] |
| F10 | Targets live in `configuration`: `where[]` (`group {rid, rtype}`, optional `items[]` of lights), `what[]` (`recall` of a scene or recipe), per-button `where`, per-slot `recall`. Every `{rid, rtype}` object anywhere in `configuration` is a reference whose `rtype` says what it is. | [verified: HAR §1.4, dumps]; "every object is a reference" [assumed: holds on every dump] |
| F11 | Button actions are strings or objects under keys named `action`: `do_nothing`, `all_off`, `dim_up`, `dim_down`, `{recall {rid, rtype: scene}}`, `last_on`. | [verified: HAR §1.4, openHAB and aiohue dumps] |
| F12 | The event stream carries `behavior_instance` items. | `update` [verified: house, Discussion #290: both saves in the Hue app arrived as live updates]; `add`, `delete` [assumed: as every other resource; openHAB handles both, HAR §1.7] |
| F13 | Nothing in any event says which automation changed a light. The audit can say what could fire, never what fired. | [assumed: no such field in any public model] |
| F14 | v1 rules, v1 schedules and Hue Labs formulas are invisible to CLIP v2, as are Alexa, Google Home, Apple Home and Home Assistant automations. | [community: HAR §5] |
| F15 | No rate limit is published for behaviour resources; Signify's general guidance applies. | [assumed: HAR §6.4; [design.md](design.md) "Commands and rate limiting"] |

### 2.2 The house (Hue Bridge Pro BSB003, OS 3.4.x controller)

| # | Finding | Status |
| --- | --- | --- |
| H1 | The bridge serves 14 behaviour scripts, among them `67d9…` "Hue Accessories" (`accessory`), `bba7…` "Motion Sensor" (`accessory`), `7238…` "Schedule" (`automation`) and `e73b…` "Timers" (`automation`). | [verified: house diagnostics 2026-10-26, issue #268] |
| H2 | **The only Hue automation on the house bridge** is the one the app forced onto the MotionAware area. It is an instance of "Hue Accessories" (`accessory`), not an `automation`. | [verified: same run] |
| H3 | Its shape: `configuration.source` = the `motion_area_configuration`; `configuration.motion.motion_service` = the `convenience_area_motion`; `configuration.motion.where` = one Hue room; `configuration.motion.when.timeslots[]`, each with `start_time`, `on_motion.recall_single[{action {recall scene}}]`, `on_no_motion.after.minutes`, `on_no_motion.recall_single[{action "all_off"}]`. Dependees, all critical: the area, the room, three scenes, the convenience service. | [verified: same run] |
| H4 | The owner set it to one time slot with **Do nothing** on motion and on no motion and saved it. The stream showed `on_motion.recall_single=[{action="do_nothing"}]`, then the same on `on_no_motion`; the scenes dropped out of `dependees`. **Motion still reached Control4 within about 1 s and no light changed.** | [verified: house, Discussion #290, 2026-10-26] |
| H5 | The area acts on one Hue room while its own group is the whole home (`bridge_home`). | [verified: issue #268] |
| H6 | The recipe of H4 is already in the bridge manual (§14.13, `src/hue_bridge/www/documentation.html:1148`). | [verified: code] |

### 2.3 MotionAware: skipping or backing out Hue's automation

| Way | Motion keeps reaching Control4? | Verdict | Status |
| --- | --- | --- | --- |
| Skip it at creation | Not possible: the app asks for lights, alerts (paid plan) or both. | — | [verified: HAR §3.4, Philips Hue support article] |
| One slot, **Do nothing** on motion and on no motion, saved | **Yes** | **Recommended** | [verified: house, H4] |
| Light control on, every light deselected | Yes, per two Homey threads | Second choice | [community: HAR §3.3] |
| Light control off (the area controls no lights) | No: areas stopped reporting | Never | [community: HAR §3.3] |
| Pause or switch off the area (`motion_area_configuration.enabled` false) | No: health `not_running` | Never | [verified: [motion-hue-research.md](motion-hue-research.md); community: HAR §3.3] |
| Delete the area's automation | Assumed no, as above | Never | [assumed; the manual already says so, H6] |
| `{"enabled": false}` on the area's instance | — | Refused, HTTP 400 | [community: HAR §3.2, Home Assistant issues #153935, #160393]; and it is `accessory` (H2), which F6 rules out anyway |
| Rewrite its `configuration` to Do nothing from the driver | Yes, if the bridge takes it (H4 shows the target shape) | Not in 1.5 (D9, Q2) | [assumed] |

So the answer to the owner's first ask: **back it out in the Hue app with
Do nothing, never switch the area off.** The audit recognises the result as
"does nothing" (D5) and stops listing it as a conflict.

### 2.4 Switches and sensors

- A switch's or sensor's behaviour is an `accessory` instance (dimmer
  switch, tap dial, wall module, smart button, motion sensor, contact
  sensor) [verified: HAR §4, H1]. The `button` services only report presses
  [verified: aiohue `button.py`, HAR §4.1].
- The API cannot switch them off (F6). The Hue app can: change what the
  buttons or time slots do, or reset the device and hand it to "another
  app" [community: HAR §4.3].
- A motion sensor's `motion.enabled` false stops it reporting at all, which
  would blind Control4's Hue Motion device too [verified:
  [motion-hue-research.md](motion-hue-research.md) §1.3, §4.1]. Forbidden.
- Legacy v1 rules made by third-party apps can hold switch set-ups too; the
  audit cannot see them (F14).

### 2.5 The code today

| What | Where | Status |
| --- | --- | --- |
| Keyed requests: `bridge_request({method, path, body}, cb)`, which also sees a rejected key (403) | `src/hue_bridge/driver.lua:387` | [verified] |
| The resync chain: lights → scenes (full tier only) → zone lights → motion, rows refreshed after | `src/hue_bridge/driver.lua:702` | [verified] |
| Stream fan-out to each module's `on_container`; rows refreshed on `add`/`delete` and on some motion updates | `src/hue_bridge/driver.lua:844`, `:550` | [verified] |
| Attention: one string built from each module's items, joined with "; ", word-wrapped onto six rows | `src/hue_bridge/driver.lua:583`, `:638`; `bridge/rows.lua` | [verified] |
| List rows: `rows:list(name, summary, items)`, a pick snaps back | `src/hue_bridge/driver.lua:632`; `bridge/rows.lua:1` | [verified] |
| Pickers: CUSTOM_SELECT functions, folders verified on OS 3.4.2; one picker cannot see another's value | [simplify-actions-design.md](simplify-actions-design.md) §2.3 | [verified: house build 447] |
| Diagnostics ▸ "Read everything from the bridge now" runs the full resync | `src/hue_bridge/driver.lua:2094` | [verified] |
| Motion diagnostics already read `behavior_script` and `behavior_instance`, redacted | `src/hue_bridge/bridge/motion_diag.lua:174` | [verified] |
| Room and zone member lights | `bridge/zone_lights.lua:312` (`member_lights`), `:301` (`group_of`) | [verified] |
| Persistence keys are prefixed `hue_`; values may be tables | [design.md](design.md) "Storage"; `C4:PersistSetValue` in `~/c4-tools/reference/docs-driverworks-api/source/includes/26.5_persistence/_4-PersistSetValue.md` | [verified] |
| PersistSetValue values survive an update in place and a reboot; deleting and re-adding the driver loses them | [design.md](design.md) "Storage" | [verified: house] |
| The controller registry is for global values; Snap One says drivers should not keep state there | `~/c4-tools/reference/docs-driverworks-api/source/includes/26_registry/_1-Introduction.md` | [verified] |
| `OnDriverRemovedFromProject` runs when a driver is deleted, for final clean-up | `~/c4-tools/reference/docs-driverworks-api/source/includes/22_miscellaneous/_26-OnDriverRemovedFromProject.md` | [verified]; not defined in `driver.lua` today |
| New properties and actions in `<config>` need no reboot: beta 4 added the On State Follows property and installed in place with no Restart Director prompt | [status.md](status.md) (beta 4 install, 2026-10-27) | [verified] |
| 1.2 already lifted D7 for names (two-way names) | [simplify-actions-design.md](simplify-actions-design.md) §3.1, Q7 | [verified] |

## 3. Decisions

| # | Decision | Reason |
| --- | --- | --- |
| D1 | **The audit reads by itself; the remedy only follows a click.** No write is ever sent from an event, a resync, a start, a timer or a removal. | Owner's expected shape (#280); CLAUDE.md "Edge cases before automation". |
| D2 | **The one write is `PUT /clip/v2/resource/behavior_instance/<rid>` with `{"enabled": false}` or `{"enabled": true}`**, only on instances that pass D6. Never `configuration`, `trigger`, `metadata`, POST or DELETE; never a write to a sensor, area, switch or scene. This amends D7 of motion-design.md for automations only. | It is the Hue app's own on/off switch, so anyone can undo it in the app, with or without Control4 (F5). Every other write is either refused (F6), invisible in the app (F7), or not reversible with confidence (HAR §6.5). |
| D3 | **Control4 lights** are: the light of every linked Hue Light device (kind light); every member light of a room or zone with a linked Zone Light device; every member light of the room or zone of a linked Hue Scene device. Unbound devices count; forgotten, deleted (tombstoned) and gone ones do not. Hue Motion devices change no lights. | These are the lights a Control4 device of this bridge can change. The driver cannot read Control4 programming [assumed: no DriverWorks call for it was found], so "has a device" stands for "Control4 controls it". |
| D4 | **An automation's targets** are collected without knowing the script's schema: every `{rid, rtype}` in `configuration` and in `dependees`, expanded to lights: `light` itself; `device` → its light services; `room`, `zone` → member lights; `grouped_light` → its owner's lights; `scene`, `smart_scene` → its group's member lights; `bridge_home` → every light. These rtypes are **triggers**, never targets: `button`, `relative_rotary`, `motion`, `convenience_area_motion`, `security_area_motion`, `motion_area_configuration`, `contact`, `camera_motion`, `light_level`, `geofence_client`, `behavior_instance`, a `device` with no light service. `entertainment_configuration` and `recipe` are neither. | F9, F10. Works on scripts the driver has never seen. |
| D5 | **"Does nothing":** when `configuration` holds at least one value under a key named `action`, and every such value is the string `do_nothing`, the instance acts on no light, whatever `where` says. | H3, H4: after Do nothing the room stays in `where` and `dependees`, but nothing happens. Automation-category scripts (Wake up, Schedule) have no `action` key, so they never match. |
| D6 | **The remedy class**, decided per instance from its script and shape: **Disable** for category `automation` with no `state.pm_state` and not the smoke-alarm script; **Hue app steps** for everything else (accessory, play/stop, safety, other, unknown scripts) and for any instance the bridge refused on this firmware (D12). | F5 to F7. Only the flag the app shows is ever written. |
| D7 | **When it fires** (decides Attention): **on its own** = a time (`when`, `when_extended`), presence (Coming home, Leaving home), a sensor (`motion`, `source` of a sensor or area, `contact`, `camera_motion`), Mimic presence while `state.pm_state` is `started`, and any instance of an unknown script; **a person starts it** = a switch (`buttons`, `button1`…`button4`, `rotary`, a `button` dependee), Timers, Go to sleep without `when`, Mimic presence while stopped; **safety** = the smoke-alarm script; **not audited** = category `entertainment`. | A switch press is a person choosing, which Control4 then sees through the stream (L6). Unknown scripts are treated as the riskier case but never written to. |
| D8 | **A conflict** is an instance that is enabled, fires on its own (D7), is not "does nothing" (D5), is not kept (D10), and whose targets include a Control4 light (D3). Conflicts go on Attention. A person-started instance on Control4 lights is **shared** (row only). An enabled instance whose targets cannot be worked out (no target rtype found) is **can't tell which lights** (row only). | Precise, computable, quiet for what a person does on purpose. |
| D9 | **No configuration writes in 1.5**, not even the MotionAware "Do nothing" rewrite. MotionAware, sensors and switches get Hue app steps. | No public schema; a PUT replaces the whole object; Restore could be refused if a referenced scene went meanwhile, leaving the owner to rebuild time slots by hand, which makes the manual fix harder (CLAUDE.md). The verified app recipe takes a minute. Q2 asks whether to revisit. |
| D10 | **Keep on the Hue side** is a per-instance mark held by the bridge driver, never sent to Hue. It stores the Control4 light rids the instance acted on when kept. It lasts until **Stop keeping**, or until the instance is deleted. If the instance starts acting on a Control4 light not in that set, it is listed again, naming only the new lights. | The owner's "ignore" list; never silent about new overlap. |
| D11 | **The record** (what Control4 disabled, and the keeps) lives in the bridge driver's `PersistSetValue("hue_automations", …)` only, keyed by bridge id. No controller-registry copy. | It survives an update in place and a reboot [verified]. The registry is not for state (section 2.5). The case it would cover (driver deleted and re-added) is handled by D16: a disabled automation stays visible and can be turned on again from the Hue app or from the new driver's Restore folder. |
| D12 | **A refusal is remembered per firmware.** A PUT answered 4xx, or answered 2xx while a read-back still shows `enabled` true, marks the instance "Hue app only" with the bridge firmware version. A new firmware clears the marks; the next click tries again. | Never retry on its own; let a firmware change re-open the door. |
| D13 | **Write-ahead.** The record entry is persisted as `pending` (or `restoring`) **before** the PUT and confirmed by a GET after it. A PUT with no answer stays pending and is resolved by the next successful read, never by sending again. | An unknown outcome (timeout, restart in between) never loses what was sent. |
| D14 | **Never fight.** An automation Control4 disabled that is enabled again outside Control4 (the Hue app, another app, a backup restore, an edit saved in the app) becomes **on again**: Attention, and an offer to disable it again or keep it. The driver never disables it again by itself, and never enables anything by itself, not even when a conflict ends. | Household members share the Hue side; the driver cannot tell who acted (F13). |
| D15 | **Restore keeps.** After Restore, an automation that still acts on Control4 lights is kept (D10) automatically, so Attention does not list it right after the owner's own click. Last Action says so and names Stop keeping. | The owner just chose it. |
| D16 | **Restore also offers what Control4 did not disable**: automation-category instances that are disabled in Hue with no record, in a subfolder labelled "Disabled outside Control4". | Makes the manual fix easier after a lost record (driver deleted and re-added, controller replaced). Still one click, still the app's own switch. |
| D17 | **v1 is not read.** The row's last line and the manual say what the audit cannot see: other apps' v1 rules and schedules, Hue Labs formulas, and Alexa, Google Home, Apple Home and Home Assistant routines. | CLAUDE.md: CLIP v2 only; the house has no sign of v1 content; revisit if a user reports one. |
| D18 | **When the audit reads:** `GET /clip/v2/resource/behavior_instance` in every **full** resync, as the chain's last step; `GET /clip/v2/resource/behavior_script` the first time, when an instance names an unknown script id, and when Bridge Firmware changes. The quick tier skips both; the stream keeps the cache current between full reads. Before every Disable or Restore, one fresh GET of the instance. No polling. | Two small GETs per full read (1 instance and 14 scripts on the house). Fits the hourly budget of [simplify-actions-design.md](simplify-actions-design.md) §4 finding 7. |
| D19 | **Re-evaluation without a GET** after every registry change (add, import, link, forget, goodbye, reconcile) and every automation stream item: conflicts are computed, never stored. | Cheap (a few hundred references at most). Conflicts follow Composer at once. |
| D20 | **One new bridge action, Hue Automations**, with one picker, `Automation`, whose folders hold the verbs. Bridge actions go from 9 to 10. | 1.2 set 9 actions (#334), so this needs a reason: the remedy is a write to Hue that must follow a person's click (D1); no existing action's intent covers it (Diagnostics is for support; Resolve Names is about names); folders keep it to one picker and one click; Composer pickers cannot see each other's value, so verbs and targets share one picker (section 2.5). Q1 asks the owner to confirm. |
| D21 | **Hue switches stay off Attention** (row only, "shared"). | A person pressing a Hue switch is not a Hue automation acting alone, and Control4 sees its effect (L6). Q3. |
| D22 | **Safety lighting** (the smoke-alarm script) is listed as kept by default and never offered for Disable. | A lighting driver should not switch off an alarm response. |
| D23 | **Deleted in Hue:** an entry whose instance a successful full read no longer lists is dropped, with one `log.always` line and a row line for the rest of this run. A failed GET marks nothing. Restore never re-creates (no POST). | Nothing is actionable; the log keeps the fact. Precedent: only a successful full read marks a light gone ([edge-cases-hue.md](edge-cases-hue.md)). |
| D24 | **Another bridge:** a record whose bridge id differs from the paired bridge's is set aside, never acted on, shown as one row line, and offered for "Forget that record" in the Restore folder. | Pair Bridge already refuses a different bridge until Forget Pairing [verified: `bridge/pairing.lua`]. Instances on the new bridge with the same ids, if a transfer kept them, are handled by D16. |

## 4. Lifecycle edge cases

"Automatic" = done by itself, read-only; "Offered" = one click in the Hue
Automations action; "Forbidden" = never without a click. Ids follow EAD
where the case is the same.

### 4.1 The Hue side

| # | Case | Automatic | Offered | Forbidden |
| --- | --- | --- | --- | --- |
| H1 | Automation created in the Hue app or another app, acting on Control4 lights | Classified, listed, logged once; Attention if a conflict (D8) | Disable (D6) or Hue app steps; Keep | Disabling it by itself |
| H2 | Created, acting only on lights Control4 does not control | Row line "Elsewhere"; no Attention | — | Counting it as a conflict |
| H3 | Edited in the Hue app while enabled (times, scenes, lights) | Targets worked out again (D19) | As H1 | — |
| H4 | Edited in the Hue app while Control4 has it disabled | Entry kept, marked "changed in Hue since" (signature of `configuration` and `metadata.name` differs) | Restore enables it as it is now; Last Action says it changed | Writing the old configuration back |
| H5 | Renamed in Hue | Row and picker show the new name; the entry keeps the old one for Last Action ("Hall timer (was Hallway timer)") | — | Renaming in Hue |
| H6 | Turned on again outside Control4 while Control4 has it disabled (the app, another app, an edit saved in the app [assumed], a backup restore) | Entry becomes **on again**; Attention (D14) | Disable again; Keep (drops the entry) | Disabling it again by itself |
| H7 | Disabled in Hue by someone else (no entry) | Row "Disabled outside Control4"; not a conflict | Restore subfolder (D16) | Adopting it into the record |
| H8 | Its targets grow to new Control4 lights (edited, or a light added to its room or zone) | Not kept: as H1. Kept: listed again naming only the new lights (D10) | Keep again; Disable | — |
| H9 | It no longer acts on any Control4 light | Not disabled: moves to "Elsewhere". Disabled by Control4: row says "no longer on Control4 lights" | Restore | Enabling it by itself |
| H10 | Deleted in Hue, or deleted by the bridge because a critical dependee went (its room, scene, switch) | D23: dropped after a successful full read, logged | — | Re-creating it; marking it deleted on a failed GET |
| H11 | Deleted and made again (new id) | H10 for the old, H1 for the new | As H1 | Carrying a disable or keep over by name |
| H12 | Partial overlap: Control4 lights and other lights | A conflict; the picker line says "also N lights outside Control4" | Disable; Last Action names what else stops following it | Removing the Control4 lights from it (a configuration write) |
| H13 | MotionAware area automation (accessory, H2) acting on Control4 lights | Conflict; marked "(MotionAware)" | Hue app steps: the Do nothing recipe (section 6.5); Keep | `enabled` on the instance; the area's `enabled`; its services; configuration writes |
| H14 | MotionAware area automation set to Do nothing (the house today) | "Does nothing" (D5): row line, no Attention | — | — |
| H15 | Motion or contact sensor set-up acting on Control4 lights | Conflict; marked "(motion sensor)" | Hue app steps; Keep | `motion.enabled` false (blinds Control4) |
| H16 | Hue switch (dimmer, tap dial, button, wall module) on Control4 lights | "Shared" row line (D21) | Keep; Hue app steps | Any write to it |
| H17 | Mimic presence (play/stop) | Started: conflict, steps only. Stopped: shared | Hue app steps; Keep | `enabled` or `trigger` writes |
| H18 | Smoke-alarm light-up | "Safety lighting (kept)" (D22) | — | Disabling it |
| H19 | Entertainment "light state after streaming" | Counted as not audited | — | Any write |
| H20 | Instance of a script the driver has not read (new firmware, Custom AI Behaviors) | One script GET (D18); until it answers: "not classified yet", no Disable | After it is read: as its class | Any write before its category is known |
| H21 | A firmware update changes script ids or shapes | Scripts re-read on the Bridge Firmware change; classification is by category and shape first (D6, D7), so a new id with a known category still works; refusal marks cleared (D12) | As H1 | Matching old records by script id; any write by itself |
| H22 | Status `errored` | Listed with `last_error`; still a conflict while enabled | As H1 | — |
| H23 | Bridge restored from a Hue backup | Entries reconcile at the next full read: enabled → H6; missing → H10; new ids → H1 | As H6 and H1 | Disabling again by itself |
| H24 | Bridge replaced through the app's transfer (new bridge id) | D24: old record set aside; disabled instances on the new bridge show as H7 | Restore subfolder; Forget that record | Re-attaching by name |
| H25 | Bridge factory reset or key revoked (403) | No audit, no writes; record kept; after pairing, D23 at the first full read | Pair Bridge | — |
| H26 | Bridge offline or rebooting | Row says "as of HH:MM"; clicks refused ("the bridge is not answering; nothing was changed"); nothing marked deleted | — | Queuing a click for later |
| H27 | Hue Bridge (square, v2) | Everything except MotionAware, which it lacks [verified: [motion-hue-research.md](motion-hue-research.md) §2.7]; behaviour instances exist on both [verified: HAR §2, the 2023 dump is a v2 bridge] | — | — |
| H28 | A smart scene started from Control4 by a Hue Scene device | Not an instance; not audited | — | Deactivating it from the audit |
| H29 | v1 rules, cloud routines | Not seen; the coverage line (D17) | — | Claiming "no conflicts" without it |

### 4.2 The Control4 side

| # | Case | Automatic | Offered | Forbidden |
| --- | --- | --- | --- | --- |
| C1 | A light, zone light or scene device added or imported | Re-evaluated (D19); new conflicts on Attention | Disable or steps; Keep | Disabling because of the import |
| C2 | A device forgotten, deleted in Composer, or its Hue thing gone | Re-evaluated; a disabled automation that no longer conflicts shows "no longer on Control4 lights" | Restore | Enabling by itself |
| C3 | A device re-linked or adopted | Re-evaluated | — | — |
| C4 | A Hue Motion device added or removed | Nothing changes in conflicts (D3); the row names the device next to an area's or sensor's automation | — | — |
| C5 | Bridge driver updated in place | Record kept [verified]; the first build with the feature has no record, so earlier disabled automations show as H7 | — | — |
| C6 | Director restart, controller reboot | Record loaded at late init; pending entries resolved at the first successful read (D13) | — | Any write at start |
| C7 | Project restored from a backup | Whatever the store holds is reconciled with the bridge at the first full read (bridge wins) | As H6, H7 | Re-applying an old disable |
| C8 | Forget Pairing while Control4 has automations disabled | Record kept; Last Action names them: "Control4 still has 2 Hue automations disabled on this bridge: …; pair again to restore them, or turn them on in the Hue app" | Pair Bridge | Dropping the record |
| C9 | Bridge driver deleted while automations stay disabled | `OnDriverRemovedFromProject` writes one `log.always` line naming them; they stay off on the bridge, visible in the Hue app | — (the manual: restore first) | Enabling them from the removal callback (an unclicked write) |
| C10 | Bridge driver added again and paired with the same bridge | Empty record; the disabled ones appear as H7 | Restore subfolder (D16) | — |
| C11 | Controller replaced or reset | As C10 when the store did not travel | As C10 | — |
| C12 | Two Hue Bridge drivers paired with one bridge (a mistake) | Each keeps its own record; the second's Disable of an instance already disabled is refused as "already disabled" | — | — |
| C13 | OS 3.x to 4.x | Nothing: only PersistSetValue (2.10.0+) and CUSTOM_SELECT, both used today | — | — |

### 4.3 Runtime

| # | Case | Behaviour |
| --- | --- | --- |
| R1 | Disable, normal path | Busy and paired checks; fresh GET; refuse with a reason if deleted, already disabled, not class Disable, marked Hue app only, or no longer a conflict (unless "can't tell which lights" and chosen); entry persisted `pending` with name, kind, script id, Control4 light names and signature; PUT; GET; `enabled` false → `disabled`. |
| R2 | 2xx but the read-back says `enabled` true | Entry dropped; marked Hue app only (D12); Last Action "accepted but not applied" and the Hue app steps. |
| R3 | 4xx | Entry dropped; marked Hue app only; Last Action quotes the error words only if they are plain (as motion_diag's vocabulary), else "the bridge refused". |
| R4 | No answer | Entry stays `pending`; Last Action "not confirmed; Control4 checks again when the bridge answers"; Attention after 10 minutes. |
| R5 | "Every one listed" | One instance at a time, each with its GET; successes kept, failures reported; no rollback. |
| R6 | Restore | Fresh GET: deleted → entry cleared, "nothing to restore"; already on → entry cleared; off → `restoring`, PUT true, GET, cleared; kept if it still conflicts (D15). |
| R7 | Restore after an edit in Hue | Enabled as it is now; Last Action names what changed when it can (name, lights), else "its settings". |
| R8 | Race with the household | The bridge's last write wins; H6 handles it. |
| R9 | Clicks during a resync, an import or another click | Refused: "Busy: reading the bridge; try again in a moment" (owner.lua's busy texts). |
| R10 | Pace | Writes go one at a time through `bridge_request`, not the light queues, and set `state.last_write_ms` like other user writes, so housekeeping yields. |

## 5. Control4 guidelines

The feature changes who moves the lights, not how a Control4 light behaves.
Rows from [c4-lighting-guidelines.md](c4-lighting-guidelines.md):

| Row | How this feature meets it |
| --- | --- |
| L6 | Unchanged: changes made by Hue automations still reach the proxies promptly. The feature only reduces how often they happen. |
| L53, L68 | Unchanged: LEDs and proxy events still follow Hue-side changes. |
| L73 | The new **Hue Automations** row is a DYNAMIC_LIST like Lights and Scenes: a pick changes nothing and snaps back. Its summary stays under 75 characters. |
| L74 | The row gets a `<tooltip>`: "Open the list to read every Hue automation and how it meets Control4". The action's parameter is a CUSTOM_SELECT (no free text). |
| L76 | The action is setup, not everyday use: it decides once per automation. Nothing goes on the light or scene devices. |
| L79 | No command, event or variable is removed or renumbered. Diagnostics and Forget Pairing move down one `sort_order` (presentation only). |
| L82 | No `<capabilities>` change in any driver. |
| L83 | The record persists across updates and restarts; a malformed stored value is dropped with a log line (as the other stores). |
| L87 | While the bridge is unreachable or rejects the key, Disable and Restore are refused and say nothing was changed; nothing is queued. |
| L88 | Attention items say what is wrong and end with the action to use; Last Action says what was written, or why not, and the next step. |

No departure.

## 6. Interfaces

### 6.1 The new modules

**`src/hue_bridge/bridge/automation_model.lua`** (pure Lua, no C4 calls):

```lua
local model = require("bridge.automation_model")
model.script(item)            -- { rid, name, category ("automation"|"accessory"|"entertainment"|"other"|""), version }
model.instance(item)          -- { rid, script_rid, name, enabled, status, last_error, pm_state,
                              --   migrated (bool), refs = { {rid, rtype, where = "configuration"|"dependee"}, ... },
                              --   actions = { "do_nothing", "all_off", "recall", ... }, sig = "<string>" }
model.update(inst, item)      -- merge a stream update into an instance; returns true when refs/actions/enabled changed
model.inert(inst)             -- D5
model.fires(inst, script)     -- "own" | "person" | "safety" | "none" (D7)
model.remedy(inst, script)    -- "disable" | "steps" (D6, before refusal marks)
model.kind(inst, script)      -- the word for texts: "wake up", "go to sleep", "schedule", "timer",
                              -- "coming home", "leaving home", "mimic presence", "natural light",
                              -- "MotionAware", "motion sensor", "contact sensor", "Hue switch",
                              -- "safety lighting", else the script's name, else "automation"
model.trigger_rtypes, model.target_rtypes   -- the sets of D4
model.signature(item)         -- a stable string of configuration and metadata.name (sorted keys)
```

`kind` uses shape first (`configuration.motion` + an area `source` →
"MotionAware"; `configuration.motion` + a device `source` → "motion sensor";
`buttons`/`button1`/`rotary` → "Hue switch"), then known script names and
the public script ids of HAR §2 (`ff8957e3…` wake up, `7e571ac6…` go to
sleep, `7238c707…` schedule, `e73bc72d…` timers, `fd60fcd1…` coming home,
`0194752a…` leaving home, `db06cabc…` mimic presence, `a4260b49…` natural
light, `7719b841…` light state after streaming, `f306f634…` tap switch,
`67d9395b…` Hue Accessories). Ids are a hint, never the only key (H21).

**`src/hue_bridge/bridge/automations.lua`** (the owner of the audit):

```lua
local automations = require("bridge.automations")
local a = automations.new(ctx)
-- ctx = {
--   http        = fn(req, cb)                 -- bridge_request
--   log, now    = os.time, now_ms
--   persist_get = fn(key), persist_set = fn(key, value)
--   bridge_id   = fn() -> "001788fffe123abc" or nil (paired bridge)
--   firmware    = fn() -> Bridge Firmware text or nil
--   paired      = fn() -> bool                -- connection() and not key-rejected
--   control4    = fn() -> { lights = { [light_rid] = "Composer name" },
--                           via = { [light_rid] = "Zone Light or Scene device name" } }
--   expand      = fn(rid, rtype) -> { light_rid, ... }   -- D4, from the lights' and zone lights' caches
--   light_name  = fn(light_rid) -> Hue name
--   motion_device = fn(source_rid) -> Composer name or nil  -- the Hue Motion device of an area or sensor
--   last_action = fn(text), changed = fn()   -- changed: rows and Attention need a refresh
--   busy        = fn() -> text or nil         -- another job runs (owner busy texts)
--   wrote       = fn()                        -- sets state.last_write_ms
-- }
a:load()                     -- read hue_automations; drop malformed parts with a log line
a:resync(done, tier)         -- tier "quick": done(true) at once; else the GETs of D18; done(ok, err, 0)
a:on_container(container)    -- behavior_instance / behavior_script add, update, delete; returns true when rows change
a:evaluate()                 -- D3-D8, D10 against ctx.control4(); cheap; called by the coordinator (D19)
a:summary()                  -- row summary (6.3)
a:list_items()               -- row drop-down lines (6.3)
a:attention_items()          -- 6.4
a:picker(folder)             -- list, back (6.2)
a:run(params)                -- the action; ends in ctx.last_action
a:forget_pairing_text()      -- C8's sentence or nil
a:removal_text()             -- C9's sentence or nil
```

### 6.2 The action

`driver.xml` (coordinator), after Set Room Mapping:

```xml
<action>
	<name>Hue Automations</name>
	<command>Hue Automations</command>
	<sort_order>8</sort_order>
	<params>
		<param>
			<name>Automation</name>
			<type>CUSTOM_SELECT:HueAutomationList</type>
		</param>
	</params>
</action>
```

Diagnostics becomes `sort_order` 9, Forget Pairing 10. `driver.lua`:
`function HueAutomationList(folder) return picker(state.automations, "picker", folder) end`
and `dispatch.commands["Hue_Automations"] = function(params) if can() then state.automations:run(params) end end`.

Picker values (stable, logged, never shown):

| Value | Shown as | Does |
| --- | --- | --- |
| `f:off` (folder) | "Disable in Hue (3 on Control4 lights)" | opens |
| `off:all` | "Every one Control4 can disable (2)" | R5 over class Disable conflicts and "on again" entries |
| `off:<rid>` | "Wake Weekdays (wake up) on Bedroom Lamp +2" | R1; for class steps: Last Action gets the Hue app steps, nothing written. Steps-only lines end "(Hue app only)" and come last |
| `f:on` (folder) | "Restore (2 disabled by Control4)" | opens |
| `on:all` | "Everything Control4 disabled (2)" | R6 over every entry |
| `on:<rid>` | "Wake Weekdays (disabled 11-09; changed in Hue since)" or "(on again outside Control4: forgets the record)" | R6 |
| `f:on:other` (folder inside `f:on`) | "Disabled outside Control4 (1)" | opens (D16) |
| `other:<rid>` | "Vacation lights (schedule; not disabled by Control4)" | PUT true as R6, no entry needed |
| `forget:<bridge_id>` | "Forget the record of bridge …3abc (2 automations)" | D24; nothing written to Hue |
| `f:keep` (folder) | "Keep on the Hue side (4)" | opens |
| `keep:<rid>` | "Bedroom dimmer (Hue switch) on Bedroom Lamp" | D10 |
| `keep:shared` | "Every Hue switch and timer listed (2)" | D10 over shared lines |
| `f:unkeep` (folder) | "Stop keeping (1)" | opens |
| `unkeep:<rid>` | "Bedroom dimmer (kept 11-09)" | drops the keep; re-evaluated |
| `""` | one explanatory row when empty ("(no Hue automations to act on)", "(not paired)", "(not read yet; Diagnostics ▸ Read everything from the bridge now)") | Last Action repeats it |

A folder that would be empty is left out. A folder value picked directly
writes nothing: "Not changed: Disable in Hue is a folder; open it and pick
one inside" (as Link Device).

### 6.3 The row

Property (coordinator), after Motion Sensors:

```xml
<property>
	<name>Hue Automations</name>
	<type>DYNAMIC_LIST</type>
	<readonly>false</readonly>
	<tooltip>Open the list to read every Hue automation and how it meets Control4</tooltip>
</property>
```

Summary: `N on bridge, N on Control4 lights, N disabled by Control4`, then
only when not 0: `, N on again`, `, N not confirmed`, `, N kept`. Before the
first read `Not read yet`; unpaired `Not paired`; a failed last read appends
` (as of 14:02)`. Example: `12 on bridge, 3 on Control4 lights, 2 disabled by Control4, 1 kept` (64 characters).

Drop-down, one line per instance, `<state>: <name> (<kind>) on <lights>`;
Control4 lights by Composer name, others by Hue name, three then `+N`; in
this order:

1. `On Control4 lights` (conflicts; `(kept; now also Desk Lamp)` where D10 applies; `(Hue app only)` for class steps)
2. `On again outside Control4`
3. `Not confirmed`
4. `Disabled by Control4 11-09` (with `; changed in Hue since` or `; no longer on Control4 lights`)
5. `Kept`
6. `Shared (a person starts it)`
7. `Does nothing` (D5; for an area: `Does nothing: Kitchen motion area (MotionAware), Control4 decides`)
8. `Can't tell which lights`
9. `Safety lighting (kept)`
10. `Disabled outside Control4`
11. `Elsewhere`
12. `Not classified yet`
13. `Deleted in Hue since Control4 disabled it` (this run only, D23)
14. `Bridge …3abc: N automations Control4 disabled there` (D24)
15. `Not audited: N entertainment settings`
16. always last: `Not seen here: other apps' v1 rules, Hue Labs, Alexa, Google, Apple Home routines`

### 6.4 Attention

Appended after the names' items in `attention_text()` (`driver.lua:583`),
in this order, each naming three then `+N more` (`util.some`), singular and
plural by `util.plural`:

1. `2 Hue automations act on Control4 lights: Wake Weekdays, Kitchen motion area (Hue Automations)`
2. `1 Hue automation Control4 disabled is on again: Wake Weekdays (turned on outside Control4; Hue Automations)`
3. `1 Hue automation change not confirmed: Wake Weekdays (Hue Automations)` (only after 10 minutes pending)

Never on Attention: shared, kept, does nothing, can't tell, safety,
disabled outside Control4, elsewhere, not classified, deleted, another
bridge's record, and a stale read (Status already says the bridge is away).

### 6.5 Last Action texts

- Disable: `Disabled in Hue: Wake Weekdays. It stays on the bridge and shows as off in the Hue app; Hue Automations ▸ Restore turns it on again.` With H12: `… It also controlled Porch Light and Garage, which Control4 does not control: they no longer follow it either.`
- Bulk: `Disabled 2 of 3 Hue automations: Wake Weekdays, Hall timer. Not disabled: Kitchen motion area (Hue app only; open it again for the steps).`
- Restore: `Turned on again in Hue: Wake Weekdays (disabled by Control4 since 11-09). It acts on Bedroom Lamp and 2 more Control4 lights, so it is now kept (Hue Automations ▸ Stop keeping lists it again).`
- Keep: `Kept Bedroom dimmer on the Hue side: Attention no longer lists it unless it starts acting on other Control4 lights.`
- Refused: `Not disabled: Wake Weekdays: the bridge refused (HTTP 400); nothing was changed. In the Hue app: Automations, Wake Weekdays, switch it off.`
- Not answering: `Not disabled: the Hue bridge is not answering; nothing was changed.`
- **Hue app steps** (wording checked against the app on the house before release, check HC4; the app's labels move between versions):
  - MotionAware: `Kitchen motion area is a MotionAware set-up the bridge does not let other apps switch off. In the Hue app open the area's automation, keep one time slot for the whole day, set On motion to Do nothing and When motion stops to Do nothing, and save. Do not switch the area off or remove its automation: the area would stop reporting motion to Control4.`
  - Motion or contact sensor: `Hallway sensor's behaviour is a sensor set-up. In the Hue app open the sensor, set every time slot to Do nothing on motion and when motion stops, and save. Leave the sensor on: Control4 reads its motion.`
  - Hue switch: `Bedroom dimmer is a Hue switch. To stop it moving Control4 lights, open it in the Hue app and point its buttons elsewhere, or reset it and set it up in another app. Or keep it (Hue Automations ▸ Keep on the Hue side).`
  - Mimic presence: `Away lights is started and stopped in the Hue app: Automations, Away lights, stop.`
  - Unknown script: `Evening routine is a kind of Hue automation this driver does not switch off. Change or switch it off in the Hue app, where it is listed under its room.`

### 6.6 Persisted record

Key `hue_automations`, a table (PersistSetValue takes tables, section 2.5):

```lua
{
	v = 1,
	bridge_id = "001788fffe123abc",
	entries = {                 -- what Control4 disabled, by instance rid
		["<rid>"] = {
			state = "disabled",     -- "pending" | "disabled" | "restoring" | "on_again"
			name = "Wake Weekdays", kind = "wake up", script_rid = "<rid>",
			lights = { "Bedroom Lamp", "Bedroom Ceiling", "Bedside" },  -- Composer names then, for texts
			sig = "<signature then>",
			at = 1793000000, on_again_at = nil,
		},
	},
	kept = { ["<rid>"] = { name = "Bedroom dimmer", at = 1793000000, lights = { ["<light rid>"] = true } } },
	refused = { ["<rid>"] = "<firmware>" },   -- D12
	other = { ["<bridge id>"] = { entries = { … } } },   -- D24, shown only
}
```

Written after every change and before every PUT (D13). Memory only, never
persisted: the script and instance caches.

### 6.7 What changes in which file

| File | Change | Owner |
| --- | --- | --- |
| `src/hue_bridge/bridge/automation_model.lua` | new (6.1) | part A |
| `src/hue_bridge/bridge/automations.lua` | new (6.1-6.6) | part B |
| `src/hue_bridge/driver.lua` | require; `state.automations = automations.new(module_ctx({...}))` at late init; `a:load()`; resync chain step after motion (full tier); `on_container` fan-out and a row refresh when it returns true; `evaluate()` at the top of `refresh_lights_props`; Attention items; `show_module_list("Hue Automations", state.automations)`; the picker global and command (6.2); `list_pick("Hue Automations")`; Forget Pairing appends `forget_pairing_text()`; new `OnDriverRemovedFromProject` logging `removal_text()`; `motion_diag` untouched | coordinator |
| `src/hue_bridge/driver.xml` | the property (6.3) and action (6.2); sort orders | coordinator |
| `tests/spec/automations_roundtrip_spec.lua` | new (section 8) | coordinator |
| `tests/fixtures/ledger.lua`, `tests/spec/ledger_spec.lua` | the new action in the ledger; the `sort_order` uniqueness still holds | coordinator |
| `src/hue_bridge/www/documentation.html`, `docs/composer-checklist.md`, `docs/motion-design.md` (D7 amended), `docs/edge-cases-motion.md` (R9, S12 now point here), `docs/c4-lighting-guidelines.md` (L76 evidence: 10 actions), `docs/README.md` (index entry), `CHANGELOG.md` (`## Unreleased`) | text | part C |
| `CLAUDE.md`, `docs/status.md` | scope line, "Open" | coordinator |

`driver.lua`'s main chunk must stay under `tools/lua_limits.py`'s limits
(137 of 180 locals today): the new module is one `local` require and one
picker global; put the context in a function, as `new_actions()` does.

## 7. Implementation split

| Part | Owns (creates or edits only these) | Done when |
| --- | --- | --- |
| A model | `src/hue_bridge/bridge/automation_model.lua`, `tests/spec/automation_model_spec.lua`, `tests/fixtures/hue_automations.lua` (new: invented ids in the shapes of H3, H4 and HAR §1.8: a wake up, a schedule, a timer, coming home, mimic presence started and stopped, a dimmer switch, a tap dial, a MotionAware set-up before and after Do nothing, a motion sensor set-up, light state after streaming, an unknown script, a smoke alarm) | `busted tests/spec/automation_model_spec.lua` passes; `luacheck` clean |
| B owner | `src/hue_bridge/bridge/automations.lua`, `tests/spec/automations_spec.lua` (uses part A's fixture file read-only; builds against 6.1's model interface, stubbing it until A lands) | `busted tests/spec/automations_spec.lua` passes; `luacheck` clean |
| C docs | the docs row of 6.7 | `python3 tools/check_links.py` passes |
| Coordinator | `driver.lua`, `driver.xml`, roundtrip spec, ledger, `CLAUDE.md`, `docs/status.md` | `tools/check.sh` and `tools/build.sh` pass |

Conventions for every part: Lua 5.1, tabs, `.luacheckrc`, busted with the
fake C4 runtime under `tests/`, every callback body `pcall`-wrapped, one GET
at a time. Others edit the rest of the checkout at the same time; no part
runs `git`. Every lighting brief names section 5's rows and the guideline
sources.

## 8. Test plan

**`automation_model_spec.lua`** (part A):

- script parsing: category present, empty, unknown value → `other`.
- refs: every `{rid, rtype}` in `configuration` and `dependees`; a dimmer's
  button-id keys are not refs; malformed items skipped.
- D4: trigger rtypes never targets; `entertainment_configuration` ignored.
- D5: the MotionAware fixture after Do nothing is inert; before it is not; a
  dimmer with one `recall` and three `do_nothing` is not inert; a wake up
  (no `action` key) is never inert.
- D7: each fixture's `fires`; mimic presence started vs stopped; unknown →
  `own`.
- D6: `remedy` is `disable` only for automation-category, non-play/stop,
  non-safety.
- `kind` for every fixture, shape before id; a known id with a new name.
- `update`: an `enabled`-only update; a `configuration` update changes refs
  and signature; `metadata.name` only changes the signature.

**`automations_spec.lua`** (part B), with a fake `http` and a fake
`control4`:

- resync: full reads both types once, quick reads none; script re-read on a
  new script id and on a firmware change; a failed GET marks nothing.
- evaluate: conflict vs shared vs elsewhere vs does-nothing vs can't tell
  (D8); D3 via a zone light and via a scene device; partial overlap (H12).
- keep: lapses only for new lights (D10); Stop keeping; Restore keeps (D15).
- Disable path R1 to R5: write-ahead persisted before the PUT; 2xx + still
  enabled → refused mark; 4xx; timeout → pending, resolved by the next
  read; bulk with mixed results, no rollback.
- Restore path R6, R7, D16 (`other:<rid>`), D24 (`forget:`).
- H6: an update with `enabled` true on a disabled entry → on again,
  Attention, no write.
- H10/D23: a successful read without the instance drops the entry with one
  `log.always`; a failed read keeps it.
- D12: refusal mark cleared by a firmware change.
- picker: folder labels, empty folders left out, folder picks refused,
  empty-picker row.
- summary under 75 characters with every count; drop-down order; the
  coverage line always last; Attention texts singular and plural.
- load: malformed store parts dropped with a log line; another bridge id →
  `other`.
- No PUT is ever sent from `resync`, `on_container`, `evaluate` or `load`
  (a spy on `http` across a simulated stream of every fixture event).

**`automations_roundtrip_spec.lua`** (coordinator): the driver with the
fake runtime: a full resync fills the row; an import makes a conflict
appear on Attention; Disable through `dispatch.commands["Hue_Automations"]`
sends exactly one PUT then one GET; Forget Pairing's Last Action names the
disabled ones; the quick tier sends no behaviour GET; `OnDriverRemovedFromProject`
logs and sends nothing.

**House checks** (for `docs/composer-checklist.md`; through the Windows
session and, for the reads, the dev loop's Hue Request in a `--dev` build,
[dev-loop.md](dev-loop.md); the coordinator can fold them into the sibling
`docs/house-checks-plan.md`; standing approval covers every write, each put
back at once):

```
Hue automation audit (#280)
- HC1 After install: Hue Automations row reads "1 on bridge, 0 on Control4 lights,
  0 disabled by Control4" (or the house's current count); its drop-down shows
  "Does nothing: <area> (MotionAware), Control4 decides" and the coverage line last.
  Attention has no automation item. Lua output: no PUT to behavior_instance.
- HC2 Diagnostics > Read everything from the bridge now: the row is unchanged,
  Last Action names the read.
- HC3 (dev loop, Hue Request) PUT {"enabled": false} on the area's instance:
  record the HTTP status and error words (expected 400); if accepted, PUT
  {"enabled": true} at once and note whether motion kept reaching the device.
- HC4 (owner's phone, about a minute) In the Hue app make a Lighting schedule on
  one Control4 lamp. The row lists it under "On Control4 lights" and Attention
  names it within seconds. Hue Automations > Disable in Hue > pick it: Last Action
  confirms; the Hue app shows it off. Hue Automations > Restore > pick it: on
  again, now kept. Edit it in the app while disabled once, and record whether it
  comes back enabled and keeps its id. Delete it in the app: the row drops it.
  Read the steps texts of 6.5 against the app's labels.
- HC5 Driver update in place and a controller reboot with one automation disabled:
  the row still says "Disabled by Control4" afterwards.
```

## 9. Reboot and changelog

**No controller reboot** for this feature: it adds one property and one
action in `<config>` and changes Lua only; no driver's `<capabilities>`
changes (section 2.5). It can ride in 1.5 beside the capability changes of
the sibling features without adding a reboot of its own.

`CHANGELOG.md`, `## Unreleased`:

```
### Added
- The Hue Bridge checks the automations stored on the Hue bridge (schedules,
  wake-ups, timers, coming home, motion and MotionAware set-ups, Hue switches)
  and lists them on a new Hue Automations row; the ones that move lights
  Control4 controls by themselves appear in Attention. The new Hue Automations
  action switches a chosen one off in Hue with one click (never deletes it),
  remembers what it switched off and turns it back on with Restore, or keeps it
  on the Hue side on purpose. Set-ups the bridge does not let other apps switch
  off, such as a MotionAware area's, get the Hue app steps instead (#280).
```

## 10. Open questions for the owner

All three answered by the owner on 2026-11-09: as recommended (a tenth action; no automatic rewrite in 1.5; switches on the row only).

| # | Question | Recommendation |
| --- | --- | --- |
| Q1 | A tenth bridge action, **Hue Automations** (D20), or fold the remedy into an existing action? | **A tenth action.** Nothing existing fits, and one picker keeps it to one click. |
| Q2 | Later, should the driver itself make a MotionAware or motion sensor set-up "Do nothing" (a configuration write, the original saved for Restore), instead of giving the Hue app steps (D9)? | **Not in 1.5.** The app recipe is verified and the house's area already uses it; revisit only if a tester asks, after a round-trip test on a spare area. |
| Q3 | Hue switches that act on Control4 lights: row only (D21), or Attention until kept? | **Row only.** A person pressing a switch is not an automation acting alone. |

## 11. What is surprising

- The house bridge's only Hue automation is the MotionAware one, and it is
  an `accessory` set-up of the "Hue Accessories" script, which the API
  cannot switch off. On the house the remedy is therefore never the
  one-click Disable but the app recipe, which the owner already applied on
  2026-10-26. The first run on the house should show no conflict at all.
- After Do nothing, the room stays in `where` and `dependees`; only the
  `action` values show that the automation acts on nothing (D5). A rule
  based on `dependees` alone would report a false conflict on the house.
- Turning an area's light control off, which sounds like the obvious way,
  stops the area reporting motion [community].
