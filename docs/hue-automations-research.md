# Hue automations on the bridge: research for the automation audit

**Status (2026-10-26): research for issue #280; nothing here is approved or
built.** It collects what an audit of the automations living on the Hue
bridge has to know: how CLIP v2 models them (§1), which ones exist (§2),
MotionAware's own (§3), switches and sensors (§4), what only the v1 API shows
(§5) and what writes do (§6). It then proposes when an automation conflicts
with Control4 (§7) and what can be done about each kind (§8). Every fact comes
from public sources (§11). Nothing was checked against a bridge. §9 lists what
the house bridge (a Hue Bridge Pro with one MotionAware area), the owner and
Signify's login-only pages can still answer. The feature's contract follows
the owner's answers.

The owner's rule behind the feature: **Control4 is the source of truth for
automations, not the Hue app.** Hue-side automations that act on lights
Control4 also programs are to be found and reported, and switched off where
the bridge allows it: from a click, and always reversibly.

Markers, as in the #268 research (`docs/motion-hue-research.md`, on that
feature's branch until it merges):

- **[verified: S]**: shown by source S (§11): code that parses real bridges
  (aiohue, Home Assistant, openHAB), a JSON dump recorded from a real bridge,
  or a Philips Hue page.
- **[community: S]**: reported by a user or developer in S (an issue, a forum
  post, a pull request description); plausible, not shown by code or a dump.
  Treat it as assumed when designing.
- **[assumed]**: no source shows it; reasoning or analogy, for the house
  bridge to confirm.
- **[needs the owner to paste: page]**: only on Signify's login-only developer
  reference, which this research may not read.

"Dump" means a JSON fixture a project recorded from its own bridge: Home
Assistant's (2023, a v2 bridge, script names kept), openHAB's (recorded
responses, script and instance names kept) and aiohue's (July 2026, a Bridge
Pro, names anonymised, descriptions kept). Instance ids in this note are
invented. Script ids are quoted, because the same id names the same script on
every bridge (§1.2).

## Summary

1. Every automation the Hue app makes, and every button, dial or sensor
   set-up, is a `behavior_instance`: one configured copy of a
   `behavior_script` that Signify ships with the firmware. The instance names
   its script in `script_id`. Its `configuration` holds triggers and targets
   in a shape of the script's own; the bridge serves only the schema's file
   name, never the schema.
2. The script's `metadata.category` sorts them: `automation` (the app's
   Automations: Wake up, Go to sleep, Timers, Lighting schedule, Coming home,
   Leaving home, Mimic presence, the smoke-alarm light-up), `accessory`
   (switches, dials, buttons, contact sensors), `entertainment` (the light
   state after a sync session), and `other` or empty (Natural Light). Home
   Assistant and openHAB show only `automation` instances as switches.
3. Each instance lists what it depends on in `dependees` (critical or not;
   deleting a critical target deletes the instance). Together with a walk of
   `configuration` for resource references, that finds the lights, rooms,
   zones, scenes, switches and sensors an instance touches without knowing
   each script's schema.
4. `enabled` is the on/off. `{"enabled": false}` works on `automation`
   instances with a toggle (Home Assistant and openHAB write it). On play/stop
   automations (Mimic presence) the app's control is `trigger` start/stop, and
   `enabled` is a setting the app does not show. Accessory and entertainment
   instances refuse it or accept it without effect. The MotionAware area's
   instance answers HTTP 400.
5. MotionAware has two switches: the area's own `enabled`
   (`motion_area_configuration`), which stops the sensing, and a separate
   light-control instance, whose `enabled` is refused. The area seems to report
   motion to other systems only while its light control is on; a community
   recipe keeps it on with no lights selected. Time slots can also be "Do
   nothing" both ways. So a Control4-only area is probably possible, but only
   through a Hue-side automation that does nothing; the house's one area can
   confirm it in minutes (§9.1).
6. Switches and sensors set up in the app cannot be switched off through the
   API. The app's ways are to change what the buttons do, or to reset the
   device and hand it to "another app". Their `button` services carry only
   events, which presumably keep coming whatever the set-up.
7. v1: the Hue app's old set-ups were migrated to instances (`migrated_from`
   holds the old v1 `/resourcelinks/N`). Third-party apps (iConnectHue, All 4
   Hue) and the Hue Labs formulas still running keep v1 rules, schedules and
   virtual sensors that CLIP v2 does not show at all. The house's Bridge Pro
   would have taken over any such content from the bridge it replaced. A
   v2-only audit misses them, and it misses cloud automations (Alexa, Google
   Home, Apple Home, SmartThings) in any case.
8. Proposed rule: an instance conflicts when it is on, can fire without a
   person (time, presence, motion, contact, alarm) and touches a light Control4
   controls (high), or fires on a sensor Control4 now owns (medium). Switches a
   person presses are low ("shared control"). The owner can mark any instance
   "keep on Hue side".
9. Remediation: `{"enabled": false}` (or `trigger` stop) from a click, for
   `automation` instances only, remembered and undone by a second click.
   Everything else is reported with the app's steps. Never delete, never
   rewrite a `configuration`, never switch off a sensor or an area.
10. New this week: Custom AI Behaviors for the Bridge Pro (firmware
    6.3.2071556020 out on 2026-10-22, the app's launch due the week of
    2026-10-26). How they are stored is unknown, so the audit must treat unknown
    scripts as "unknown, report only".

## 1. The model

### 1.1 Two resources

| Resource | What it is | Methods in public models | Source |
| --- | --- | --- | --- |
| `behavior_script` | A program Signify ships with the bridge firmware, one per kind of automation or accessory set-up. Clients cannot add scripts; they can only configure Signify's. | GET all, GET one; a PUT whose body holds nothing but `type` | methods [verified: [openhue-bs]]; "no own scripts" [community: [hueblog-api-2023]] |
| `behavior_instance` | One configured use of a script: an automation from the app, a switch's buttons, a sensor's or a MotionAware area's light control, the light state after an entertainment session. | GET all, GET one, PUT one; POST with `script_id`, `enabled`, `configuration`, `metadata`, `migrated_from`; DELETE | GET and PUT [verified: [openhue-bi]]; POST [verified: [aiohue-bi], its create model; community: [huemanager] recreates instances]; DELETE [assumed: in no public model] |

Capacity: room for about 200 script-based set-ups on the Bridge Pro against
45 on the v2 bridge, beside a v1 rule limit of 250 on both [community:
[hueblog-rules], citing Signify; that its "scripts" are what CLIP v2 calls
instances is assumed].

### 1.2 `behavior_script`

