# Edge cases and lifecycle policy: the Hue automation audit

> **Research (2026-10-26) for issue #280**, written before the contract, against `main` as of #270 (the house runs release 1.0, build 359) and the motion branch of #268 (`docs/motion-design.md`, `docs/edge-cases-motion.md`); "today" and `[code: …]` mean that code. Read-only. It enumerates the lifecycle corner cases on both sides and recommends, per case, what is automatic, what is only offered and what is forbidden without a click. The owner's answers go into §10; until then the recommended defaults stand. The Hue API side is researched at the same time in `docs/hue-automations-research.md` (HAR below), which had not appeared when this was written: every API fact not confirmed from a public source is marked [assumed], and HAR decides it.

What the bridge driver does on its own, what it only offers and what it
never does without a click, for every event in the life of a Hue
automation that touches lights Control4 controls. The owner's north star
(#280): **Control4 is the source of truth for automations, not the Hue
app.** The feature reads the Hue automations (`behavior_instance`
resources) by itself, reports those that act on Control4 lights, and on a
click disables the chosen ones (never deletes them), records exactly what
it disabled and offers a matching Restore. It changes decision D7 of
`docs/motion-design.md` ("no writes to Hue") for automations only: a write
happens on a click, is reversible and is recorded. It extends
`docs/edge-cases-ux.md`, the rules of `docs/import-design.md` §1 and the
motion policy of `docs/edge-cases-motion.md` (EC below; HR is its Hue
research, `docs/motion-hue-research.md`; both are on the motion branch until
#268 merges) to something that is not a Control4 device.

Four things make this feature different from lights, scenes, zone lights
and motion, and most rows follow from them:

1. **It changes Hue's setup, not only light state.** Until now the driver
   sent light and group commands and scene recalls [code:
   `hue_bridge/driver.lua`, `bridge/scenes.lua`], and the motion devices
   send nothing (D7). A disabled automation is a change to the household's
   Hue setup that outlives Control4's view of it.
2. **No Control4 device stands for what was changed.** A light's device
   keeps its own rid, which makes a lost bridge registry recoverable
   (import-design §1, rule 3). Nothing in the project stands for "Wake up
   Bedroom is off because of Control4", so the record of what the driver
   disabled needs a home that survives the bridge driver itself (§7).
3. **The household shares the Hue side.** Anyone with the Hue app or
   another app can enable an automation again, edit it, delete it or make a
   new one at any time, and the driver cannot tell who did. It must never
   fight them.
4. **The audit sees only part of the picture.** It sees what the bridge
   exposes as behaviour instances through CLIP v2. Rules made through the
   old v1 API, and automations that run in Apple Home, Alexa, Google Home or
   Home Assistant, are invisible to it [assumed], so it says what it cannot
   see instead of reporting "no conflicts".

Status markers as in the other research documents: [verified: …] = the
DriverWorks reference (`API x/_y` =
`~/c4-tools/reference/docs-driverworks-api/source/includes/<x>/<_y>.md`,
`FUND x/_y` = the fundamentals), a document of this repository that holds
the evidence, a recorded dump, or the house; [code: file] = what the
drivers do today; [community: …] = a library, an integration, an issue or
a post, not shown by a dump or on the house; [assumed] = not confirmed
anywhere, to test or for HAR to settle.

## Rules behind every row

The three rules of `docs/import-design.md` §1 hold unchanged:

1. **The project is the owner's.** The feature adds no device and never
   creates, renames, binds, unbinds or re-points one.
2. **Nothing is lost by waiting.** Every finding is listed in a bridge row,
   counted and logged, and stays actionable from Composer a week later
   without the Hue-side event having to recur.
3. **The Control4 device is the identity.** Unchanged for lights, scenes,
   zone lights and motion devices. An automation has no device, so rules 7
   and 8 take its place for the record.

Seven more for automations:

4. **Read freely; write one field, only on a click.** The audit reads on
   its own (§6.1). A write is one `PUT` of `{"enabled": false}` or
   `{"enabled": true}` on one `behavior_instance`, sent only from **Disable
   Hue Automation** or **Restore Hue Automation**: never queued for later,
   never from an event, a resync, a start or a removal. Never
   `configuration`, `trigger`, `metadata`, `POST` or `DELETE`; and this
   feature writes nothing to sensors, areas, scenes or switches.
5. **Only flags the Hue app shows.** `enabled` is written only on
   automations whose on/off switch the Hue app shows (script category
   `automation` [community: Home Assistant PR #177671]), so anyone in the
   house can undo any change in the Hue app, with or without Control4.
   Switch and sensor settings, internal settings, run-by-hand automations
   (mimic presence) and anything the bridge refused get the Hue app steps
   instead (#280, plan item 2).
6. **Never fight, never guess.** An automation Control4 disabled that is
   enabled again (the Hue app, another app, a bridge restore or update) is
   reported and offered, never disabled again by the driver; nothing is
   ever enabled by the driver either, not even when its conflict ends. Who
   changed something outside Control4 is unknown, and the texts say
   "outside Control4".
7. **The bridge is the truth for on and off; the record is a journal.** The
   record says what Control4 disabled, when, why and how it looked; every
   audit reconciles it with the bridge; it never drives a write without a
   click. Losing it never loses the fact that an automation is off: the
   bridge still says so and the Hue app still undoes it.
8. **The record outlives the driver instance.** It is keyed by bridge id,
   kept in the bridge driver's persistence and copied to the controller
   registry, so a bridge driver deleted and added again finds it (§7).
9. **Conflicts are computed, never stored.** Which automations act on which
   Control4 lights is worked out again from the current Hue resources and
   the current registries at every audit; only the owner's decisions (what
   Control4 disabled, what he kept) are stored.
10. **Say what is not seen.** The row and the manual state the audit's
    coverage (H14).

## 0. Facts the policy rests on

### 0.1 Hue

| Fact | Status |
| --- | --- |
| Hue keeps each automation as a `behavior_instance`: `id`, `script_id`, `enabled`, `configuration` (its shape set by the script), `dependees` (each a `target` `{rid, rtype}` with a `level` of `critical` or `non_critical`), `status` (`initializing`, `running`, `disabled`, `errored`), `last_error`, `metadata.name`, and optionally `state`, `id_v1` and `migrated_from`. | [community: aiohue `v2/models/behavior_instance.py`] |
| A `behavior_script` describes each kind of instance: `metadata.name`, `metadata.category` (`automation`, `accessory`, `entertainment`, `other`), `version`, JSON schemas for the configuration, trigger and state, `max_number_instances`. The schemas make the catalogue large, and it changes only with the bridge's firmware. | fields [community: aiohue `v2/models/behavior_script.py`]; size and stability [assumed] |
| A client may `PUT` `enabled`, `configuration`, `trigger` and `metadata` on an instance and `POST` a new one; `DELETE` exists. | PUT and POST fields [community: aiohue `BehaviorInstancePut`, `BehaviorInstancePost`]; DELETE [assumed: HAR] |
| The instances are not only the Hue app's automations: they also hold the button settings of dimmer switches, wall switch modules and tap dials, and internal entertainment settings. Only the automations show in the Hue app, each with an on/off switch; for the others the bridge refuses `enabled`, or accepts it and the switch keeps working. Home Assistant therefore offers its automation switches for category `automation` only. | [community: Home Assistant PR #177671 (2026-08-01) and `homeassistant/components/hue/switch.py`] |
| Some automations are run with a play and a stop control in the Hue app (mimic presence): they report `state.pm_state` (`started`, `stopped`) and start and stop through `trigger`; their `enabled` is a flag the Hue app does not show. | [community: Home Assistant PR #177691; aiohue `BehaviorInstanceController.start`, `stop`] |
| A switch's instance names, per button, a `where` (a room in the dump; a zone presumably too) and lists that room as a critical dependee beside the switch's own device; an unconfigured switch has empty `where` lists and only its device. A dimmer switch's instance keys its buttons by button rid. An entertainment instance names an `entertainment_configuration`. All four instances of the dump were enabled and `running`, with an empty `last_error`. | [verified: aiohue fixture `tests/fixtures/v2_resources.json`, an anonymised dump] |
| A critical dependee is a target the instance cannot work without: deleting the target deletes the instance. | [community: aiohue `DependencyLevel` docstring] |
| The shapes of wake-up, go-to-sleep, timer, routine, coming-home and leaving-home (geofencing) and motion-sensor automations: which `configuration` fields name their lights, rooms, zones and scenes, and whether `dependees` always lists them; the scripts' names. | [assumed: HAR] |
| A MotionAware area set up to control lights has a light automation, a `behavior_instance` tied to the area's configuration; a `PUT` of `enabled` on it was answered HTTP 400 in reports from 2025-10 to 2026-02. | [community: Home Assistant issues #153935, #160393; HR §2.2, §2.5, §4.1 in `docs/motion-hue-research.md`]; its script category [assumed] |
| Setting up an area asks for a response: control lights (free), alerts (a paid plan), or both; an owner without the plan therefore gets the light automation. | [verified: HR §2.1] |
| An area's light automation may act on a zone other than the area's own group. | [community: Home Assistant issue #181632] |
| Pausing an area (`motion_area_configuration.enabled` false) is accepted by the API and silences the area altogether, including the motion a Control4 motion device reads. | [verified: HR §4.1; EC A6] |
| Whether the event stream carries `add`, `update` and `delete` items for `behavior_instance`, including an `enabled` changed in the Hue app. | [assumed]; one report says an area toggle changed in the Hue app did not reach Home Assistant [community: #153935] |
| Whether an edit in the Hue app keeps the instance's id, and whether saving a disabled automation enables it. | [assumed] |
| Rules, schedules and resource links of the v1 API (made by older Hue app versions and other apps) are not behaviour instances, and CLIP v2 does not show them; `migrated_from` names the v1 resource an instance replaced. | invisibility [assumed]; the field [community: aiohue] |
| Apple Home, Alexa, Google Home and Home Assistant run their automations outside the bridge and send ordinary light commands. | [assumed] |
| Smart scenes (time-based scenes) are `smart_scene` resources, not behaviour instances; Control4 starts and stops them through Hue Scene devices (`activate`, `deactivate`). | [verified: `docs/smart-scenes-design.md`] |
| The Hue app's bridge transfer moves automations to the new bridge, which has a new bridge id; whether resource ids survive is contradictory. | [verified: `docs/edge-cases-hue.md` §4, Philips support]; ids [community, contradictory] |
| No published rate limit for behaviour instance writes is known; the driver sends one request at a time on its command queue. | [assumed; `docs/design.md` "Commands and rate limiting"] |

### 0.2 Control4

| Fact | Status |
| --- | --- |
| `PersistSetValue` values belong to the device id: an update in place, a Director restart and a reboot keep them; deleting the driver and adding it again loses them. | [verified: house; `docs/design.md` "Storage"] |
| Whether a project backup carries `PersistSetValue` values. | [silent: `docs/edge-cases-control4.md` 3.6] |
| `PersistData` is saved in the project file and kept through a project save or backup, an orderly Director restart and a driver update. | [verified: FUND 24/_1] |
| The controller registry (`C4:RegistrySetValue`, `RegistryGetValue`, `RegistryDeleteValue`, OS 2.10.4 and later) is one key-value table per controller holding numbers, strings, booleans or tables. Snap One meant it for global values such as configuration shared by every instance of a driver, and advises against keeping state or transient data there. | [verified: API 26_registry/_1, _3, _4] |
| Whether the controller registry survives deleting a driver (expected: it belongs to no device), is left out of project backups and is not rolled back by a project restore (expected), takes string keys (its pages say "number"), and works on OS 3.4.2. | [assumed: check 6] |
| `OnDriverRemovedFromProject` runs in a driver being deleted, for final commands; `OnDriverDestroyed` follows and the driver's timers end. | [verified: API 22/_26, 22/_24]; that an HTTPS request started there completes [assumed: unlikely] |
| Sandbox files are not in project backups and are lost when the controller is reset or migrated. | [verified: FUND 3_what's_new/_17] |
| `C4:GetDevices({C4iNames = "hue_bridge.c4z"})` lists the project's Hue Bridge drivers. | [verified: API 22/_9; used today for the lights] |
| Bridge rows: `Attention` is one string, items joined with "; ", each naming three things and then "+N more"; list rows are `DYNAMIC_LIST`s with a summary in the row and one line per item in the drop-down, and Composer clips a row at about 75 characters; `Last Action` wraps onto six rows of 72 characters; action pickers are `CUSTOM_SELECT` lists built on demand, which work on OS 3.x. | [code: `owner:attention_items`, `util.some`, `hue_bridge/driver.lua` `show_list`, `last_action`; verified: `docs/import-design.md` §8] |
| The bridge driver keeps its registries with `PersistSetValue` under its own keys; `Forget Pairing` clears the key and keeps the registries; `Pair Bridge` refuses a bridge whose id differs until `Forget Pairing`. | [code: `bridge/credentials.lua`, `Forget_Pairing`, `bridge/pairing.lua` `other_bridge`] |

### 0.3 Terms used below

- **Control4 lights**: the Hue lights a Control4 device of this bridge can
  change: the light of every Hue Light device; every light of a room or
  zone that has a Zone Light device; every light of the room or zone of a
  Hue Scene device. Linked and unbound entries count; gone, forgotten and
  deleted ones do not. Motion devices change no lights. (Q1)
- **An automation's lights**: the lights its actions can change, from its
  `dependees` and its `configuration` (`where` and the targets of each
  action): a light; a device's lights; a room's devices' lights; a zone's
  lights; a grouped light's room or zone; a scene's or a smart scene's room
  or zone; the whole home (`bridge_home`), which is every light. A device
  that only triggers it (a switch, a sensor, an area, a phone's geofence) is
  its **trigger**: shown, never counted. When neither field names a light,
  the automation's lights are **unknown**, never "none".
- **Conflict**: an automation that is enabled in Hue, whose lights include a
  Control4 light, and that the owner has not kept.
- **Class**, from the instance's script category (rule 5): **automation**
  (`automation`: Disable is offered); **switch or sensor setting**
  (`accessory`: listed, never written); **run by hand** (reports
  `state.pm_state`: listed, never written); **not audited**
  (`entertainment`, `other`, or a script not read yet: counted only). An
  instance that reports `state.pm_state` is run by hand whatever its
  category. An automation whose `enabled` the bridge refused is **Hue app
  only** until the bridge's firmware changes.
- **The record** (§7): what Control4 disabled, one entry per instance with
  its state (pending, disabled, restoring, enabled again, deleted in Hue),
  and what the owner kept, per bridge id.
- **Example names** in the texts: "Wake up Bedroom" (a wake-up on the Hue
  room Bedroom, whose three lights are Control4 lights); "Hall timer" (a
  timer on Hall Lamp); "Kitchen routine"; "Porch evening" (a routine on Hall
  Lamp, a Control4 light, and on Porch Light and Garage, which are not);
  "Garage timer" (lights outside Control4); "Bedroom dimmer" (a Hue dimmer
  switch); "Hallway sensor" (a Hue motion sensor and its behaviour);
  "Kitchen motion area" (a MotionAware area, as on the house since
  2026-10-26); "Desk Lamp"; "Hall" (a Control4 room).

## 1. Automations: the Hue side

Each row: what the bridge shows and the driver sees; what the driver does
on its own; what it offers as a click; what it never does without one; the
text the owner reads; the precedent, or "new".

| # | Case | Observable | Automatic | Offered (a click) | Forbidden without a click | Owner sees | Precedent |
| --- | --- | --- | --- | --- | --- | --- | --- |
| H1 | Created in the Hue app or another app, acting on Control4 lights | An `add` item [assumed]; the next `/behavior_instance` GET lists it; its script gives the class. | Classified, its lights worked out, listed, counted, logged once; in Attention while it is a conflict. | **Disable Hue Automation**; **Keep Hue Automation**. | Disabling it on its own: someone in the house just made it, and a silent disable is the surprise rule 6 forbids. | Attention "1 Hue automation acts on Control4 lights: Wake up Bedroom (Disable Hue Automation or Keep Hue Automation)"; row "On Control4 lights: Wake up Bedroom (wake-up) → Bedroom Lamp +2". | Lights: a new light is listed, never added (import-design §1). |
| H2 | Created, acting only on lights Control4 does not control (a timer or a switch in a room Control4 leaves to Hue) | As H1. | Listed as elsewhere; no Attention; nothing to keep. | — | Counting it as a conflict. | Row "Elsewhere: Garage timer (timer) → Garage". | New. |
| H3 | Edited in the Hue app while enabled (times, scenes, lights) | An `update` item [assumed] or the next GET; the id kept [assumed]. | Its lights worked out again; a kept automation is listed again only when it now acts on a Control4 light it did not act on when kept (H8). | As H1 while it is a conflict. | — | Row refreshed. | Lights: a Hue-side change refreshes the labels. |
| H4 | Edited in the Hue app while Control4 has it disabled | An update or a GET shows `configuration` or `metadata` that differ from the record's signature; `enabled` still false (when the edit enabled it: H6). | Entry kept and marked "changed in Hue since"; nothing written. | **Restore Hue Automation** enables it as it is now and says what changed (R8). | Writing the old configuration back; disabling the new version again. | Row "Disabled by Control4 10-26 (changed in Hue since): Hall timer → Hall Lamp". | New. |
| H5 | Renamed | `metadata.name` in an update or a GET. | Row, pickers and record show the new name; the entry keeps the name it had when disabled, for the texts. | — | Renaming it in Hue. | Row and pickers; Last Action of a Restore "Hall timer (was Hallway timer)". | Lights: Hue names shown, Composer untouched. |
| H6 | Enabled again outside Control4 (the Hue app, another app, an edit saved in the app, a bridge restore or update) while Control4 has it disabled | `enabled` true in an update or a GET. | The entry becomes "enabled again" with the time seen; the automation is a conflict again; Attention. If it is later disabled again outside Control4, the entry is dropped: someone else disabled it (H7). | **Disable Hue Automation** (a new entry); **Keep Hue Automation** (drops the entry). | Disabling it again on its own: the driver never fights the household (rule 6). | Attention "1 Hue automation Control4 disabled is enabled again: Kitchen routine (enabled outside Control4 on 10-27; Disable Hue Automation or Keep Hue Automation)"; row "Enabled again outside Control4: Kitchen routine → Kitchen Pendant +3". | New. |
| H7 | Disabled in the Hue app by someone else (no entry) | `enabled` false and no entry. | Listed as disabled in Hue; not a conflict; no Attention; no entry made. | — (Restore lists only what Control4 disabled: Q4). | Enabling it; adopting it into the record. | Row "Disabled in Hue (not by Control4): Vacation lights → Living Room Lamp". | New. |
| H8 | Its lights grow to more Control4 lights (its targets edited in Hue; a light added in Hue to a room or zone it targets) | Its lights worked out again. | Not kept: as H1. Kept: listed again, naming only the new Control4 lights; the keep stays for the old ones. | **Keep Hue Automation** again (covers the new set); **Disable Hue Automation**. | — | Attention item of H1 with "Bedroom dimmer (kept; now also Desk Lamp)". | Lights: a dismissed name difference returns when the Hue name changes again (import-design Q10). |
| H9 | Its lights change so that it no longer acts on any Control4 light | As H8. | Not disabled by Control4: it moves to elsewhere and its Attention item clears. Disabled by Control4: the entry stays and Attention offers the Restore. | **Restore Hue Automation**. | Enabling it on its own (rule 6): the owner may be about to re-link or add a light. | Attention "1 Hue automation Control4 disabled no longer acts on Control4 lights: Hall timer (Restore Hue Automation)". | New. |
| H10 | Deleted in the Hue app or another app, or by the bridge because a critical dependee went (its light, room, scene or switch) | A `delete` item with id and type only [assumed]; a successful GET without it; never a failed GET. | Conflict and keep dropped; an entry becomes "deleted in Hue on <date>" and stays for the owner's information (Q10); logged. | **Restore Hue Automation** on such an entry only clears it ("nothing to restore"). | Creating it again (no `POST`, ever); marking it deleted on a failed GET. | Row "Deleted in Hue 10-28 (was disabled by Control4): Hall timer"; no Attention. | Lights: only a successful full GET marks a light gone (import-design §5). |
| H11 | Re-created: deleted and made again (by hand, by an app edit that makes a new instance, by a switch set up again) | H10 for the old id, H1 for the new one, which has a new id [assumed]. | The new one listed with a hint when an entry or a keep has the same name and the same script: "looks like Hall timer, which Control4 disabled on 10-26"; hinted ones first in the pickers. | **Disable Hue Automation** or **Keep Hue Automation** on the hinted one. | Carrying a disable or a keep over on a name match. | Attention item of H1 with the hint. | Lights: a replaced bulb's re-link hint, never automatic (import-design §5). |
| H12 | Partial overlap: it acts on Control4 lights and on lights Control4 does not control | Its lights worked out. | A conflict, listed with both sets. | **Disable Hue Automation**, whose picker line and Last Action say what else stops; **Keep Hue Automation**. | Removing the Control4 lights from its targets (a configuration write, §8); disabling it without saying what else stops. | Picker "Porch evening (routine) → Hall Lamp; also 2 lights outside Control4"; Last Action on Disable "Disabled in Hue: Porch evening. It also controlled Porch Light and Garage, which Control4 does not control: they no longer follow it either. To keep it for them, restore it and remove Hall Lamp from it in the Hue app." | New. |
| H13 | Several apps on the bridge (phones with the Hue app, Home Assistant, which offers a switch per automation, other Hue apps) | The same flags change; who changed them is never visible. | H6, H7 and H10 apply whoever acted. | — | Guessing who acted; fighting any of them. | Texts say "outside Control4". | New. |
| H14 | Automations the audit cannot see: v1 rules and schedules (older Hue app versions, other Hue apps), Apple Home, Alexa, Google Home and Home Assistant automations | Nothing; only their light commands arrive, as light updates. | The row's last line and the manual state the coverage. | — (a v1 read is Q7). | Claiming "no conflicts" without the coverage line. | Row "Not visible here: other apps' own rules; Apple Home / Alexa / Google routines". | New. |
| H15 | A bridge firmware or Hue app update migrates automations (v1 rules into instances with `migrated_from`), changes a script's version or shape, or resets `enabled` | New ids, changed `configuration` shapes, `enabled` changes. | New instances listed as H1, noting "(moved from an older Hue rule)" when `migrated_from` is set; the script catalogue read again (§6.1); an `enabled` reset on a recorded automation is H6; a configuration the driver cannot read gives unknown lights (R3). | As H1. | Reading an unknown shape as "acts on nothing". | Row note. | New. |
| H16 | An automation in error or starting (`status` `errored` with `last_error`, or `initializing`) | `status`, `last_error`. | Listed with its status; while enabled it still counts as a conflict, since it may recover. | As H1. | — | Row "On Control4 lights: Wake up Bedroom (wake-up; in error in Hue) → Bedroom Lamp +2". | New. |
| H17 | A smart scene (time-based scene) started from Control4 | A Hue Scene device's ON sends `activate` [code: `bridge/scenes.lua`]; the smart scene turns active. | Not audited: a smart scene is a scene Control4 started, and its slots changing the lights is what the owner chose. | — (the scene device's OFF stops it). | Listing it as a conflict; deactivating it from the audit. | Nothing new; the scene device's Status. | Smart scenes (`docs/smart-scenes-design.md`). |
| H18 | A smart scene started by a Hue automation (a routine, a wake-up with a time-based scene) or by hand in the Hue app | The automation's actions name the smart scene; or the smart scene turns active with no Control4 command. | The automation is audited by the smart scene's room or zone (H1). A smart scene started by hand is a scene, not an automation: its Hue Scene device, if imported, shows it running. | As H1 for the automation. | Deactivating a running smart scene from the audit. | As H1. | Smart scenes (Decision 10, `other_active`). |
| H19 | An automation the owner wants to keep although it acts on Control4 lights (a wake-up he prefers to Control4's, a Hue switch by the bed) | — | — | **Keep Hue Automation** (R10). | — | Row "Kept: Bedroom dimmer → Bedroom Lamp +1". | Accept Names As They Are. |

## 2. Switches, sensors, MotionAware and other behaviours

| # | Case | Observable | Automatic | Offered (a click) | Forbidden without a click | Owner sees | Precedent |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | A MotionAware area set up in the Hue app to control lights (the house's case since 2026-10-26): without the paid alerts plan the setup always gives the area a light automation | An instance tied to the area's configuration [community: HR §2.2], acting on the area's lights or on a zone chosen for it [community: #181632]; its category [assumed]. | Listed by its lights; a conflict when they are Control4 lights; marked "(MotionAware)"; the row names the area and, when one is imported, its motion device. | **Disable Hue Automation** sends one `PUT`. When the bridge refuses (HTTP 400, as reported), the pending entry is dropped, the automation is marked Hue app only for this bridge firmware, and Last Action gives the Hue app steps, written from the house's area (check 3). **Keep Hue Automation.** | Pausing the area to silence it (that also stops the motion a Control4 motion device reads: EC A6); writing its configuration (time slots, lights); deleting the area or the automation; repeating a refused `PUT` on its own. | Last Action "Not disabled: Kitchen motion area lights. The Hue bridge does not let other apps switch this automation off. In the Hue app, open MotionAware, then Kitchen motion area, and set every time slot to do nothing; or point it at a zone without Control4 lights; or use Keep Hue Automation." [steps assumed] | Motion: EC R9 "both run, the manual says so"; now audited and offered. |
| S2 | An area saved again in the Hue app (Signify's advice for "unrecoverable") or re-created | Its light automation may come back with a new id [assumed]. | H11. | H11. | H11. | H11. | Motion A13. |
| S3 | A Hue switch's button settings act on Control4 lights (dimmer switch, tap dial, smart button, wall switch module) | An `accessory` instance whose buttons name a room or zone in `where` [verified: aiohue fixture]. | Listed as a Hue switch; counted; in Attention once until kept (Q3); its line in Disable's picker says Hue app only. | **Keep Hue Automation** (one, or "every Hue switch listed"). Picking it in Disable writes nothing and puts the Hue app steps in Last Action. | Writing its `enabled` (refused, or the switch keeps working: rule 5); writing its button settings. | Attention "2 Hue switches control Control4 lights: Bedroom dimmer, Hall tap dial (they act on a button press; Keep Hue Automation, or set their buttons in the Hue app)". | New. |
| S4 | A Hue switch in a room Control4 does not control | As S3, its lights elsewhere. | Elsewhere (H2). | — | — | Row "Elsewhere: Garage dimmer (Hue switch) → Garage". | New. |
| S5 | A switch or sensor paired again (reset, replaced) | A new device with new rids [assumed: EC S6]; its old instance deleted with its critical device dependee [community: aiohue]; a new instance once it is set up again in the app. | H10 for the old instance, H11 for the new one; the hint covers keeps: "looks like Bedroom dimmer, which you kept". | As H11. | Carrying a keep over on a name match. | As H11. | Motion S4 to S6. |
| S6 | A Hue motion sensor's behaviour acts on Control4 lights; the sensor may also be a Control4 motion device | An instance with the sensor as trigger and lights as targets; its category [assumed: HAR]. | Listed by its lights; "(trigger: Hallway sensor, also in Control4)" when a motion device stands for the sensor. Category `automation`: as H1. `accessory`: as S3. | As H1 or S3. | Switching the sensor off in Hue to silence it: that stops the motion Control4 reads (EC S7). | Last Action for an `accessory` one: "Not disabled: Hallway sensor's behaviour is a sensor setting. In the Hue app, open the sensor and set its time slots to do nothing; leave the sensor itself on, since Control4 reads its motion." [steps assumed] | Motion R9. |
| S7 | A sensor or a switch whose settings still live in v1 rules | Nothing (H14). | The coverage line. | — | — | As H14. | New. |
| S8 | A run-by-hand automation (mimic presence) | `state.pm_state` `started` or `stopped` [community: #177691]. | Listed as run by hand, "(running)" while started; not a conflict; no Attention. | — | Writing its `enabled`: the Hue app does not show it, so nobody could undo it there (rule 5); starting or stopping it. | Row "Run by hand: Away lights (running) → Living Room Lamp +4". | New. |
| S9 | Entertainment and internal settings, and instances of a script not read yet | Category `entertainment` or `other`, or an unknown `script_id`. | Counted on one row line; never written; an unknown script triggers one catalogue read (R2). | — | Writing anything. | Row "Not audited: 6 entertainment or internal settings". | New. |
| S10 | Security responses (Hue Secure alarms that flash lights, MotionAware alerts), if the bridge keeps them as instances [assumed: HAR] | Recognised by script name or by a security source [assumed]. | Listed by their lights, marked "(security)". | **Keep Hue Automation**; Disable not offered (Q5): its picker line reads "(security: Hue app only)". | Disabling an alarm's response from a lighting driver. | Picker and row "(security)". | New. |

## 3. The bridge

| # | Case | Observable | Automatic | Offered (a click) | Forbidden without a click | Owner sees | Precedent |
| --- | --- | --- | --- | --- | --- | --- | --- |
| B1 | Bridge restored from a Hue backup (a Bridge Pro feature [assumed]) | Automations as the backup had them: enabled again, deleted, or with new ids [assumed]. | Entries reconcile: enabled → H6; missing after a successful GET → H10; new ids → H1 with H11's hints. | As H6 and H11. | Disabling again on its own. | Attention "3 Hue automations Control4 disabled are enabled again: …". | Motion B2. |
| B2 | Bridge replaced through the Hue app's transfer | A new bridge id: `Pair Bridge` refuses it until `Forget Pairing` [code]; the automations moved, ids perhaps kept [community: contradictory]; whether `enabled` travels [assumed]. | The old bridge's record stays under its bridge id, shown and never acted on. After the new bridge is paired, an entry whose instance id exists on it is re-attached (the same id is the evidence; logged; nothing written); the rest stay on the old bridge's line. | **Restore Hue Automation** on re-attached entries; Disable on new conflicts. | Re-attaching entries by name; writing anything because of the old bridge's record. | Row "Old bridge …3abc: 2 automations Control4 disabled (not on this bridge)"; log "re-attached the record of Hall timer from the bridge this one replaced". | Lights: auto-adopt by rid (import-design Q3); the bridge identity check (#236). |
| B3 | Bridge factory reset | Every keyed request refused with 403 until `Pair Bridge` [verified: house, #44]; afterwards its automations are gone. | While refused: no audit, no writes. After pairing: every entry becomes "deleted in Hue" at the first successful GET; new automations as H1. | `Pair Bridge`. | — | The bridge's Status; then the row. | Lights (a rejected key). |
| B4 | Bridge offline, rebooting or updating its firmware | GETs fail; the stream drops [code: `bridge/stream.lua`]. | R1: the row shows the last audit "as of"; clicks refused; nothing marked deleted. After an update: the script catalogue read again (H15) and the Hue app only marks cleared (B5). | — | Queuing a click to run later. | Row "Hue automations (as of 14:02; bridge not answering)". | Motion B4. |
| B5 | A firmware update changes what the bridge accepts (an area's automation starts accepting `enabled`, or another starts refusing it) | The bridge's software version [code: `Bridge Firmware`]. | Hue app only marks belong to a firmware version: a new version clears them, so the next Disable click tries again. | Disable. | Trying on its own after the update. | — | New. |
| B6 | Bridge address changed | Identity check and rediscovery [code: `verify_identity`]. | As B4 until the bridge answers again. | — | — | As B4. | Lights. |
| B7 | A square Hue Bridge (v2) | No MotionAware [verified: HR §2.7]; behaviour instances on both generations [assumed]. | Everything but S1 and S2. | — | — | — | Motion B5. |
| B8 | Application key rejected | 403 [verified: #44]. | As B3 while refused. | `Pair Bridge`. | — | As B3. | Lights. |

## 4. The Control4 side

| # | Case | Observable | Automatic | Offered (a click) | Forbidden without a click | Owner sees | Precedent |
| --- | --- | --- | --- | --- | --- | --- | --- |
| C1 | A light imported after the audit (Add Light, Import All New Lights), or a Zone Light or a Hue Scene device added | The registries change [code]. | The conflicts worked out again: automations now acting on a Control4 light become conflicts (Attention); a kept automation now acting on it is listed again (H8). | As H1. | Disabling anything because of the import. | Attention "1 Hue automation acts on Control4 lights: Garage timer (Disable Hue Automation or Keep Hue Automation)". | Lights: Attention refreshes after every click. |
| C2 | A light leaves Control4 (Forget Light; deleted in Composer, a tombstone; gone in Hue), or a Zone Light or a Hue Scene device forgotten or deleted | As C1. | Conflicts that no longer act on Control4 lights leave the list; an entry whose automation no longer does is offered for Restore (H9). | **Restore Hue Automation**. | Enabling anything on its own: the owner may be about to re-link or add the light again. | As H9. | Lights (tombstones). |
| C3 | A device re-linked to another Hue light, or adopted by Link Devices or by its hello | The registry's rid changes [code: `owner:relink`, `adopt`]. | The conflicts worked out again; the texts name the devices as they are now (the entry keeps the names it had for the log). | — | — | — | Lights. |
| C4 | A motion device added or removed | The motion registry [motion branch]. | Conflicts unchanged (motion devices change no lights); the row's "(trigger … also in Control4)" follows. | — | — | Row. | Motion. |
| C5 | Project restored from a backup | The registries come back as the backup had them, and perhaps the bridge driver's own copy of the record [silent]; the controller registry's copy is not rolled back [assumed]. | At load the newer copy of the record wins whole (§7.4); the conflicts are worked out from the restored registries; the first audit reconciles the record with the bridge: an entry whose automation is enabled now is H6, a deleted one H10. | As H6 and H9. | Applying a disable from an older record. | Possibly H6's Attention for an entry older than a Restore the backup did not know about; the text blames nobody. | Lights (the project reconcile). |
| C6 | Bridge driver updated in place | Its persistence kept [verified: house]. | Nothing. The first build with the feature finds no record: every automation disabled before it is "Disabled in Hue (not by Control4)"; its first audit lists everything at once, three names per Attention item and "+N more", and the bulk entries of §6.2 handle them in two clicks. | — | — | — | Lights. |
| C7 | Bridge paired again with the same bridge | A new key, the same bridge id [code]. | Nothing; the record goes on. | — | — | — | Motion B6. |
| C8 | `Forget Pairing` while Control4 has automations disabled | [code: `Forget_Pairing`]. | Record kept (keyed by bridge id); Disable and Restore refused until paired; Forget Pairing's Last Action names them. | `Pair Bridge`. | Dropping the record. | Last Action "Forgot the pairing. Control4 still has 2 Hue automations disabled on this bridge: Wake up Bedroom, Hall timer. Pair it again to restore them, or enable them in the Hue app." | New. |
| C9 | Bridge driver deleted while automations stay disabled | The bridge's `OnDriverRemovedFromProject` [verified: API 22/_26]; its own persistence goes [verified: house]. | One `log.always` line naming them; the controller registry's copy is kept. | — (the manual: before deleting the bridge driver for good, use Restore Hue Automation with "everything Control4 disabled"). | Enabling them from `OnDriverRemovedFromProject`: an unconfirmed write nobody clicked, during what may be the first half of a delete and re-add; deleting the registry copy. | Lua output "Hue Bridge removed while Control4 had 2 Hue automations disabled on bridge …3abc: Wake up Bedroom, Hall timer. They stay disabled: enable them in the Hue app, or add the Hue Bridge driver again, pair it and use Restore Hue Automation." | Lights: devices keep their rids for a re-added bridge (`docs/edge-cases-control4.md` 1.7, 1.8). |
| C10 | Bridge driver added again and paired with the same bridge | Empty persistence; the registry holds a copy for this bridge id. | Adopted when the driver's own copy is empty and the copy's writer is no longer in the project (`GetDevices` lists no other Hue Bridge driver); logged; the audit follows. | **Restore Hue Automation** as usual. | Adopting a copy whose writer is another Hue Bridge driver still in the project (C13). | Last Action after pairing "Found the record of 2 Hue automations an earlier Hue Bridge driver disabled on this bridge: Wake up Bedroom, Hall timer (Restore Hue Automation)". | Lights: auto-adopt (import-design Q3). |
| C11 | The drivers uninstalled for good | The bridge driver deleted (C9) and not added again. | Nobody enables the automations automatically. They stay disabled on the bridge, where the Hue app shows each one off and can enable it; C9's log line lists them. The record stays in the controller registry (a few kilobytes) and is adopted if a Hue Bridge driver for that bridge returns (C10). When nothing is disabled or kept, the driver deletes the registry copy itself, so an uninstall after a full Restore leaves nothing behind. | Before: **Restore Hue Automation** with "everything Control4 disabled", the first step of the manual's uninstall section; Last Action confirms "Nothing disabled by Control4 remains on this bridge". | Restoring at removal (C9); deleting the registry copy at removal. | The manual's section "Removing the Hue drivers". | New. |
| C12 | Controller replaced or reset to defaults (the project moved) | The registry copy stays behind or is lost [assumed]; the bridge driver's copy travels if the project carries `PersistSetValue` values [silent]; the key may not travel [assumed: `docs/edge-cases-control4.md` 3.7]. | After pairing: the record reconciles, or, when it is lost, every automation Control4 disabled shows as "Disabled in Hue (not by Control4)" (H7), still visible and undoable in the Hue app (rule 7). | `Pair Bridge`. | — | As H7. | Motion C20. |
| C13 | Two Hue Bridge drivers paired with the same bridge (a mistake; several bridges are later) | The second finds a registry copy whose writer is a device still in the project. | It does not adopt the record and refuses Disable and Restore; Attention names the other driver. | — | Two drivers writing one record or the same automations. | Attention "Another Hue Bridge driver (device 1001) is paired with this bridge; Hue automations are disabled and restored from that one only". | Lights (two devices claiming one rid). |
| C14 | Director restarted, controller rebooted | Load at init; the audit after the first resync [code: the resync chain]. | Record loaded; pending entries resolved at the first audit (R6); no write at start. | — | Any write at start. | — | Lights. |
| C15 | OS 3.x upgraded to 4.x | The registry API is 2.10.4 and later [verified]. | Nothing. | — | — | — | Motion C14. |

## 5. Runtime

| # | Case | Observable | Automatic | Offered (a click) | Forbidden without a click | Owner sees | Precedent |
| --- | --- | --- | --- | --- | --- | --- | --- |
| R1 | The audit while the stream is down or the bridge is away | GETs fail; or they succeed while no event arrives. | The last results kept and shown "as of"; a GET that works still refreshes (the audit does not need the stream), and the resync at reconnect refreshes; a failed GET marks nothing deleted, enabled again or no longer conflicting. Clicks make their own fresh GET (R4) and are refused when it fails. | **Audit Hue Automations** (reads now). | Queuing a click for later; reading "not seen" as deleted. | Row summary "… (as of 14:02; bridge not answering)"; Last Action "Not disabled: the Hue bridge is not answering; nothing was changed." | Lights: a failed GET marks nothing gone. |
| R2 | A partial read: the instances read but not the script catalogue; or the lights' caches stale | One GET failed. | The last catalogue kept (its small part persisted: id, name, category, version); an instance of an unknown script is not classified until the catalogue is read; conflicts from stale caches marked "as of". | — | Offering Disable on an unclassified instance. | Row "Not audited: 1 automation of a script not read yet". | New. |
| R3 | An automation whose lights cannot be worked out | An unknown configuration shape and no dependee with lights. | Listed as "can't tell which lights"; not a conflict; no Attention. | **Disable Hue Automation** lists it, marked so, when its class is automation (the owner may know what it does). | Guessing its lights from its name. | Row "Can't tell which lights: Evening routine". | New. |
| R4 | A Disable click, the normal path | — | Busy check; one fresh GET of the instance (of the list, for "every …"); checks: it exists, is enabled, is of class automation, is not marked Hue app only, still acts on Control4 lights (or has unknown lights and was chosen); the entry written **before** the `PUT` as "pending", with the pre-image (name, script, a signature of `configuration` and `metadata`, the Control4 lights); `PUT {"enabled": false}`; on success the entry becomes "disabled", confirmed by a GET. The stream's echo is matched to the entry, never read as H7. A run in progress (a wake-up fading in) may finish [assumed]. | — | Disabling an automation the fresh GET shows deleted, already disabled or no longer acting on Control4 lights: refused, with the reason. | Last Action "Disabled in Hue: Wake up Bedroom. It stays on the bridge and shows as off in the Hue app; Restore Hue Automation enables it again." | New. |
| R5 | A disable that half succeeds: in "every …", some `PUT`s refused (400), failed, or accepted without effect | One answer and one GET per instance. | Each instance is its own step: successes recorded, failures leave no entry; a 2xx whose GET still shows `enabled` true counts as refused ("accepted but not applied"); refused ones marked Hue app only; the successes are not rolled back; Last Action lists both. | The failures stay in the picker; refused ones as Hue app only. | Rolling back the successes; retrying the failures on its own. | Last Action "Disabled 3 of 4 Hue automations: Wake up Bedroom, Hall timer, Kitchen routine. Not disabled: Kitchen motion area lights (the bridge refuses; in the Hue app, …)." | New. |
| R6 | A `PUT` whose outcome is unknown (a timeout; the connection lost after sending; Director restarted in between) | No answer. | The pending entry stays (it was persisted first); one GET resolves it as soon as the bridge answers: `enabled` false → "disabled", true → entry dropped (a pending Restore the other way round). Attention only while it stays unresolved for more than 10 minutes. | **Audit Hue Automations**. | Sending the `PUT` again on its own. | Last Action "Not confirmed: Wake up Bedroom: the bridge did not answer in time; Control4 checks again when it answers"; Attention "1 Hue automation change not confirmed: Wake up Bedroom (Audit Hue Automations)". | New. |
| R7 | A Restore click | — | Busy check; fresh GET. Deleted → entry cleared, "nothing to restore". Already enabled → entry cleared, "already enabled outside Control4". Disabled → entry "restoring", `PUT {"enabled": true}`, confirmed by a GET, entry cleared; when it still acts on Control4 lights it is kept with its current lights (Q2), so Attention does not list it right after the owner's own click. | — | Writing anything but `enabled`. | Last Action "Enabled again in Hue: Wake up Bedroom (disabled by Control4 since 10-26). It acts on Bedroom Lamp and 2 more Control4 lights and is now kept (Stop Keeping Hue Automation lists it as a conflict again)." | New. |
| R8 | A Restore after the automation was edited in the Hue app | The fresh GET's signature differs from the entry's. | Enabled as it is now; Last Action says what changed when it can tell (name, lights), "settings" otherwise. | — | Writing the old configuration back. | Last Action "Enabled again in Hue: Hall timer. It was changed in Hue while it was disabled (its lights are now Hall Lamp and Desk Lamp); it runs as it is now." | New. |
| R9 | "Everything Control4 disabled" restored with mixed outcomes | One answer per entry. | As R5: an outcome per entry, no rollback. | — | — | Last Action "Enabled again 2 of 3 Hue automations: Wake up Bedroom, Hall timer. Nothing to restore for Old routine (deleted in Hue on 10-28)." | New. |
| R10 | Keep: what it records and how long it lasts | — | The instance id, its name and the Control4 lights it acted on when kept. It lasts until **Stop Keeping Hue Automation**, until the automation is deleted in Hue, or, for the new lights only, until it acts on Control4 lights it did not act on when kept (H8). It never expires by time, and it survives restarts, updates, project restores and a bridge driver delete as the record does (§7). Hue never sees it. | **Keep Hue Automation**; **Stop Keeping Hue Automation**. | Expiring keeps by time; carrying a keep to a re-created automation (H11). | Last Action "Kept Bedroom dimmer: Attention no longer lists it unless it starts acting on other Control4 lights (Stop Keeping Hue Automation undoes this)." | Accept Names As They Are (import-design Q10). |
| R11 | The household enables an automation seconds after Control4 disabled it (a race) | The bridge's last write wins. | H6. | H6. | H6. | H6. | New. |
| R12 | Two clicks at once, or a click during a resync or an import | The busy flags [code: `BUSY_FLAGS`]. | Refused with "Busy: changing Hue automations; try again in a moment"; a resync waits for the click's job, as today. | — | — | Last Action. | Lights (busy). |
| R13 | The pace of a bulk click | — | One request at a time on the command queue, each followed by its GET; 20 automations take some seconds; Last Action written at the end, progress in the log. | — | Parallel `PUT`s. | — | Lights (the command queue). |
| R14 | Clocks | — | Dates in the texts are the controller's time when Control4 acted or saw a change; no bridge time is needed. | — | — | — | New. |
| R15 | Notifications | — | §6: Attention for what the owner must decide, the row for everything, Last Action for each click. | — | Any channel outside Composer (push, mail). | §6. | Lights. |

## 6. The owner-facing surface

### 6.1 When the audit runs

- After every resync, as the last step of the chain (lights → scenes → zone
  lights → motion → automations), because it needs every other cache: one
  GET of `/behavior_instance`, and of `/behavior_script` once per start and
  whenever an unknown script id or a new bridge firmware appears.
- On every `behavior_instance` stream item [assumed that they arrive],
  applied to the cache in order, as the other modules do.
- After every change to Control4's registries (add, import, re-link,
  forget, Link Devices, a goodbye, the project reconcile): worked out again
  from the caches, without a GET.
- On **Audit Hue Automations**, and before every Disable or Restore (one
  fresh GET).
- Never on a timer: no polling.

### 6.2 Actions (bridge, after the scenes' and motion actions)

| Action | Params | Does |
| --- | --- | --- |
| **Audit Hue Automations** | — | Reads now, works the conflicts out again, refreshes the row and Attention. Read-only. Last Action "Hue automations: 14 read; 3 act on Control4 lights; 2 disabled by Control4; 1 kept; 8 elsewhere." |
| **Disable Hue Automation** | `Automation`: first "(every automation listed that Control4 can disable: 3)" (Q9); then the conflicts of class automation, hinted ones first (H11); kept ones "(kept)"; unknown-lights ones "(can't tell which lights)"; last the Hue app only ones, switches and security responses, marked so (choosing one writes nothing and puts the steps in Last Action) | R4, R5 |
| **Restore Hue Automation** | `Automation`: first "(everything Control4 disabled: 2)"; then the entries: "Wake up Bedroom (disabled 10-26)", "Hall timer (disabled 10-26; changed in Hue since)", "Kitchen routine (enabled again outside Control4: clears the entry)", "Old routine (deleted in Hue: clears the entry)"; "(not paired)" while unpaired | R7 to R9 |
| **Keep Hue Automation** | `Automation`: first "(every Hue switch listed: 2)"; then every conflict not kept (automations, switches, Hue app only ones, security responses) | R10 |
| **Stop Keeping Hue Automation** | `Automation`: the kept ones | Drops the keep; a conflict again if it still acts on Control4 lights |

All five are refused while a click or a resync runs (R12), and Disable and
Restore while the bridge is unpaired or not answering (C8, R1). An empty
picker holds one explanatory entry that the action rejects into Last
Action, as today.

### 6.3 The row `Hue Automations`

A `DYNAMIC_LIST` after `Motion Sensors` (after `Zone Lights` until the
motion feature merges). The summary stays under 75 characters: "3 on
Control4 lights; 2 disabled by Control4; 1 kept; 8 elsewhere", with "(as
of 14:02)" while the last read failed, "None on this bridge", "Not read
yet" or "Not paired". The drop-down holds one line per instance, "<state>:
<name> (<kind>) → <lights>", Control4 lights by their Composer names and
others by their Hue names, three and then "+N", in this order:

1. On Control4 lights (conflicts, with hints and "(kept; now also …)");
2. Hue switch on Control4 lights;
3. Enabled again outside Control4;
4. Not confirmed;
5. Disabled by Control4 <date> (with "changed in Hue since" or "no longer
   on Control4 lights");
6. Kept;
7. Hue app only (refused; MotionAware; security);
8. Can't tell which lights;
9. Run by hand (with "running");
10. Disabled in Hue (not by Control4);
11. Elsewhere;
12. Deleted in Hue (was disabled by Control4);
13. Old bridge …3abc: N automations Control4 disabled (B2);
14. Not audited: N entertainment or internal settings;
15. "Not visible here: other apps' own rules; Apple Home / Alexa / Google
    routines" (always the last line).

The kind is a word from the script's name when the driver recognises it
("wake-up", "go to sleep", "timer", "routine", "coming home", "leaving
home", "motion sensor", "MotionAware", "Hue switch") [assumed: the names are
HAR's], else the script's own name, else "automation".

### 6.4 Attention

After today's items, in this order, each naming three and then "+N more";
singular and plural as today:

1. "N Hue automations act on Control4 lights: … (Disable Hue Automation or
   Keep Hue Automation)": automations, sensor behaviours and MotionAware,
   with "(Hue app only)", "(kept; now also …)" and the hints where they
   apply.
2. "N Hue switches control Control4 lights: … (they act on a button press;
   Keep Hue Automation, or set their buttons in the Hue app)" (Q3).
3. "N Hue automations Control4 disabled are enabled again: … (enabled
   outside Control4; Disable Hue Automation or Keep Hue Automation)".
4. "N Hue automations Control4 disabled no longer act on Control4 lights: …
   (Restore Hue Automation)".
5. "N Hue automation changes not confirmed: … (Audit Hue Automations)",
   after 10 minutes.
6. "Another Hue Bridge driver (device 1001) is paired with this bridge; Hue
   automations are disabled and restored from that one only" (C13).

Never in Attention: elsewhere, disabled by someone else, deleted entries,
run by hand, not audited, unknown lights, and a stale audit (the bridge's
Status already says the bridge is away).

### 6.5 Last Action

The texts are in the rows (R4 to R10, H12, S1, S3, S6, C8, C10, C11). Each
names the automation, what was written or why nothing was, and the next
step; a long one continues on `Last Action (2)` to `(6)` as today.

### 6.6 The "keep this one" mechanism

**Keep Hue Automation** is the owner's "I know, leave it": per automation,
per bridge, read-side only (Hue never sees it), lasting until he takes it
back, the automation is deleted, or it reaches Control4 lights it did not
reach when kept, and then only for those (R10). Its bulk entry, "(every Hue
switch listed)", answers S3 for a house full of switches in one click. A
Restore keeps the restored automation the same way (R7, Q2). A keep is
never carried to a re-created automation on a name match; the hint offers
it (H11, S5).

### 6.7 The manual (the bridge's Documentation tab)

- What the audit sees and what it cannot see (H14).
- Disable is the Hue app's own on/off switch: anyone can switch the
  automation on again in the Hue app, and Control4 then asks instead of
  fighting (H6).
- A Hue switch keeps working, and Control4 sees what it does through the
  event stream; Keep it, or set its buttons in the Hue app (S3).
- The MotionAware steps, written from the house's area (S1, check 3).
- "Removing the Hue drivers": Restore Hue Automation with "everything
  Control4 disabled" first (C11).

## 7. The record

### 7.1 Contents

```lua
hue_automations = {
	version = 1,
	bridge_id = "001788fffe123abc",
	writer = 1001,              -- the bridge driver's device id (C10, C13)
	saved_at = 1793000000,      -- os.time() of the last change; the newer copy wins (§7.4)
	disabled = {                -- what Control4 disabled, keyed by instance rid
		["<instance rid>"] = {
			state = "disabled", -- "pending", "disabled", "restoring", "enabled_again", "deleted"
			name = "Wake up Bedroom", script_name = "<script name>", kind = "wake-up",
			lights = { "Bedroom Lamp", "Bedroom Ceiling", "Bedside" }, -- Control4 names then, for the texts
			signature = "<signature of configuration and metadata then>",
			disabled_at = 1793000000, changed_at = 1793000000,
		},
	},
	kept = {
		["<instance rid>"] = { name = "Bedroom dimmer", kept_at = 1793000000,
			lights = { ["<light rid>"] = true } },
	},
	old_bridges = { ["<bridge id>"] = { disabled = { } } }, -- B2, shown only
}
```

Local only, never copied: the script catalogue's small part (id, name,
category, version) and the Hue app only marks with the firmware version
they belong to. An entry is a few hundred bytes. "Pending" and "restoring"
entries are written before their `PUT` (R4, R6).

### 7.2 Where it lives

- **The bridge driver's persistence**, `PersistSetValue("hue_automations",
  …)`, like every registry of the bridge (`docs/design.md` "Storage"),
  written after every change and before every `PUT`.
- **A copy in the controller registry**,
  `C4:RegistrySetValue("c4-hue-driver/automations/<bridge id>", …)`, the
  same table written at the same moments, and deleted when `disabled` and
  `kept` are both empty. It is what a bridge driver deleted and added again
  finds (C10). Snap One advises against keeping state in the registry
  (§0.2); the record is long-lived and belongs to the bridge rather than to
  one driver instance, which is the closest fit, but that is a judgement
  (Q6).
- **The Hue bridge's own `enabled` flags**: the truth for on and off, read
  at every audit (rule 7).

### 7.3 What survives what

| Event | Bridge driver's persistence | Controller registry copy | What the owner keeps |
| --- | --- | --- | --- |
| Director restart, controller reboot | kept [verified: house] | kept [assumed] | everything |
| Bridge driver updated in place | kept [verified: house] | kept [assumed] | everything |
| Bridge driver deleted, then added again and paired | lost [verified: house] | kept [assumed] | everything, adopted at pairing (C10) |
| Bridge driver deleted for good (uninstall) | lost | kept until a bridge driver returns [assumed] | the automations stay disabled, visible and undoable in the Hue app (C11) |
| Project restored on the same controller | rolled back or kept [silent] | kept, not rolled back [assumed] | the newer copy, reconciled with the bridge (C5) |
| Controller replaced or reset | travels if the project carries it [silent] | stays behind or lost [assumed] | when both are lost: "Disabled in Hue (not by Control4)" lines and the Hue app (C12) |
| `Forget Pairing`, then another bridge paired | kept, under the old bridge id | kept | the old bridge's line; entries whose ids exist on the new bridge re-attached (B2) |
| Bridge factory reset | kept until the first successful GET marks entries deleted | as the persistence | nothing to restore (B3) |

### 7.4 Load, merge and reconcile

1. At late init the driver reads its own copy, and the registry copy for
   the bridge id it is paired with; a driver that is not paired yet reads
   the registry copy right after pairing (C10).
2. A registry copy whose writer is another Hue Bridge driver still in the
   project is never taken (C13); one written by this driver, or by a driver
   no longer in the project (C10), is.
3. Of the copies taken, the one with the newer `saved_at` wins whole: both
   are written together, so the newer one holds every later change,
   including entries cleared since. The driver's own copy for another
   bridge id goes to `old_bridges` (B2).
4. At the first successful audit the bridge decides each entry: enabled →
   "enabled again" (a "restoring" one cleared); gone → "deleted"; disabled
   → "disabled" (a "pending" one confirmed).
5. Nothing in this sends a write.

### 7.5 Homes considered and rejected

- **`PersistData`**: it is in the project file, so it would travel with a
  controller replacement [verified: FUND 24/_1], but it goes with a deleted
  driver and is rolled back by a project restore, like the persistence it
  would duplicate (Q6 asks whether that one case is worth a third copy).
- **Sandbox files**: not in backups, lost on migration [verified: FUND
  3_what's_new/_17].
- **The Hue bridge**: CLIP v2 offers clients no storage of their own
  [assumed: HAR]. A marker in the automation's own name ("Hall timer (off:
  Control4)") would survive everything on the Control4 side, but it changes
  what the household reads in the Hue app, needs a second write that can
  fail on its own, clashes with renames made in the app, and must be undone
  by Restore (Q6).
- **v1 resource links or CLIP sensors**: the v1 API (CLAUDE.md: CLIP v2
  only).
- **The Control4 light devices**: no device stands for an automation, and
  spreading the record over the lights would add messages to four drivers
  for what the registry copy does alone.
- **Anywhere off the controller** (the repository, a file on the VM): house
  data stays out of the public repository (CLAUDE.md, Licensing).

## 8. Not in v1, so that nothing automates them

- Disabling new conflicts automatically (an "enforce" mode): it would fight
  the household (rule 6; Q8).
- Writes other than `enabled`: removing Control4 lights from an
  automation's targets, changing time slots or scenes, renaming, creating
  or deleting instances.
- Starting or stopping run-by-hand automations (mimic presence).
- Pausing MotionAware areas or switching sensors off to silence their
  automations.
- Reading v1 rules and schedules (Q7).
- Rows on the light devices ("Hue automations acting on this light").
- Several bridges (the record is per bridge id already).
- Disabling security responses (Q5).

## 9. What differs from lights, scenes and motion

1. **A write to Hue's setup**: one field, on a click, recorded, and only
   where the Hue app shows it (rules 4, 5); lights write light state, motion
   devices nothing (D7).
2. **No device holds the identity**, so the record lives in the bridge
   driver's persistence and in the controller registry (§7); lights rebuild
   a lost registry from their devices.
3. **Never fight**: an automation enabled again outside Control4 is
   reported, not disabled again (H6); nothing else here has a second
   writer.
4. **Conflicts are computed at every audit** (rule 9); light entries and
   states are stored.
5. **The coverage is stated** (H14); every light is visible, not every
   automation.
6. **Keep is a per-automation dismissal holding the lights it covered**
   (R10), as Accept Names As They Are holds the names it accepted.
7. **Bulk clicks report per item and never roll back** (R5, R9).
8. **Write-ahead entries**: the record is written before the `PUT` (R4,
   R6).
9. **The script catalogue decides what may be written** (rule 5); lights
   and motion read resource types only.
10. **EC R9 changes**: "both run, the manual says so" becomes an audited
    conflict, with a Disable or the Hue app steps (S1, S6).

## 10. Questions for the owner (recommended default first)

1. **What counts as a Control4 light**: **every light a Control4 device of
   this bridge can change (Hue Light devices, and the lights of rooms and
   zones with a Zone Light or a Hue Scene device)**, or only lights with a
   Hue Light device of their own?
2. **After a Restore, an automation that still acts on Control4 lights**:
   **kept automatically with its current lights**, so Attention does not
   list it right after your own click, or listed as a conflict again?
3. **Hue switches in Attention**: **listed once until kept** ("every Hue
   switch listed" keeps them all in one click), or in the row only, since
   they act on a button press and Control4 sees what they do?
4. **Automations disabled outside Control4, or whose record was lost**:
   **Restore lists only what Control4 disabled; the others are enabled in
   the Hue app**, or also offer an "Enable" for them, marked "no record"?
5. **Security responses** (if Hue Secure's alarm lights are behaviour
   instances): **listed, never disabled from Control4**, or disabled like
   the others?
6. **Where the record lives**: **the bridge driver's persistence plus a
   copy in the controller registry**; also in `PersistData` (it travels with
   a controller replacement); or also a marker in the automation's Hue name
   (it survives everything, but the household sees it)?
7. **v1 rules and schedules**: **not read; the audit states what it cannot
   see** (CLAUDE.md: CLIP v2 only), or one read-only v1 GET of rules and
   schedules to list them?
8. **Disabling new conflicts automatically**: **never**, or an opt-in
   property later?
9. **"(every automation listed)" in Disable**: **automations only** (not
   kept ones, switches, unknown-lights or Hue app only ones), or every
   listed conflict that can be written?
10. **Entries of automations deleted in Hue**: **kept until cleared from
    Restore**, or dropped after 30 days?
11. **The MotionAware remedy** on the house's area: **the Hue app steps,
    written from the house's area (check 3), and nothing else**, or also a
    configuration write later, if HAR finds a field that can be set and set
    back safely?

## 11. Checks

On the house (Bridge Pro with the MotionAware area of 2026-10-26), through
the dev loop and the development build's Hue Request action
(`docs/dev-loop.md`); each takes about a minute. The Hue app parts of
checks 2 to 5 need the owner's phone. Every write below is put back at
once.

1. GET `/clip/v2/resource/behavior_script` and `/behavior_instance`, logged
   with names and ids redacted: the categories present, the MotionAware
   automation's script category, `dependees` and `configuration`, any
   `migrated_from`, and the catalogue's size.
2. A throwaway automation made in the Hue app on one lamp (a timer): `PUT
   {"enabled": false}`. Does the Hue app show it off? Which stream items
   arrive (`update` with `enabled`, `status`)? Then `PUT {"enabled": true}`,
   then delete it in the app and record the `delete` item.
3. The MotionAware automation: `PUT {"enabled": false}` (expected HTTP 400;
   record the body; if it is accepted, `PUT {"enabled": true}` at once and
   note whether the Hue app showed the change), and in the Hue app the way
   to stop its light response without pausing the area (time slots set to
   do nothing, a zone): S1's steps.
4. The throwaway automation disabled, then edited in the Hue app and saved:
   does it come back enabled, with the same id (H4, H6, H11)?
5. If the house has a Hue switch: `PUT {"enabled": false}` on its instance,
   then press it. Does it still work (rule 5)? Put it back.
6. The controller registry from the dev loop: a string key set and read
   back, then read again after a Director restart. Its survival across a
   driver delete and re-add, and across a project restore, is left
   [assumed] until a test driver can be deleted and re-added through the
   Windows session without touching the house's bridge.