| Field | Meaning | Source |
| --- | --- | --- |
| `id` | The script's id. The same id names the same script on every bridge: Home Assistant's 2023 dump and openHAB's give identical ids to the same eight scripts, and the instances in aiohue's 2026 Bridge Pro dump run scripts whose ids openHAB's dump also has (Light state after streaming, Tap Switch, the dimmer switch's). Match on names and categories first, ids second. | [verified: [ha-fixture], [oh-bs], [oh-bi], [aiohue-fixture]] |
| `metadata.name` | Signify's English name, not always the app's ("Basic wake up routine" is the app's Wake up) | [verified: [oh-bs]] |
| `metadata.category` | `automation`, `accessory`, `entertainment` or `other`; aiohue reads any other value as `other`, openhue declares a plain string. Natural Light carries an empty string. In Home Assistant's 2023 dump only Timers has the field, so older firmware left it out. | [verified: [aiohue-bs], [openhue-bs], [oh-bs], [ha-fixture]]; "older firmware" [assumed] |
| `description` | One English sentence ("Countdown Timer", "Tap Switch script") | [verified: [oh-bs]] |
| `configuration_schema`, `trigger_schema`, `state_schema` | Each a reference to a file name (`basic_wake_up_config.json#`) or `{}`, never the schema itself: a client cannot validate a configuration. Accessory scripts have an empty trigger schema. | [verified: [oh-bs], [ha-fixture], [aiohue-fixture]] |
| `version` | "0.0.1" on every script seen | [verified: [oh-bs]] |
| `supported_features` | Usually empty; Basic wake up routine lists `style_sunrise` and `intensity` | [verified: [oh-bs]] |
| `max_number_instances` | Present on single-use scripts: 1 on presence mimicking (PM) and on the smoke alarm automation | [verified: [oh-bs], [aiohue-fixture]] |
| `id_v1` | Optional; none seen | [verified: [aiohue-bs]] |

### 1.3 `behavior_instance`

| Field | Meaning | Source |
| --- | --- | --- |
| `id`, `type` | | [verified: dumps] |
| `script_id` | The script it runs: the only link between the two | [verified: [openhue-bi], [aiohue-bi]] |
| `metadata.name` | The name the app shows ("Wake Weekdays", "Coming home", a switch's name) | [verified: [hb-1087], [oh-bi]] |
| `enabled` | The on/off. For ordinary automations it is the app's toggle; for play/stop automations it is a setting the app does not show (§6.1). | the toggle [assumed]; play/stop [community: [ha-177691]] |
| `status` | `initializing`, `running`, `disabled`, `errored`. Not a reliable on/off: a disabled instance read `initializing` in one dump. | values [verified: [openhue-bi], [aiohue-bi]]; the disabled one [verified: [hb-1087]] |
| `last_error` | Text while `errored`, "" otherwise | [verified: dumps] |
| `state` | Read-only, per the script's state schema: `timer_state` on Timers, `pm_state` (`started`, `stopped`) on presence mimicking, `model_id` and `source_type` on a dimmer switch; absent or null on most | [verified: [ha-fixture], [aiohue-bi], [oh-bi], [aiohue-fixture]] |
| `configuration` | Triggers and targets, per script (§1.4) | [verified: dumps] |
| `dependees[]` | `{type: "ResourceDependee", level, target {rid, rtype}}` (§1.5). openhue models the items as bare resource identifiers, unlike every dump. | [verified: dumps, [aiohue-bi]; [openhue-bi]] |
| `migrated_from` | Optional v1 path (§1.6) | [verified: [aiohue-bi], [oh-bi], [hb-1087]] |
| `id_v1` | Optional; none seen | [verified: [aiohue-bi]] |

A PUT accepts `enabled`, `configuration`, `metadata.name` and `trigger`
[verified: [openhue-bi] for the first three, [aiohue-bi] for `trigger`].
`trigger` exists only on the way in: `{"trigger":{"start":{}}}` starts and
`{"trigger":{"stop":{}}}` stops an instance that runs on demand. aiohue's
docstring adds that `enabled` only arms such an instance [verified:
[aiohue-config]]. One user starts Go to sleep and Wake up the same way from
Node-RED [community: [ha-forum-trigger]].

### 1.4 `configuration`: where triggers and targets live

There is no public schema (the served schema is a file name, §1.2). The keys
below are the ones the dumps show; each script has its own shape.

| Key | Holds | Seen on | Role | Source |
| --- | --- | --- | --- | --- |
| `where[]` | `{group {rid, rtype}, items[] {rid, rtype: light}}`: rooms and zones, optionally narrowed to some of their lights | Wake up, Timers, a time-based instance of 2022 (probably a Schedule), Coming home, a dimmer switch (once for all buttons), a tap dial (per button and dial), the light state after streaming (an `entertainment_configuration`) | targets | [verified: [hb-1087], [ha-fixture], [oh-bi], [aiohue-fixture]]; "probably a Schedule" [assumed: the issue hides its script id] |
| `what[]` | `{group {rid, rtype}, recall {rid, rtype: scene or recipe}}`: what each group gets | Timers, the 2022 time-based instance, Coming home | targets and the light state | same |
| `when` | `{recurrence_days[], time_point {type: time, time {hour, minute}}}` | Wake up | trigger: a time | [verified: [hb-1087]] |
| `when_extended` | `{recurrence_days[], start_at {time_point}}` | the 2022 time-based instance | trigger: a time | [verified: [hb-1087]] |
| `when_constrained` | `{type: nighttime}` | Coming home | condition | [verified: [oh-bi]] |
| `fade_in_duration`, `duration` | `{seconds}` | Wake up; Timers | timing | [verified: [hb-1087], [ha-fixture]] |
| `device`, `model_id` | The switch's device and model | dimmer switch | trigger source | [verified: [oh-bi], [aiohue-fixture]] |
| `buttons {<button id>: {...}}` | Per button `on_short_release`, `on_long_press`, `on_repeat`, optionally its own `where` | dimmer switch | trigger and action | same |
| `button1` to `button4`, `rotary` | The same per button; the dial's `on_dim_on` and `on_dim_off` | tap dial | trigger and action | [verified: [aiohue-fixture]] |
| button actions | `action`: `all_off`, `do_nothing`, `dim_up`, `dim_down`; `time_based_extended {slots[{start_time, actions[{action {recall {rid, rtype: scene}}}]}], with_off {enabled}, repeat_timeout {seconds}}`; `scene_cycle_extended {slots[[...]], with_off, repeat_timeout}`; `recall_single_extended {actions[], with_off}`; `recall_single [{action: last_on}]` | dimmer switch, tap dial | actions | [verified: [oh-bi], [aiohue-fixture]] |
| `end_state` | `last_state` | Light state after streaming | action | [verified: [aiohue-fixture]] |
| `source`, `motion.motion_service`, `light_level.daylight.daylight_sensitivity` | The sensor's device (or the MotionAware area's configuration), the motion service it listens to, and the light-level service with `settings {dark_threshold, offset}`, where a threshold of 65534 means "ignore daylight" | motion automations | trigger and condition | [community: [halo-motion], fixtures written by a developer who tested against a real bridge ([halo-1065])]; the area's `source` [community: [ha-181632]] |
| time slots and targets of a motion automation | not in any public dump | | | [assumed: a `where` and per-slot actions, as the app shows] |

A reading that needs no schema: every object `{rid, rtype}` anywhere in
`configuration`, and every object key that is a resource id (the dimmer's
`buttons`), is a reference, and its rtype says what it is. Together with
`dependees` that lists everything an instance touches [assumed: it holds for
every dump above; the proposal behind §7.2].

### 1.5 `dependees`

- `level` is `critical` (the instance cannot work without the target;
  removing the target removes the instance) or `non_critical` (the instance is
  affected but stays) [verified: [aiohue-bi], whose docstrings describe
  Signify's schema].
- What they held in the dumps, all critical: Wake up, its rooms and lights;
  Coming home, its rooms and scenes; a timer, its room; a dimmer switch, its
  device, its zone, the scenes of its time slots and its four buttons; a tap
  dial, its device and room; the light state after streaming, its
  entertainment configuration [verified: [hb-1087], [oh-bi], [ha-fixture],
  [aiohue-fixture]]. Coming home listed no geofence client [verified: [oh-bi]].
- So dependees mix the trigger side (a switch's device and buttons) with the
  target side (rooms, zones, lights, scenes). The rtype, and whether a device
  owns a `light` service, tell them apart [assumed: design proposal].
- Deleting a scene, a room or a zone in the Hue app can take whole instances
  with it. The house saw the same mechanism with smart scenes: deleting a
  slot's scene deleted the smart scene one second later
  ([smart-scenes-research.md](smart-scenes-research.md) §7, V14) [assumed: the
  same for instances].

### 1.6 `migrated_from`

- A v1 path: `/resourcelinks/5338` on a dimmer switch's set-up [verified:
  [oh-bi]], `/resourcelinks/<n>` on two Wake up instances [verified: [hb-1087]].
  Instances made since carry none (Coming home in [oh-bi]; a time-based
  instance made in 2022 in [hb-1087]).
- A v1 resourcelink grouped the rules, schedules, virtual sensors, scenes and
  groups that one app feature created; the bridge never acts on resourcelinks
  [community: [hb-resourcelinks]].
- The create model accepts `migrated_from` [verified: [aiohue-bi]], so whoever
  replaced a v1 set-up by an instance wrote the old path there [assumed]. On
  the bridge of [hb-1087] the v1 schedules list was empty afterwards, so the v1
  pieces went with the move [assumed].
- The field says "this came from the v1 era", nothing more: the resourcelink
  it names may no longer exist [assumed].

### 1.7 Events

- Instances arrive in `add`, `update` and `delete` containers like any
  resource. openHAB adds or removes its automation channel on `add` and
  `delete`, and sets the channel from `enabled` on `update` [verified:
  [oh-bridge-handler]]. Starting an automation in the app produced an update
  carrying its new `state` [community: [oh-forum-trigger]].
- An update item carries `id`, `type` and the changed fields (`enabled`,
  `state`, `status`, `last_error`, `configuration`, `metadata`) [assumed, as
  for other resources: [design.md, Event stream](design.md#event-stream)].
- Scripts change only with the firmware [assumed]; the resync after a bridge
  restart re-reads them.
- Nothing in an event says which instance changed a light: lights, grouped
  lights and scenes report a change without its cause [assumed: no such field
  in any public model]. The audit can say what could fire, never what fired.

### 1.8 Sample shapes

Invented ids, shapes from the dumps (§1.3, §1.4). A Wake up migrated from v1
([hb-1087]):

```json
{"id":"b1000000-0000-4000-8000-000000000001","type":"behavior_instance",
 "script_id":"ff8957e3-2eb9-4699-a0c8-ad2cb3ede704",
 "metadata":{"name":"Wake Weekdays"},"enabled":true,"status":"running","last_error":"",
 "configuration":{
  "fade_in_duration":{"seconds":600},
  "when":{"recurrence_days":["monday","tuesday","wednesday","thursday","friday"],
          "time_point":{"type":"time","time":{"hour":6,"minute":30}}},
  "where":[{"group":{"rid":"40000000-0000-4000-8000-000000000001","rtype":"room"},
            "items":[{"rid":"1a000000-0000-4000-8000-000000000001","rtype":"light"}]}]},
 "dependees":[
  {"type":"ResourceDependee","level":"critical","target":{"rid":"40000000-0000-4000-8000-000000000001","rtype":"room"}},
  {"type":"ResourceDependee","level":"critical","target":{"rid":"1a000000-0000-4000-8000-000000000001","rtype":"light"}}],
 "migrated_from":"/resourcelinks/12"}
```

A dimmer switch's set-up ([oh-bi], shortened to two buttons):

```json
{"id":"b1000000-0000-4000-8000-000000000002","type":"behavior_instance",
 "script_id":"67d9395b-4403-42cc-b5f0-740b699d67c6",
 "metadata":{"name":"Bedroom dimmer"},"enabled":true,"status":"running","last_error":"",
 "state":{"model_id":"RWL022","source_type":"device"},
 "configuration":{
  "device":{"rid":"de000000-0000-4000-8000-000000000031","rtype":"device"},
  "model_id":"RWL022",
  "where":[{"group":{"rid":"40000000-0000-4000-8000-000000000002","rtype":"zone"}}],
  "buttons":{
   "bb000000-0000-4000-8000-000000000001":{
    "on_short_release":{"time_based_extended":{
      "slots":[{"start_time":{"hour":7,"minute":0},
                "actions":[{"action":{"recall":{"rid":"5e000000-0000-4000-8000-000000000001","rtype":"scene"}}}]}],
      "with_off":{"enabled":false}}},
    "on_long_press":{"action":"do_nothing"}},
   "bb000000-0000-4000-8000-000000000002":{"on_repeat":{"action":"dim_up"}}}},
 "dependees":[
  {"type":"ResourceDependee","level":"critical","target":{"rid":"de000000-0000-4000-8000-000000000031","rtype":"device"}},
  {"type":"ResourceDependee","level":"critical","target":{"rid":"40000000-0000-4000-8000-000000000002","rtype":"zone"}},
  {"type":"ResourceDependee","level":"critical","target":{"rid":"5e000000-0000-4000-8000-000000000001","rtype":"scene"}},
  {"type":"ResourceDependee","level":"critical","target":{"rid":"bb000000-0000-4000-8000-000000000001","rtype":"button"}},
  {"type":"ResourceDependee","level":"critical","target":{"rid":"bb000000-0000-4000-8000-000000000002","rtype":"button"}}]}
```

The trigger half of a motion sensor's set-up ([halo-motion]; its slots and
targets are in no public dump):

```json
{"configuration":{
  "source":{"rid":"de000000-0000-4000-8000-000000000041","rtype":"device"},
  "motion":{"motion_service":{"rid":"a0000000-0000-4000-8000-000000000041","rtype":"motion"}},
  "light_level":{"daylight":{"daylight_sensitivity":{
    "light_level_service":{"rid":"11000000-0000-4000-8000-000000000041","rtype":"light_level"},
    "settings":{"dark_threshold":14477,"offset":7000}}}}}}
```

## 2. Catalogue of scripts

"Kind" is the category §7 uses. App versions are the Hue app's [verified:
[hue-rn-ios], [hue-rn-android]].

| Script: served name; category; id | The app's name and use | Fires on | Targets in | Trigger in | Kind | Source |
| --- | --- | --- | --- | --- | --- | --- |
| Basic wake up routine; `automation`; `ff8957e3-2eb9-4699-a0c8-ad2cb3ede704` | Wake up: fades lights up | a time on chosen days | `where[]` groups and lights | `when` | timed | [verified: [oh-bs], [hb-1087]] |
| Basic go to sleep routine; `automation`; `7e571ac6-f363-42e1-809a-4cbf6523ed72` | Go to sleep: fades down and off; a Sunset style and a start from a switch or widget since 5.19 | a time, or a person | `where[]` [assumed: as Wake up] | `when` if timed [assumed] | timed, or manual | [verified: [oh-bs], [hue-rn-ios]] |
| Schedule; `automation`; `7238c707-8693-4f19-9095-ccdc1444d228` | "Custom", renamed "Lighting schedule" in 5.70: lights to a scene or off at times | a time on chosen days | `what[]`, `where[]` | `when_extended` | timed | the script [verified: [oh-bs], [ha-fixture]]; its keys [assumed: from the 2022 instance of [hb-1087], whose script id the issue hides]; that "Lighting schedule" is this script [assumed: name and description match] |
| Timers; `automation`; `e73bc72d-96b1-46f8-aa57-729861f80c78` | Timers: does something when a countdown ends | a person starts it (play button; a switch since 5.27) | `what[]`, `where[]` | `duration`; running shown in `state.timer_state` | manual | [verified: [ha-fixture], [oh-bs], [hue-rn-ios]] |
| Coming home; `automation`; `fd60fcd1-4809-4813-b510-4a18856a595c` | Coming home: scenes when a phone of the household arrives | presence (geofence), here only at night | `what[]`, `where[]` | the household's `geofence_client` items, not referenced in the instance; `when_constrained` | presence | [verified: [oh-bi], [oh-bs], [oh-geofence]] |
| Leaving home; `automation`; `0194752a-2d53-4f92-8209-dfdc52745af3` | Leaving home: lights off when the last phone leaves | presence | [assumed: `where[]`] | geofence | presence | [verified: [oh-bs], [aiohue-fixture] (description)] |
| PM; `automation`, at most 1; `db06cabc-c752-4904-9e8f-4ebe98feaa1a` | Mimic presence: lights rooms on and off as if someone were home; started and stopped by play/stop or, since 5.27, a switch; when it starts it switches off every light it does not use | a person starts it; then on its own | [assumed: rooms in the configuration] | `state.pm_state` | presence simulation | [verified: [oh-bs], [aiohue-bi], [hue-rn-ios]; [hue-faq-automations] (answers read from a search engine's copy: the page loads them in the browser)] |
| Smoke alarm automation; `automation`, at most 1; id anonymised | [assumed] lights on when a Hue Secure camera hears a smoke or CO alarm (5.57) | an alarm | [assumed] | [assumed] | safety | [verified: [aiohue-fixture], [hue-rn-ios]]; the link between them [assumed] |
| Natural Light; empty category; `a4260b49-0c69-4926-a29c-417f4a38a352` | Unknown; "Natural light during the day" | unknown | unknown | unknown | unknown | [verified: [oh-bs], [ha-fixture]] |
| Light state after streaming; `entertainment`; `7719b841-6b3d-448d-a0e7-601ae9edb6a2` | An entertainment area's setting: the lights' state after a sync session | a sync session ending | `where[]` (an `entertainment_configuration`), `end_state` | none | entertainment | [verified: [oh-bs], [aiohue-fixture]] |
| Tap Switch; `accessory`; `f306f634-acdb-4dd6-bdf5-48dd626d667e` | A tap dial's buttons and dial (probably also the old Hue Tap) | a person | each button's and the dial's `where[]`; scenes in the actions | `button1` to `button4`, `rotary` | switch | [verified: [oh-bs], [aiohue-fixture]]; the old Tap [assumed] |
| (the dimmer switch script; its name is in no dump); `accessory` [assumed]; `67d9395b-4403-42cc-b5f0-740b699d67c6` | A dimmer switch (RWL021, RWL022) | a person | `where[]`; scenes in the slot actions | `device`, `buttons` keyed by button id | switch | [verified: [oh-bi], [aiohue-fixture]] |
| Generic switches script; `accessory`; id anonymised | [assumed] wall switch modules, smart buttons, Friends of Hue switches; Home Assistant's test data names one instance "Wall switch Hallway" | a person | [assumed: as the dimmer] | [assumed] | switch | [verified: [aiohue-fixture]; [ha-const] (test data)] |
| Contact Sensor script; `accessory`; id anonymised | The Secure contact sensor's light behaviour [assumed] | a door or window | [assumed] | [assumed] | sensor | [verified: [aiohue-fixture]] |
| (a motion sensor's script; name and id in no public dump) | A motion sensor's set-up: time slots, daylight | motion, and no motion after a delay | [assumed: `where[]` and slot actions] | `source`, `motion.motion_service`, `light_level.daylight...` | sensor | [community: [halo-motion]] |
| (MotionAware's script; name and id in no public dump) | A motion area's "control lights" response (§3) | motion in the area | a zone in one report [community: [ha-181632]] | `source` is the `motion_area_configuration` | sensor | [community: [ha-181632], [ha-153935]] |
| Others | Camera detection areas that switch lights (5.60), the security system's arming schedule (5.34), automations made by the AI assistant (5.55), Custom AI Behaviors (Bridge Pro firmware 6.3) | unknown | unknown | unknown | unknown | [verified: [hue-rn-ios]; community: [hueblog-ai-0905], [hueblog-ai-1023]] |

- Telling them apart in code: the category first, then the served name, then
  the id; anything else is `unknown`, listed with the references it holds and
  never written to [assumed: design proposal]. Home Assistant and openHAB stop
  at the category: only `automation` instances become switches, and Home
  Assistant removed in 2026-08 the switches it had made for accessory and
  entertainment instances, because toggling them did nothing [verified:
  [ha-switch], [oh-bridge-handler]; community: [ha-177671]].
- The AI assistant (app 5.55 onward) makes ordinary automations [assumed: the
  same scripts]. What Custom AI Behaviors add on the bridge is not public yet;
  the examples given are a dimmer switch whose button cycles scenes after
  8 p.m., a schedule that picks another scene each day, and weekend schedules
  for sensors and MotionAware [community: [hueblog-ai-0905]].
- Since app 5.61 the app lists automations, accessory ones included, inside
  the rooms and zones they control [verified: [hue-rn-ios],
  [notebookcheck-561]].
- Smart scenes are not instances, but a running one changes lights at its slot
  boundaries. The driver already starts and stops them
  ([smart-scenes-design.md](smart-scenes-design.md)).

## 3. MotionAware's own automation

### 3.1 Which resource holds it

| Thing | Resource | Source |
| --- | --- | --- |
| The area: name, room or zone, sensing lights, health, on/off | `motion_area_configuration` (`enabled`) | [verified: `docs/motion-hue-research.md` §2.3 (#268); [aiohue-config]] |
| Its motion | `convenience_area_motion` while the area is bound to lights, `security_area_motion` otherwise | [verified: motion research §2.5; community: [ha-177643]] |
| What the lights do on motion | A `behavior_instance` whose `source` is the area's configuration, acting on a room or zone | [community: [ha-181632], [ha-153935]]; its script's name and category [assumed: unknown, §9.1 H3] |

So an area has two switches that do not follow each other. An area turned off
in the app reads `enabled: false` and `health: not_running` on its
configuration, while its light-control instance still reads `enabled: true`
[community: [ha-153935]].

### 3.2 Through the API

| Write | Result | Source |
| --- | --- | --- |
| `{"enabled": false}` on the area's instance | HTTP 400. One reporter saw the description "The instance doesn't support triggers". Several users in two issues, 2025-10 to 2026-02. | [community: [ha-153935], [ha-160393]] |
| `{"enabled": false}` on the `motion_area_configuration` | Accepted; the area stops sensing, as with the app's area switch | [verified: [aiohue-config], [ha-switch]; community: [aiohue-628]] |
| `enabled` on the area's two motion services | Accepted, no effect | [community: motion research §2.5] |
| The instance's `configuration` | Probably writable: iConnectHue 5.15 lets the owner pick an area's lights, shorten its no-motion delay to 30 s and choose among a few actions, once the area exists | the app's features [verified: [iconnect-515], [hueblog-iconnect-ma]]; that it writes the instance [assumed] |
| The configuration's schema | Not public: Signify documented creating and configuring motion areas on 2025-09-04, behind its login | [verified: [hue-dev-news]]; [needs the owner to paste: the API reference for motion areas and their light control] |

Verdict: the area's light control cannot be switched off through `enabled`,
and changing its configuration would mean writing an undocumented shape. Both
are forbidden for the audit (§8).

### 3.3 Does the area keep reporting motion when Hue does nothing with it?

| Set-up in the Hue app | Motion reported to other systems | Source |
| --- | --- | --- |
| The area switched off | No: `health` `not_running` | [community: [ha-153935]; motion research §2.5] |
| No response to motion at all | Not offered: at creation the app asks for lights, alerts, or both | [verified: [hue-ma-article]] |
| Light control off (the area controls no lights) | No: a Homey user's areas stopped reporting while they controlled no lights, and worked while they did | [community: [homey-150704], 2026-03-30] |
| Light control on, every light deselected | Yes, according to two Homey threads: keep the area's "turn lights on" switch on and deselect its lights. In one, the asker confirmed that switching that setting on made his area report again; in the other, the user who gave the recipe added that he was not sure it is still current. | [community: [homey-154905] (2026-05-14 to 16), [homey-150704] (2026-10-09)] |
| Light control on, every time slot "Do nothing" on motion and on no motion | Probably yes, since the instance still runs; a reviewer saw lights dim or go off in one slot anyway | [assumed]; the options and the observation [verified: [pcworld-ma]] |
| Alerts only (a Hue Secure or MotionAware plan) | Probably on the security service only | [assumed: from [ha-177643]'s choice of service] |
| Light control on (Hue's normal set-up) | Yes, on the convenience service | [verified: motion research §2.5] |

One Home Assistant user found an area too slow and unreliable as a trigger
once Hue's own light control was disabled, while the Hue app's reaction was
quick [community: [ha-disc-960], 2025-10-01]. Hue's lights react 1 to 2 s
after entry [community: motion research §2.1].

### 3.4 What the app offers

- At creation, after the calibration: control lights (in up to three rooms or
  one zone, not necessarily the sensing lights), send alerts (a Hue Secure plan
  with a camera, or a MotionAware plan, after a 30-day trial), or both
  [verified: [hue-ma-article]].
- Up to 10 time slots a day. Per slot, on motion: a scene, "Last on state" or
  "Do nothing"; on no motion, after 1 to 60 minutes: "Off", "Do nothing" or
  "Return to previous state". A per-slot "Do not disturb" leaves lights that
  are already on alone; a daylight setting stops daytime triggering; no
  weekday-specific slots [verified: [pcworld-ma], [hue-ma-article]]. "Do not
  disturb" misbehaved right after slot changes on MotionAware areas, on Bridge
  Pro firmware of 2025-10 to 2026-04 [community: [he-12815]].
- The area can be paused or switched off from its settings menu [verified:
  [hue-ma-article]]; that stops the sensing (§3.3).

### 3.5 Answer

- **A Control4-only area is probably possible, but only through a Hue-side
  automation that does nothing:** the area on, its light control on, and
  either no lights selected (the cleanest: the instance then targets nothing)
  or every slot "Do nothing" both ways [community and assumed, §3.3]. Control4
  then reads the convenience service, as the #268 contract does.
- The audit reports an area's instance like any sensor automation (§7), offers
  nothing programmatic, and gives the app's steps (§8).
- Never switch the area off or write its services: Control4 would lose the
  motion too.
- The house's one area settles all of it in a few minutes (§9.1, H3, H7, H9).

## 4. Switches and sensors set up in the Hue app

### 4.1 Where their behaviour lives

| Piece | Resource | Holds | Writable | Source |
| --- | --- | --- | --- | --- |
| What a button or dial does | `behavior_instance` of an accessory script (§2) | per-button actions and targets | `enabled` refused or without effect (§6.1) | [verified: [oh-bi], [aiohue-fixture]; community: [ha-177671]] |
| A button | `button` service of the switch's device | `button_report {updated, event}` with `initial_press`, `repeat`, `short_release`, `long_press`, `long_release`, `double_short_release`; the events it can send; `metadata.control_id` | no write in aiohue's model | [verified: [aiohue-button]] |
| A wall switch module's mode | `switch_input_configuration` (since 2026-06, replacing the device's `device_mode`) | single or dual, rocker or push-button; the button services of that mode | `switch_mode.mode` only | [verified: [aiohue-sic], [hue-dev-news]] |
| Switches in v1 | `/sensors/N`, with the Hue app's rules until they were migrated | | | [community: [hueblog-rules]] |

The `button` services report presses whatever an instance does with them:
Home Assistant turns them into `hue_event`s, at most one a second per device
[verified: [ha-docs]]. That a switch with no set-up on the bridge still
reports presses is [assumed: the event comes from the service, not the
instance].

### 4.2 Reading one

- The switch: `configuration.device` (dimmer) or the `device` dependee; its
  buttons are the keys of `buttons`, or `button1` to `button4`.
- Its targets: the top-level `where[]`, each button's own `where[]`, and the
  scenes in its slot actions. `all_off` acts on the `where` groups [assumed:
  the action has no target of its own].
- A button that starts or stops an automation (timers and Mimic presence,
  since app 5.27 [verified: [hue-rn-ios]]) refers to that instance [assumed:
  its rtype in the action]; the audit then also reports that automation.

### 4.3 Switching one off

- Through the API: no. Accessory instances are device configuration that the
  bridge keeps running even after it accepts `enabled: false`; Home Assistant
  removed its switches for them in 2026-08 because they did nothing
  [community: [ha-177671], [ha-switch] comments].
- The button services cannot be switched off; the device can only be deleted
  [assumed: no `enabled` on `button` in any model].
- In the app: change what the buttons do (other rooms, a scene, nothing on a
  long press), or reset the switch and choose to configure it in another app,
  which removes Hue's set-up. While a set-up exists on the bridge it wins over
  another system's [community: [linkdhome] (2020), [reconfigo] (2026: set the
  accessories it manages to "Configure in another app" and switch off competing
  Hue automations)]. The labels are unverified for today's app.
- A switch the owner keeps on the Hue side and presses on purpose is shared
  control, not a conflict (§7.4).

### 4.4 Motion sensors, contact sensors and cameras

- A motion sensor's set-up is an instance too, with time slots, a daylight
  threshold and targets [community: [halo-motion]; up to 10 slots and Natural
  light since 2023: [hueblog-motion-2023]].
- `motion.enabled: false` on the sensor stops it reporting at all, which would
  blind Control4 too [verified: motion research §1.3, §4.1]. The instance's own
  `enabled` presumably does nothing, as for other accessory set-ups [assumed].
- In the app: every slot "Do nothing" both ways, or "configure in another
  app" [community: [reconfigo]]; the slot options [assumed: as MotionAware's,
  §3.4].
- Contact sensors and cameras that switch lights: the same. The Secure contact
  sensor exists only for scripts, with no v1 rules at all [community:
  [hueblog-rules]].

## 5. Legacy v1

### 5.1 What only v1 shows

| v1 resource | Holds | Who makes them today | In CLIP v2 | Source |
| --- | --- | --- | --- | --- |
| `/rules` | Condition-action rules: `name`, `owner` (the app that made it), `status`, `conditions`, `actions`, `lasttriggered`, `timestriggered`, `recycle`; at most 250 per bridge, Bridge Pro included | third-party apps (iConnectHue, All 4 Hue), Hue Labs formulas, the Hue app before migration | no | [community: [node-hue-rule], [hueblog-rules], [huemanager]] |
| `/schedules` | Timed commands: `name`, `description`, `command`, `localtime`, `status`, `autodelete` | third-party apps, any API client | no | [community: [node-hue-schedules], [hb-1087]] |
| `/sensors` of the CLIP types | Virtual flags and status values that rules use as variables | third-party apps, Hue Labs | no; physical sensors are, with `id_v1` `/sensors/N` | [community: [huemanager]]; physical sensors [verified: motion research §1.2] |
| `/resourcelinks` | Groupings of the above per app feature; the bridge does not act on them | the Hue app of the v1 era, Hue Labs, other apps | only as `migrated_from` text | [community: [hb-resourcelinks]]; [verified: [oh-bi]] |
| the `/config` whitelist | Every application with access to the bridge, with its name and last use | every pairing | no | [assumed] |

### 5.2 What moved to v2

- The Hue app's own set-ups became instances; `migrated_from` names the old
  resourcelink (§1.6). All automations and accessory functions made in the
  Hue app now run on scripts and do not count toward the 250 rules; new
  accessories such as the Secure contact sensor exist only for scripts
  [community: [hueblog-rules]].
- The v1 API still takes schedules from other clients; the Hue app no longer
  makes them [community: [hb-1087], the maintainer's reply].

### 5.3 What a v2-only audit misses

| Missed | Example | Note |
| --- | --- | --- |
| v1 rules of third-party apps | iConnectHue's switch set-ups, All 4 Hue | They act on lights as instances do |
| Hue Labs automated formulas | Still running after Hue Labs closed on 2024-06-25, editable nowhere; the Hue app deletes them all at once under its bridge settings ("Hue Labs", "Delete all formulas") | [verified: [hue-labs]] |
| v1 schedules | Timers or routines of other apps | |
| Virtual CLIP sensors | State that v1 rules read | Indirect |
| Cloud and hub automations | Alexa routines, Google Home, Apple Home, SmartThings, IFTTT: they command the bridge from outside, invisible to both APIs | CLIP v2 shows only that HomeKit is paired (`homekit.status`) and which Matter fabrics exist (`matter_fabric.fabric_data.vendor_id`, `label`) [verified: [oh-homekit], [oh-matter-fabric]] |

### 5.4 The house

- The house bridge is a Bridge Pro that took over a v2 bridge through the
  app's transfer ([edge-cases-hue.md](edge-cases-hue.md), "Bridge replaced via
  the app's transfer").
- For the main bridge the transfer moves automations, accessory behaviours,
  Hue Secure settings and third-party app content ("legacy HueLabs" named as
  an example; the apps may need relinking) [verified: [hue-pro-upgrade]]. So
  any v1 rules and schedules of the old bridge are probably on the house bridge
  now [assumed].
- Whether there are any: unknown without a keyed v1 read (§9.1 H11) or the
  owner's memory of the apps he used.

### 5.5 Options for the gap

- **A. Accept it.** The report says in one line that v1 rules, v1 schedules
  and cloud automations are not covered.
- **B. One read-only v1 pass from a click.** `GET /api/<key>/rules`,
  `/schedules`, `/sensors` (CLIP types only), `/resourcelinks` and the names
  in the `/config` whitelist. The key is the one the driver already sends:
  pairing's v1 answer is stored and used as the `hue-application-key` header
  [verified: `bridge/pairing.lua`, `bridge/http.lua`]. It would be an
  exception to "CLIP v2 only" like the two the driver already makes: pairing
  (`POST /api`) and the identity check (`GET /api/0/config`,
  [bridge-compat-design.md](bridge-compat-design.md)). Never a v1 write.
- **C. The owner checks by hand** in the apps he has used.

Recommendation: A now, B if the owner agrees (§9.2 O2); the house's first run
shows whether the gap matters.

## 6. Writes

### 6.1 What `{"enabled": false}` does, per kind

| Kind | Result | In the app | Undo | Source |
| --- | --- | --- | --- | --- |
| `automation` with a toggle (Wake up, Go to sleep, Lighting schedule, Coming home, Leaving home) | Accepted; the instance stops firing | Its toggle shows off [assumed] | `{"enabled": true}` | accepted [verified: [ha-switch], [ha-switch-test] (switching off sends it), [oh-bridge-handler], [oh-16904]]; the app [assumed: Home Assistant and openHAB present `enabled` as the app's on/off, and [ha-177691] names only play/stop automations as different] |
| `automation` with play/stop (Mimic presence; Timers) | Changes a setting the app does not show, and does not stop a running instance | Nothing visible | `{"enabled": true}` | Mimic presence [community: [ha-177691]]; that timers have play and stop buttons [verified: [hue-faq-automations], read from a search engine's copy]; that the same holds for them [assumed] |
| ... the same, through `trigger` | `{"trigger":{"stop":{}}}` stops it; `start` starts it | The play/stop control follows [assumed] | `start`, which begins a new run | [verified: [aiohue-config]] |
| `accessory` (switches, dials, buttons, sensors) | Refused, or accepted with no effect | | | [community: [ha-177671]] |
| `entertainment` | The same | | | [community: [ha-177671]] |
| The MotionAware area's instance | HTTP 400 | | | [community: [ha-153935], [ha-160393]] |
| Unknown category | Unknown | | | [assumed] |

A 200 answer therefore proves nothing for accessory instances. Even for
automations the audit can re-read the flag, not see the effect.

### 6.2 Refused or never offered

- No write to scripts: openhue's PUT for one script has a body of `type` alone
  [verified: [openhue-bs]].
- `trigger` on an instance whose script has no trigger schema: refused
  [assumed: from the error text of §3.2].
- `state`, `status`, `dependees`, `migrated_from`, `script_id`: read-only
  [assumed; aiohue marks `state` read-only: [aiohue-bi]].
- Errors come back as HTTP 4xx with CLIP's `errors[]` descriptions [assumed:
  as for other resources].

### 6.3 Does the owner see it, does the app undo it?

- Nothing public says. People toggle Hue automations from outside routinely
  (one openHAB user enables or disables a child's wake-up from a nightly job,
  depending on holidays) [community: [oh-forum-trigger]], and no report found
  says the app turns them back [assumed: the absence of reports is weak
  evidence].
- The app reaches the bridge partly through Signify's cloud [community:
  [oh-forum-trigger], a developer's traffic capture]. Whether it keeps a copy
  of an automation that can overwrite a local change is unknown [assumed].
- Editing an automation in the app and saving it probably writes `enabled:
  true` again [assumed]. The audit has to notice re-enables in the stream and
  report them, never fight them.

### 6.4 Rate limits

- Nothing is documented for behaviour resources. Signify's general guidance
  (about 10 commands a second to lights, at most 1 a second to grouped lights)
  applies ([design.md, Commands and rate limiting](design.md#commands-and-rate-limiting));
  anything more specific [needs the owner to paste: Core Concepts, if it says
  more].
- The bridge answered HTTP 429 to 12 parallel GETs [community: [halo-1065]],
  and to every CLIP v2 call once more than about 10 connections were open
  [community: [ha-184767], an issue filed by an AI agent and closed].
- The audit's load: two GETs per resync, queued one at a time with the
  others; writes only from clicks, one in flight. Nothing to coalesce.

### 6.5 What cannot be restored exactly

- **`enabled`**: restored exactly by writing the remembered value. A time
  missed while it was off is not replayed [assumed].
- **`trigger` stop**: a later start begins a new run, not the old one.
- **`configuration`**: a PUT replaces the whole object (a developer writes the
  full object back to change one threshold) [community: [halo-motion],
  [halo-1065]]. The bridge validates it against a schema nobody outside Signify
  can read (§1.2); a copied configuration was refused by another bridge whose
  script differed [community: [huemanager]]; the app may keep presentation
  details elsewhere [assumed]. Not reversible with confidence: forbidden.
- **DELETE**: the id, `migrated_from` and everything that points at the
  instance (a button that starts it) are gone; a POST of a saved copy makes a
  new instance with a new id [assumed]. Forbidden.
- **Side effects of switching back on**: none known; a Coming home switched
  back on while someone is home does not fire [assumed].

### 6.6 An older note to settle

[smart-scenes-research.md](smart-scenes-research.md) §1.1 cites Signify's
Core Concepts page, as saved by the owner, as saying behaviours can only be
listed. Public code writes `enabled` with success (§6.1). Either that text
predates the writes or it means scripts [assumed]; the owner can paste the
current reference (§9.3 P1, P3).

## 7. Conflict rules (proposal)

### 7.1 What Control4 controls and owns

- **L1**: lights imported as Hue Light devices (kind light).
- **L2**: the member lights of rooms and zones imported as Hue Light devices
  (kind group, [zone-light-design.md](zone-light-design.md)).
- **L3**: the lights of rooms and zones whose scenes or time-based scenes are
  imported as Hue Scene devices.
- **T**: sensors and MotionAware areas imported as Hue Motion devices (#268,
  once it lands).

The driver cannot read Control4 programming [assumed: no API for it was found
in this research; the contract checks the SDK], so "imported" stands for
"programmed in Control4".

### 7.2 An instance's targets and triggers

1. Collect its references: `dependees[].target`, every `{rid, rtype}` in
   `configuration`, every key that is a resource id.
2. Expand targets to lights, from the caches the bridge already keeps for
   lights, devices, rooms, zones and scenes: a light is itself; a device with
   a `light` service, its lights; a room, its devices' lights; a zone, its
   lights; `bridge_home`, every light; a grouped light, its owner's lights; a
   scene, the lights of its actions; a smart scene, its group's lights; a
   `recipe` is a light state, not a target.
3. Classify the trigger: the device of a `button` or `relative_rotary`
   service (switch); `motion`, `convenience_area_motion`,
   `motion_area_configuration`, `contact`, `camera_motion` (sensor); `when` or
   `when_extended` (time); Coming home and Leaving home (presence, by
   script); scripts started only by `trigger` (Timers, Mimic presence, Go to
   sleep without a `when`).
4. An unknown script keeps its references and the kind `unknown`.

### 7.3 The rule and its severities

An instance **conflicts** when it is enabled (or started, for play/stop) and
its targets meet L1, L2 or L3, or its trigger is in T.

| Kind | Fires | Targets meet L1 or L2 | Targets meet only L3 | Trigger in T, targets elsewhere | Not enabled or not started |
| --- | --- | --- | --- | --- | --- |
| timed (Wake up, Go to sleep with a time, Lighting schedule) | on its own | high | medium | n/a | info |
| presence (Coming home, Leaving home) | on its own | high | medium | n/a | info |
| Mimic presence, while started | on its own | high, whenever L is not empty: it switches off every light it does not use | high | n/a | info |
| sensor (motion, MotionAware, contact, camera) | on its own | high | medium | medium: Hue and Control4 both act on one sensor (the motion design's R9) | info |
| manual (Timers, Go to sleep without a time) | by a person | low | low | n/a | info |
| switch (dimmer, tap dial, button, wall module) | by a person | low: shared control | low | n/a | info |
| safety (the smoke-alarm light-up) | on its own | info, wanted by default | info | n/a | info |
| entertainment (light state after streaming) | after a sync session | none | none | n/a | none |
| unknown | unknown | medium: an unknown Hue automation touches Control4 lights | low | low | info |

High findings get an `Attention` line; medium and low go into the report;
info is counted. An `errored` instance is reported as such, with its
`last_error`, not as a conflict.

### 7.4 Harmless or wanted

- A Hue switch the owner keeps on the Hue side on purpose (a bedside dimmer):
  low by default, and markable "keep on Hue side".
- Smart scene schedules started from Control4: not instances, and the owner's
  intent ([smart-scenes-design.md](smart-scenes-design.md)). A smart scene
  running that Control4 did not start: info.
- The smoke-alarm light-up: wanted by default.
- The light state after streaming: harmless.
- "Keep on Hue side" is a mark per instance, persisted by the bridge with a
  fingerprint of the instance's targets and triggers; when they change, the
  mark lapses and the finding comes back.

### 7.5 Lifecycle cases

Per CLAUDE.md, "Edge cases before automation". "Pause" and "Resume" are the
writes of §8.

| Case | Automatic | Offered (one click) | Forbidden |
| --- | --- | --- | --- |
| An instance appears (the app, the AI assistant, a firmware update) | Classify, count, log; `Attention` for high | Pause (allowed kinds); Keep on Hue side | Any write |
| An instance is edited in the app | Classify again; a "keep" mark whose fingerprint changed lapses | The same | |
| Paused by Control4, switched on again in the app | Drop the pause record; `Attention`: "turned on again in the Hue app" | Pause again | Pausing again on its own |
| Deleted in the app, or by a cascade (§1.5) | Drop it and its records; log | | |
| A new script arrives with a firmware update | Its instances are `unknown` | Keep on Hue side | Any write to it |
| A light, zone light or scene device imported in Control4 | Evaluate again | Pause | |
| One forgotten or deleted in Composer | Evaluate again; a paused instance that no longer conflicts is listed | Resume | Resuming on its own |
| Bridge restart or firmware update | Resync; the bridge's `enabled` wins over the records | | |
| Bridge replaced or migrated (new bridge id) | Records whose instance id no longer exists are dropped, with a log | | Matching instances by name |
| Control4 project restored from a backup | The bridge wins; differences with the records are reported | Resume All | Re-applying pauses from the backup |
| The bridge driver deleted or unpaired | Pauses stay on the Hue side; `Attention` names them while any exist, and the manual says to resume them first | Resume All Paused Hue Automations | |
| The key revoked (HTTP 403) | No writes; records kept | | |
| A sensor or area switched off in the app | The motion feature's rows (#268) | | Switching it on |
| A MotionAware area made Control4-only in the app (§3.5) | Its instance targets nothing: no conflict | | |

## 8. Remediation per kind

| Kind | From a click | Undo | In the Hue app (described in this note's words; unverified for the current app) | Never |
| --- | --- | --- | --- | --- |
| timed and presence automations | `{"enabled": false}`; the previous value, the time and a fingerprint remembered; the flag read back | Resume: `{"enabled": true}` | Automations tab, or the room or zone the automation controls (app 5.61 onward): switch its toggle off [verified: [hue-faq-automations], read from a search engine's copy] | Delete; rewrite the configuration; pause on its own |
| Mimic presence, while started | `{"trigger":{"stop":{}}}` | Resume: `start` (a new run) | Automations tab: its stop button [verified: [hue-faq-automations], as above] | Writing `enabled`, which the app does not show |
| Timers, while running | `stop` | None: a person starts the next one | Its stop button | The same |
| manual automations (Go to sleep without a time) | Nothing: low | | | |
| switches | Nothing: the bridge ignores it | | The switch's page among the accessories (devices, in newer apps): point its buttons elsewhere, or reset it and choose to set it up in another app | Writes to the instance; deletes |
| motion sensors | Nothing | | The sensor's settings: each time slot "Do nothing" on motion and on no motion, or hand it to another app | `motion.enabled: false`, which blinds Control4; writes to the instance |
| MotionAware area | Nothing | | The area's settings: keep its light control on and deselect every light, or set each slot to "Do nothing" both ways; never switch the area off | The area's `enabled`; its services' `enabled`; configuration writes |
| contact sensor, cameras | Nothing | | Their settings, as for motion sensors | Writes |
| smoke-alarm light-up | Nothing: wanted | | | Pausing it unless the owner says so |
| entertainment end state | Nothing | | | |
| unknown kinds | Nothing until the house shows their shape | | | Any write |
| v1 rules and schedules (if read, §5.5 B) | Nothing | | The app that made them (the whitelist names it); Hue Labs: delete all formulas under the bridge settings [verified: [hue-labs]] | v1 writes |
| cloud automations | Nothing | | The Alexa, Google Home, Apple Home or SmartThings app | |

**The exception to "no writes" it asks for.** The #268 contract's decision D7
(`docs/motion-design.md`) says the driver never changes anything on the Hue
side. This feature needs, for automations only and only if the owner agrees
(§9.2 O1): (a) `enabled` on `automation`-category instances that have a
toggle, and (b) `trigger` `stop` and `start` on started play/stop
`automation` instances. Only from a click, never from an event, a resync or a
start. Each write is logged with the previous value, remembered across
restarts, and has its Resume.

**What the owner would see** (names provisional, for the contract): a
`Hue Automations` summary property ("28 on the bridge: 3 conflicts, 2 high;
2 paused by Control4; 1 unknown kind; v1 not checked"); a `Hue Automation`
list of findings ("HIGH Wake Weekdays: Wake up, 06:30 Mon to Fri: Bedroom, 2
imported lights"); `Attention` lines for high findings and for every pause;
actions `Audit Hue Automations`, `Pause Selected Hue Automation`, `Resume
Selected Hue Automation`, `Keep Selected On Hue Side`, `Resume All Paused Hue
Automations`; and a redacted diagnostics action for the first house run (§9.1).

## 9. Open questions

### 9.1 For the house bridge (a Bridge Pro with one MotionAware area)

A diagnostics action on a prerelease build, or the dev loop, logs H1 to H6
with names, ids, MAC addresses and times redacted as the #268 research
proposes for sensors (motion research §6.4). The writes are covered by the
owner's standing approval and are undone at once.

| # | Step | Who | Settles |
| --- | --- | --- | --- |
| H1 | `GET /clip/v2/resource/behavior_script`: names, categories, ids, `max_number_instances`, `supported_features` | read-only | The catalogue on this firmware; whether MotionAware and motion sensors have scripts of their own, and their categories |
| H2 | `GET /clip/v2/resource/behavior_instance`: per instance its script, `enabled`, `status`, the keys of `state`, whether `migrated_from` is set, the rtypes of its dependees and the key paths of its configuration | read-only | The shapes; how many date from v1 |
| H3 | The area's instance (the one whose `source` is the area): its whole key structure | read-only | §3.1; what a "no lights" area looks like |
| H4 | `motion_area_configuration` and both area motion services: `enabled`, `health`, which service changed last | read-only | Which service reports on the house |
| H5 | `geofence_client`, `homekit`, `matter_fabric` | read-only | Which phones and ecosystems can drive the lights from outside |
| H6 | §7 run against today's registry, report only | read-only | How noisy the rule is |
| H7 | `{"enabled": false}` and then `true` on the area's instance | write | §3.2 on this firmware: a 400 and its text |
| H8 | On an automation the owner names: `enabled` false, the owner looks at the app, `enabled` true; the stream items of both | write, owner's eyes (a minute) | §6.1 and §6.3: whether the app's toggle follows; the event's shape |
| H9 | In the app, the area's light control on with every light deselected (or each slot "Do nothing" both ways); the owner walks through the area | owner's hands (a few minutes) | §3.3 and §3.5: whether a Control4-only area reports motion |
| H10 | The owner switches one automation off and on in the app | owner's hands | That `enabled` is the toggle; the update item |
| H11 | Keyed v1 GETs of rules, schedules, CLIP sensors, resourcelinks and the whitelist names (counts and owners only) | read-only, only if O2 allows | §5.3 on the house |
| H12 | H1 again once the app offers Custom AI Behaviors | read-only | New scripts |

### 9.2 Decisions for the owner

| # | Question | Recommendation |
| --- | --- | --- |
| O1 | Change D7 for automations: allow the two writes of §8 (`enabled` on automation toggles; `trigger` stop and start on play/stop automations), only from a click, each with its Resume? | Yes |
| O2 | The v1 gap: accept it, or allow one read-only keyed v1 pass (§5.5 B) as a third exception to "CLIP v2 only"? | Accept it for now; decide after H6 |
| O3 | The severities of §7.3: switches low, the smoke-alarm light-up wanted, Mimic presence high, unknown kinds medium? | Yes |
| O4 | The house's MotionAware area: keep Hue's own light control (quick), or make it Control4-only (H9, his hands in the app)? | His choice after H9 |
| O5 | When the audit runs: at every resync, reporting only, or only on a click? | Every resync, reporting only |
| O6 | A "keep on Hue side" mark lapses when the instance's targets or triggers change? | Yes |
| O7 | Control4 programming commands to pause and resume Hue automations (a holiday mode, say)? | Not in this feature; later, after the clicks have run on the house |

### 9.3 Pages for the owner to paste

| # | Page | Settles |
| --- | --- | --- |
| P1 | CLIP v2 API reference: `behavior_script` and `behavior_instance` (PUT semantics, partial configurations, POST, DELETE, error texts) | §6.2, §6.5 |
| P2 | The MotionAware sections: `motion_area_configuration`, and how an area's light control is created and configured | §3.2 |
| P3 | Core Concepts: its current sentence on behaviours | §6.6 |
| P4 | The Hue developer Terms of Use, the MotionAware section | Whether an integration may change an area's light control |

## 10. What it means for the code (input for the contract)

- A pure model module (scripts, instances, the reference walk of §7.2, the
  kinds and severities of §7.3) with specs on invented fixtures in the shapes
  of §1.8.
- An owner module: `GET /clip/v2/resource/behavior_script` at start and after
  a firmware change, `GET /clip/v2/resource/behavior_instance` in every
  resync, stream items of both types, the report, the actions, and the pause
  records persisted by the bridge.
- `driver.xml`: properties and actions only, no `<capabilities>` change, so an
  ordinary update with no controller reboot ([status.md](status.md), "How
  builds reach the house").
- The diagnostics of §9.1 first: H1 to H6 decide the fixtures.

## 11. Sources

All read on 2026-10-26. Code and fixtures are cited at their main or dev
branch; the projects anonymise ids, and aiohue also names, in their fixtures.

- The openhue OpenAPI description of CLIP v2 ([openhue]): [openhue-bi],
  [openhue-bs].
- aiohue, the library Home Assistant's Hue integration uses: [aiohue-bi],
  [aiohue-bs], [aiohue-config], [aiohue-button], [aiohue-sic], a Bridge Pro
  dump of July 2026 ([aiohue-fixture]), [aiohue-628].
- Home Assistant: [ha-switch], [ha-switch-test], [ha-const], its 2023 dump
  ([ha-fixture]), [ha-docs]; pull requests [ha-177671], [ha-177691],
  [ha-177643]; issues [ha-153935], [ha-160393], [ha-181632], [ha-184767];
  [ha-disc-960]; [ha-forum-trigger].
- openHAB's Hue binding: [oh-bridge-handler], [oh-16904], [oh-forum-trigger],
  and its recorded responses [oh-bs], [oh-bi], [oh-geofence], [oh-homekit],
  [oh-matter-fabric].
- Philips Hue: [hue-ma-article], [hue-faq-automations], [hue-pro-upgrade],
  [hue-labs], [hue-rn-ios], [hue-rn-android]; the public news page of the
  developer portal, [hue-dev-news].
- Other projects and reports: [hb-1087], [hb-resourcelinks], [huemanager],
  [halo-1065], [halo-motion], [reconfigo], [linkdhome], [node-hue-rule],
  [node-hue-schedules], [homey-150704], [homey-154905], [he-12815],
  [pcworld-ma], [hueblog-api-2023], [hueblog-rules], [hueblog-motion-2023],
  [hueblog-iconnect-ma], [hueblog-ai-0905], [hueblog-ai-1023], [iconnect-515],
  [notebookcheck-561].
- This repository: [design.md](design.md),
  [smart-scenes-research.md](smart-scenes-research.md),
  [smart-scenes-design.md](smart-scenes-design.md),
  [zone-light-design.md](zone-light-design.md),
  [edge-cases-hue.md](edge-cases-hue.md),
  [edge-cases-ux.md](edge-cases-ux.md) (the policy rules this note follows),
  [bridge-compat-design.md](bridge-compat-design.md), [status.md](status.md),
  `src/hue_bridge/bridge/pairing.lua`, `src/hue_bridge/bridge/http.lua`; and on
  the #268 branch `docs/motion-hue-research.md` (cited as "motion research")
  and `docs/motion-design.md`.

[openhue]: https://github.com/openhue/openhue-api
[openhue-bi]: https://github.com/openhue/openhue-api/tree/main/src/behavior_instance
[openhue-bs]: https://github.com/openhue/openhue-api/tree/main/src/behavior_script
[aiohue-bi]: https://github.com/home-assistant-libs/aiohue/blob/main/aiohue/v2/models/behavior_instance.py
[aiohue-bs]: https://github.com/home-assistant-libs/aiohue/blob/main/aiohue/v2/models/behavior_script.py
[aiohue-config]: https://github.com/home-assistant-libs/aiohue/blob/main/aiohue/v2/controllers/config.py
[aiohue-button]: https://github.com/home-assistant-libs/aiohue/blob/main/aiohue/v2/models/button.py
[aiohue-sic]: https://github.com/home-assistant-libs/aiohue/blob/main/aiohue/v2/models/switch_input_configuration.py
[aiohue-fixture]: https://github.com/home-assistant-libs/aiohue/blob/main/tests/fixtures/v2_resources.json
[aiohue-628]: https://github.com/home-assistant-libs/aiohue/issues/628
[ha-switch]: https://github.com/home-assistant/core/blob/dev/homeassistant/components/hue/switch.py
[ha-switch-test]: https://github.com/home-assistant/core/blob/dev/tests/components/hue/test_switch.py
[ha-const]: https://github.com/home-assistant/core/blob/dev/tests/components/hue/const.py
[ha-fixture]: https://github.com/home-assistant/core/blob/dev/tests/components/hue/fixtures/v2_resources.json
[ha-docs]: https://www.home-assistant.io/integrations/hue/
[ha-177671]: https://github.com/home-assistant/core/pull/177671
[ha-177691]: https://github.com/home-assistant/core/pull/177691
[ha-177643]: https://github.com/home-assistant/core/pull/177643
[ha-153935]: https://github.com/home-assistant/core/issues/153935
[ha-160393]: https://github.com/home-assistant/core/issues/160393
[ha-181632]: https://github.com/home-assistant/core/issues/181632
[ha-184767]: https://github.com/home-assistant/core/issues/184767
[ha-disc-960]: https://github.com/orgs/home-assistant/discussions/960
[ha-forum-trigger]: https://community.home-assistant.io/t/how-to-trigger-a-pre-configured-philips-hue-automation/841417
[oh-bridge-handler]: https://github.com/openhab/openhab-addons/blob/main/bundles/org.openhab.binding.hue/src/main/java/org/openhab/binding/hue/internal/handler/Clip2BridgeHandler.java
[oh-16904]: https://github.com/openhab/openhab-addons/issues/16904
[oh-forum-trigger]: https://community.openhab.org/t/trigger-hue-automations-from-openhab/161617
[oh-bs]: https://github.com/openhab/openhab-addons/blob/main/bundles/org.openhab.binding.hue/src/test/resources/behavior_script.json
[oh-bi]: https://github.com/openhab/openhab-addons/blob/main/bundles/org.openhab.binding.hue/src/test/resources/behavior_instance.json
[oh-geofence]: https://github.com/openhab/openhab-addons/blob/main/bundles/org.openhab.binding.hue/src/test/resources/geofence_client.json
[oh-homekit]: https://github.com/openhab/openhab-addons/blob/main/bundles/org.openhab.binding.hue/src/test/resources/homekit.json
[oh-matter-fabric]: https://github.com/openhab/openhab-addons/blob/main/bundles/org.openhab.binding.hue/src/test/resources/matter_fabric.json
[hue-ma-article]: https://www.philips-hue.com/en-us/support/article/motionawaretm--transform-your-hue-lights-into-motion-sensors/000011
[hue-faq-automations]: https://www.philips-hue.com/en-us/support/topic/automations/100061
[hue-pro-upgrade]: https://www.philips-hue.com/en-us/support/article/how-to-upgrade-to-the-hue-bridge-pro/000010
[hue-labs]: https://www.philips-hue.com/en-us/support/article/huelabs/000003
[hue-rn-ios]: https://www.philips-hue.com/en-us/support/release-notes/ios
[hue-rn-android]: https://www.philips-hue.com/en-gb/support/release-notes/android
[hue-dev-news]: https://developers.meethue.com/
[hb-1087]: https://github.com/ebaauw/homebridge-hue/issues/1087
[hb-resourcelinks]: https://github.com/ebaauw/homebridge-hue/wiki/Resource-Links
[huemanager]: https://github.com/albaintor/huemanager
[halo-1065]: https://github.com/eetu/halo/pull/1065
[halo-motion]: https://github.com/eetu/halo/blob/main/backend/src/hue/motion.rs
[reconfigo]: https://github.com/tommyzacek/hue-reconfigo
[linkdhome]: https://linkdhome.com/articles/2017/11/9/how-to-configure-hue-switches-for-homekit
[node-hue-rule]: https://github.com/peter-murray/node-hue-api/blob/master/docs/rule.md
[node-hue-schedules]: https://github.com/peter-murray/node-hue-api/blob/master/docs/schedules.md
[homey-150704]: https://community.homey.app/t/hue-motion-aware/150704
[homey-154905]: https://community.homey.app/t/motion-aware/154905
[he-12815]: https://community.hueessentials.com/t/hue-bridge-pro-motion-area-do-not-disturb-bug/12815
[pcworld-ma]: https://www.pcworld.com/article/2957900/philips-hue-turned-my-lights-into-motion-sensors-its-magical-but-imperfect.html
[hueblog-api-2023]: https://hueblog.com/2023/10/02/philips-hue-api-many-possibilities-remain-unused/
[hueblog-rules]: https://hueblog.com/2025/12/16/hue-bridge-pro-a-detailed-explanation-of-the-rule-limit/
[hueblog-motion-2023]: https://hueblog.com/2023/08/08/hue-motion-sensor-now-with-10-time-slots-and-natural-light/
[hueblog-iconnect-ma]: https://hueblog.com/2026/05/25/iconnecthue-now-supports-motionaware-zones/
[hueblog-ai-0905]: https://hueblog.com/2026/09/05/custom-ai-behaviors-more-exciting-than-i-originally-thought/
[hueblog-ai-1023]: https://hueblog.com/2026/10/23/hue-bridge-pro-is-being-prepared-for-custom-ai-behaviors/
[iconnect-515]: https://iconnecthue.com/iconnecthue-5-15-motion-area-support/
[notebookcheck-561]: https://www.notebookcheck.net/Philips-Hue-app-update-officially-adds-new-Automations-feature.1229299.0.html
