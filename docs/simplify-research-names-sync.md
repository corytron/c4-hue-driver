# Simplify research: two-way names (D6, #334)

Research file for the owner's answer D6 in [the simplification contract](simplify-actions-design.md)
(§1.8): a rename in Composer renames the thing on the Hue bridge, a rename in
Hue renames the Control4 device, for lights, scenes and motion sensors, not
rooms. Read-only research, 2026-11-05, against `main` = beta 7 (build 425).
CLAUDE.md's "edge cases before automation" applies: every corner case below
is decided before any code.

Sources: **IMP** [simplify-research-import.md](simplify-research-import.md) (its C2, H3, S2 and
E-numbers), **CMP** [simplify-research-compat.md](simplify-research-compat.md), **C4**
[edge-cases-control4.md](edge-cases-control4.md), **HUE** [edge-cases-hue.md](edge-cases-hue.md),
**UX** [edge-cases-ux.md](edge-cases-ux.md), **EM** [edge-cases-motion.md](edge-cases-motion.md),
**HR** [motion-hue-research.md](motion-hue-research.md); **API** is
`~/c4-tools/reference/docs-driverworks-api/source/includes/`. Marks: **V**
verified (code, spec, SDK doc or hardware report), **C** community (a public
library reproducing Signify's schema; the full Hue reference is login-walled),
**A** assumed.

## 1. Findings

1. **Sync needs a remembered pair per device, not today's comparison.** The
   Composer name is derived from the Hue name (a zone scene gets the zone in
   front, a time-based scene loses the app's number, a light takes its Hue
   *device's* name, every name is cleaned by `util.display_name`), so
   comparing "expected" with "current" cannot tell who renamed, and pushing
   one side to the other can loop (E6, E8). One persisted pair per device,
   the last names both sides agreed on, answers who changed, absorbs both
   echoes and lets a startup pass catch what happened while the driver was
   not watching. It is a new key; no stored record changes shape (E17).
2. **Both detection paths exist already.** A Composer rename fires
   `OnItemNameChanged` with the **proxy** id, verified on OS 3.4.2 (E1); the
   bridge registers it but only refreshes its rows, and ignores it before
   late init (E2). Hue renames already update the registries from events and
   resyncs, each logging "Composer name unchanged" (E7). Missing: a map from
   proxy id to entry for devices adopted by Link Devices or a hello, which
   have no `proxy_id` (E5).
3. **What Hue lets the driver write.** A device's `metadata.name`, 1-32
   characters (C, E9): the name of a single-light lamp and of a motion
   sensor. A scene's and a time-based scene's `metadata.name`, 1-32 (C; the
   time-based PUT verified on the house, E11). A light's own name: in no
   community schema, yet the house bridge took it (E10). A MotionAware
   area's `name`: the two libraries disagree (A, E12). Duplicate scene names
   in one room: no source either way (A, E13).
4. **Zone lights count as rooms and stay out of the sync.** Their Hue name
   is a room's or zone's name; writing it renames a Hue room, which the
   owner excluded, and a zone rename changes every zone scene's Composer name
   too (§2).
5. **"Control4 wins" and "never out of sync" agree wherever a pair exists.**
   Both-sides-renamed resolves to the Composer name, converges, and says
   which Hue name it replaced. They only collide where no agreed pair exists
   (the first run after the update, a re-added bridge driver, a restored
   project): those differences are **offered**, in line with compat rule R5
   ("what was a click does not start by itself after the update").
6. **Cheap in requests, not free in Composer.** One PUT per Composer rename,
   none per Hue rename. But every `RenameDevice` refreshes the project (E3),
   so Hue-to-Composer renames are paced (one per 2 s) and a large batch found
   at once (a restore, a bridge reset) is held and offered, not applied.
7. **Motion's "never write" rule has to change, for names only.**
   `motion.lua`, motion-design D7 and EM rule 6 forbid any PUT (E15); D6
   needs `PUT /device` for sensors and, if a one-minute test passes, the
   area's name.
8. **Resolve Names survives, small.** It handles only pairs that cannot sync
   by themselves: the first sync after the update, names Hue refuses,
   batches the bulk guard held, shared name sources and zone lights. Adopt
   Hue Names merges into it; Accept Names As They Are and both children's
   Adopt Hue Name retire (§6).
9. **Five one-minute tests on the house settle every assumption that
   matters** (§8), all in D9's dev build, before any code.

## 2. What "the name" is, per kind

| Kind | Control4 name (creation rule) | Hue name carried by | Writable | Today's code |
| --- | --- | --- | --- | --- |
| Hue Light, only light of its Hue device (all 47 on the house) | the Hue device's name (`lights.lua:1153`) | `device.metadata.name`; the light's own `metadata.name` also "agrees" (`lights.lua:1395`) | `PUT /device/<device_rid>` (C, E9) | reads: `on_device_item` (`lights.lua:1058-1080`), `take_name` (`:697`, `:1017`); writes Composer only via Adopt (`owner.lua:1239`) |
| Hue Light on a multi-light device | the light's own name | `light.metadata.name` | `PUT /light/<rid>` took on the house, deprecated (E10) | as above |
| Zone light of a room | "<Room> Lights" (`zone_lights.lua:387`) | `room.metadata.name` | yes, but a room | `take_name` (`zone_lights.lua:413`) |
| Zone light of a zone | the zone's name | `zone.metadata.name` | yes, but a group | as above |
| Hue Scene in a room | the scene's name (`scenes.lua:490`) | `scene.metadata.name` | `PUT /scene/<rid>` (C, E9) | `take_name` (`scenes.lua:672`) |
| Hue Scene in a zone | "<Zone> <Scene>" | `scene.metadata.name` (the prefix is the zone's) | as above | as above |
| Time-based scene | its base name, the app's trailing number dropped (`scenes.lua:252`, `hue_model.lua:773`) | `smart_scene.metadata.name` | `PUT /smart_scene/<rid>` → 200 on the house (V, E11) | as above |
| Hue Motion, sensor | the sensor's Hue name (`motion.lua:716-723`) | `device.metadata.name` (the services carry none, EM §0.1) | `PUT /device/<rid>` (C, HR §4.1) | `refresh_entry` (`motion.lua:784-788`) |
| Hue Motion, MotionAware area | the area's name, else "MotionAware area #tag" | `motion_area_configuration.name` (`motion_model.lua:466`) | contested (A, E12) | as above |

The Composer name is always the **proxy's** (Composer shows and renames the
proxy, API `22_miscellaneous/_32-RenameDevice.md`); no other proxy name
exists for these drivers. The children's `Hue Name` / `Hue Scene` rows show
the Hue side (`hue_light/driver.lua:516`, `hue_motion/driver.lua:393`).

**Zone lights are "rooms" for D6.** Reasons: (1) their Hue thing is a room
or zone, so a Composer-to-Hue write renames a Hue room, exactly what the
owner excluded; (2) a zone's name is also the prefix of every zone scene's
Composer name and the label of the room mappings and the MotionAware areas'
rooms, so one sync would cascade; (3) a room device's Composer name is
"<Room> Lights" by design, never the Hue name, so writing back means
guessing a suffix. They keep today's behaviour: a difference is listed and
offered (Resolve Names). Alternative, not recommended: Hue to Composer only,
which still changes a device name because someone renamed a room.

## 3. Detection

### 3.1 A rename in Composer

- `OnItemNameChanged` arrives as a c4soap string with `iditem` (the proxy
  id), `name`, `itemtype` 7 and `idroom`, within seconds (V, E1). No
  `OnBindingChanged` comes with it (V, same report).
- Today `OnSystemEvent` only refreshes the rows, and only after late init
  (`driver.lua:2197-2205`). Change: read `iditem` only, look the entry up in
  a proxy-id map built from all three registries, and read the new name with
  `GetDeviceDisplayName(iditem)` (API `32_serial_network_device/_6-GetDeviceDisplayName.md`)
  instead of parsing the XML-escaped `name`. Unknown ids (rooms, other
  drivers' devices, our bridge) are ignored.
- **Proxy ids.** Only devices made by AddDevice carry `proxy_id`
  (`owner.lua:1039`); an adopted device has none, so its rename cannot be
  mapped, and today's comparison reads the *protocol* device's name
  (`owner.lua:1226`), which Composer does not rename (A, C4 row 1.5). Fill
  the existing field at reconcile with `GetBoundConsumerDevices(device_id,
  5001)`, the call each child already uses for its own proxy
  (`common/device.lua:255`; API `32_serial_network_device/_3`).
- **Missed events.** Before late init, during a driver update or a Director
  restart, the event is lost or ignored. Composer cannot rename without
  Director, so the gap is seconds, but the startup pass (3.3) covers it, and
  the 5-minute row tick (`driver.lua:2293`) repeats the Composer side with
  local reads only.
- **Our own `RenameDevice`** probably comes back as `OnItemNameChanged` (A,
  E22); the pair makes that harmless (rule 5.1, row N6).

### 3.2 A rename in Hue

- Stream `update` items: `device` `metadata.name` (single-light lamps,
  sensors), `light`, `scene`, `smart_scene` (one update event, V E11),
  `motion_area_configuration` `name` (A, HR §3.5). All four modules already
  absorb them (E7).
- Whether a device rename also updates the light's own `metadata.name`, and
  in which order, was never probed (HUE §9 test 2; [import-design.md](import-design.md) §11 probe 9).
  The rule absorbs either: both arrive within a second and coalesce per
  entry.
- Anything renamed while the stream was down is read by the resync after
  every connect (IMP E20), and by the housekeeping reads of the contract
  (§1.3: 6 h quick, 24 h full).

### 3.3 The startup reconciliation rule

At late init the pairs load with the registries. The Composer side can be
read at once (local calls); the Hue side only after that module's **first
resync of this run**, because cached names may be hours old and the lights'
creation name falls back to the light's own name until devices are read
(`lights.lua:1382-1399`). So:

1. Late init: note Composer names that differ from their pair; send nothing.
2. After each module's first resync: one pass over its linked entries with
   the rule of 5.1, Hue and Composer side together, under the bulk guard
   (N10). Pushes go out through the paced queue (5.4).
3. Afterwards: live events per entry; the same pass after every later
   resync; the Composer side again on the 5-minute tick.

## 4. Edge cases

Classes: **auto** (automatic), **offered** (the driver proposes, one click
in Resolve Names accepts), **click** (forbidden without a click). "Pair" is
the stored agreed names of 5.3; g() is the Hue name a Composer name maps to,
f() the Composer name a Hue name maps to (5.2).

| # | Case | Side | Detection | Proposed behaviour | Class | Why |
| --- | --- | --- | --- | --- | --- | --- |
| N1 | Light, scene or sensor renamed in Composer | C4 | `OnItemNameChanged` (E1); startup pass | PUT g(name) to Hue; pair updated on success | auto | D6; Control4 is the source |
| N2 | Renamed in the Hue app | Hue | stream update; resync | `RenameDevice(proxy, f(name))`, paced; pair updated | auto | D6 |
| N3 | Both renamed before the driver saw either (stream down, Director restart) | both | startup or reconnect pass: both differ from the pair | Composer name wins: PUT g(Composer name); Last Action names the Hue name it replaced. If the two now agree in form, only the pair is updated | auto | the owner's rule; converges; the lost Hue name is visible |
| N4 | Hue refuses the name (over 32 characters, characters it rejects, a duplicate scene name in the group) | Hue | PUT answer 400 with Hue's error text (A: shape) | Pair **held**; Attention gives Hue's reason; Resolve Names offers "Hue name to Composer" or "cut to 32 characters in Hue". Length pre-checked locally, so no request is wasted | offered | a cut name nobody typed is a surprise; the owner shortens or chooses |
| N5 | Echo of our own PUT (the update event) | Hue | event name equals the pair's `push` | absorbed: the pair takes it, nothing else | auto | the loop breaks at the first turn |
| N6 | Echo of our own RenameDevice | C4 | event name equals the pair's Composer name, written before the call | absorbed | auto | as N5 |
| N7 | A side stores something other than what we sent (trimmed, normalised) | both | the first answer for that entry within 10 s of our write | taken as the echo whatever its text; no counter-write. Loop breaker: more than 3 automatic writes for one device in 10 minutes holds the pair, Attention "names of X keep changing" | auto, then offered | no ping-pong can outlive two turns |
| N8 | Burst of Composer renames (an installer renaming 20 devices) | C4 | one event each | queued, latest per device wins, one PUT a second, never within 1.5 s of a user command | auto | each is a person's act; pacing keeps lights first |
| N9 | Burst of Hue renames (a script, an app) | Hue | many updates | coalesced; one RenameDevice per 2 s; past 10 in a minute the rest are held | auto, then offered | each rename refreshes the project (E3) |
| N10 | More than 5 differences found in one pass (Hue backup restored, bridge reset, project restored) | both | startup or resync pass | nothing applied; all held; Attention "12 names changed while the driver was not watching (Resolve Names)" | offered | a mass change that nobody typed is not a rename |
| N11 | Renamed in Composer while the bridge is offline, the key rejected or the identity unchecked | C4 | event | the name waits in the pair (`push`, persisted); Attention after 10 minutes "2 renames wait for the bridge"; sent after the next successful resync, then N3 | auto | a restart must not lose it |
| N12 | Renamed in Hue while Director, the driver or the stream was down | Hue | the resync after connect | as N2 (N10 if many) | auto | detection by pair, not by event |
| N13 | Renamed in Composer while its Hue thing is gone | C4 | event | pair's Composer name updated; nothing sent; at re-link N16 sends it | auto | nothing to rename on the bridge |
| N14 | Renamed while unbound, forgotten, or a hand-added device not yet linked | C4 | event | ignored until it is linked again (then the pass decides) | auto | not ours to push |
| N15 | One rid claimed by two devices, or one Hue name feeding two devices (a light and a sensor on one Hue device) | both | conflict list; two entries with one name source | no sync either way; listed in Resolve Names | offered | a rename would rename the other device too |
| N16 | Re-linked (Link Device click, or D7's automatic MAC match) | both | the relink (`owner.lua:1446`) | the Hue thing takes the Composer name (PUT g(name)); the pair moves to the new rid; said in the relink's Last Action | auto (follows the click or D7) | the device and its name are Control4's; after a bridge reset Hue gets its names back |
| N17 | Imported (AddDevice) | C4 | the callback | pair seeded from the Hue name and the name Composer actually shows (read back) | auto | no first-sync offer for new devices |
| N18 | Project restored from a backup with old names | C4 | the pass: Composer differs from the pair (store not restored) or Hue differs (store restored, E20) | caught by N10 when more than 5; fewer follow the rule (N1/N2) | offered / auto | either way nothing silent happens in bulk |
| N19 | Driver updated in place; names already differ | both | first run of the new build (migration flag, CMP R4) | pairs that agree in form are seeded silently; the rest, accepted ones (`name_dismissed`) included, are held; Attention "N names differ between Composer and Hue (Resolve Names)", whose first row is "Composer names to Hue" | offered | CMP R5; an accepted difference was a choice under the old rules |
| N20 | Bridge driver deleted and re-added (empty store) | both | no pairs, no flag | as N19 | offered | same |
| N21 | Rollback to beta 7 and back | both | the key survives unread | renames made under beta 7 are judged against the old pairs (correct by 5.1); N10 guards a large set | auto | new key only (CMP R3) |
| N22 | The Hue app renames a room's lights one by one | Hue | live updates | N2 each; N9 if fast | auto | |
| N23 | Hue room or zone renamed | Hue | room/zone update | not synced (rooms excluded); a zone scene's Composer name keeps its old prefix, since its pair holds the scene's own name; zone light listed in Resolve Names | offered | D6 excludes rooms |
| N24 | Hue name with control characters, edge blanks, commas, quotes or emoji | Hue | event | Composer gets `display_name` (E8); the pair keeps Hue's raw text, so no loop; commas stay in device names (only list rows replace them) | auto | the cleaning is idempotent |
| N25 | Composer name Hue cannot hold (33+ characters; 32 may count bytes, A E14) | C4 | local check, else Hue's answer | N4 | offered | |
| N26 | Sensor renamed (name on the Hue device, one Control4 device per sensor) | both | device update | `PUT /device/<sensor rid>`; the light-level and temperature services carry no name (EM §0.1) | auto | one-to-one |
| N27 | MotionAware area renamed (one Control4 device per area) | both | configuration update | Hue to Composer auto; Composer to Hue only if T3 passes, else held with "Hue does not take area names from Control4" | auto / offered | E12 |
| N28 | Scene deleted and re-made in Hue under the same name | Hue | delete + add | old entry gone; Link Device suggests the new one (IMP S4); at re-link N16 (names usually equal) | offered | |
| N29 | Two Control4 devices with one name | C4 | — | sent as is; lights and sensors may share names in Hue (V, EM S11); a duplicate scene name in one group may be refused (N4) | auto | |
| N30 | Composer name carries a room prefix by habit ("Kitchen Pendant", Hue "Pendant") | C4 | the pair's form (5.2) | the prefix stays on the Composer side: Hue keeps "Pendant", a Hue rename to "Island" gives "Kitchen Island" | auto once paired | the Hue app shows the room; 32 characters go further |
| N31 | Light on a multi-light device renamed in Composer | C4 | event | `PUT /light/<rid>` if T1 confirms it renames only that light; else held | auto / offered | E10 |
| N32 | Time-based scene "Golden hours 4" (Composer "Golden hours") renamed in Composer to "Evening" | C4 | event | Hue gets "Evening" (the app's number goes); a later Hue name "Evening 2" gives Composer "Evening" (base name) | auto | the existing creation rule (smart-scenes Decision 7) |
| N33 | Two Control4 projects (or a copied project) on one bridge | both | — | each syncs; they converge; N7 caps a fight | auto | IMP P4, P5 |
| N34 | Bridge itself or a Control4 room renamed | C4 | event for an unmapped id | ignored | — | not a light, scene or sensor |

## 5. The rules and the state

### 5.1 One rule per device

For a linked entry with a pair (`h` Hue name agreed, `c` Composer name
agreed), the current Hue name `H` (fresh this run) and Composer name `C`:

| Hue changed (`H` ≠ `h`, not our pending push) | Composer changed (`C` ≠ `c`) | Action |
| --- | --- | --- |
| no | no | nothing |
| no | yes | PUT g(`C`); pair = (g(`C`), `C`) once Hue answers |
| yes | no | RenameDevice f(`H`); pair = (`H`, f(`H`)) set before the call |
| yes | yes | `C` agrees with f(`H`): pair updated only; else PUT g(`C`) (Control4 wins) |

A pair that is **held** (no agreed names yet, refused, bulk-held, shared
source) syncs nothing until Resolve Names answers it, with one exception: a
Composer rename of a held device is an explicit act and resolves it
(Control4 wins). A Hue rename of a held device only updates its row.

### 5.2 The forms (f and g)

Seeded with the pair, the form says how the two names relate; f and g are
inverse by construction and only ever compared with the stored pair, never
recomputed against each other, which is what keeps the time-based scene's
lossy base name from looping.

- **Same**: f(h) = display_name(h), g(c) = c.
- **Zone scene**: f(h) = "<Zone> " .. h; g(c) = c without a leading
  "<Zone> " when present, else c.
- **Time-based scene**: f(h) = base name of h (plus the zone prefix);
  g(c) = c.
- **Owner affix** (N30): c = P .. f(h) .. S at seeding, P or S not empty;
  then f(h') = P .. f(h') .. S, and g(c') = the middle while c' still starts
  with P and ends with S, else c' whole (the affix is dropped).
- Anything else is "unrelated": held at the first sync (N19).

### 5.3 Minimum new state

One new persisted key, never new fields in `hue_lights`, `hue_scenes` or
`hue_motion` (their schema drops unknown fields, `registry.lua:34-45`; CMP
R3):

```
hue_name_pairs = { v = 1, seeded_build = <build>,
  pairs = { ["light:<rid>"] = { h = "Desk lamp", c = "Desk Lamp", pre = nil, post = nil,
                               push = nil, held = nil, at = 1762300000 }, ... } }
```

- `push`: a name waiting for the bridge (N11); `held`: why it waits for
  Resolve Names ("first", "refused: <Hue text>", "bulk", "shared", "loop").
- Moved under the new rid at relink, dropped at forget and tombstone,
  written after each batch like the registries.
- `seeded_build` is the migration flag of N19 (CMP R4): absent means first
  sync. About 60 bytes a device, 4 KB on the house.
- In memory only: the proxy-id map, the echo window (N7) and the write
  counter of the loop breaker. `proxy_id` is filled in the existing
  registry field (`registry.lua:74`), not a new one.

### 5.4 Cost and pacing

- **Composer to Hue:** one PUT per rename (two for a single-light lamp only
  if T1 shows the light's own name does not follow its device). REST goes
  through `C4:url`, one transfer per host at a time (`commands.lua:1-20`,
  [design.md](design.md) "C4:url transfer scheduling"), so name PUTs run one
  at a time, at most one a second, never within 1.5 s of a user command (the
  scheduler research's rule). They follow a person's act, so they are
  outside the 60-an-hour optional budget of the contract's §1.3; the bulk
  guard bounds them instead. Worst case, 47 lamps re-linked after a bridge
  reset: about 50 s.
- **Hue to Composer:** no bridge request; one `RenameDevice` each, one per
  2 s, never in OnDriverInit (E3). Each refreshes the project, whose cost on
  OS 3.4.2 with Composer open is unmeasured (T4 watches it).
- **Passes:** no extra GET (they ride the resyncs that already run); one
  local `GetDeviceDisplayName` per device, which Attention already makes every
  5 minutes (`owner.lua:1212-1234`).

### 5.5 What Last Action and Attention say

- Last Action, one line per automatic rename, joined in a burst: "Name sent
  to Hue: Reading Lamp (was Desk lamp in Hue)"; "Name taken from Hue: Office
  Lamp (device 1213, was Desk Lamp)"; N3: "Both renamed: kept the Composer
  name Reading Lamp and sent it to Hue (Hue had Office lamp)".
- Attention, only for what needs a person, each ending in the action that
  settles it: "2 renames wait for the bridge: Reading Lamp, Relax";
  "1 name Hue refused: Kitchen Under-Cabinet Left Strip (34 characters, Hue
  takes 32) (Resolve Names)"; "12 names differ between Composer and Hue
  (Resolve Names)". Today's "N Hue names differ … (Adopt Hue Names or Accept
  Names As They Are)" item (`owner.lua:1356-1364`) becomes the last one.
- Debug Mode logs every pass, echo and skip (D4: no switch, the log shows
  what ran).

## 6. Verdicts

| Action | Verdict | Reason |
| --- | --- | --- |
| Adopt Hue Names | **MERGE into Resolve Names** | its "Hue names to Composer (all N)" row, for held pairs only; every other Hue rename is automatic (N2) |
| Accept Names As They Are | **RETIRE** | "keep both as they are" is the drift D6 rules out; the pair replaces its memory, and its old `name_dismissed` is read once, to hold those devices at the first sync (N19). Its hidden alias (CMP R2) points to Resolve Names and writes nothing |
| Hue Light: Adopt Hue Name | **RETIRE** | D3; the sync does it, and a held device has its own row in Resolve Names, which needs no pairing for a Composer-side row, as the child's action did not (`hue_light/driver.lua:590-602`) |
| Hue Scene: Adopt Hue Name | **RETIRE** | as for the light (`hue_scene/driver.lua:1091-1109`) |
| Resolve Names (proposed, contract §1.2 action 6) | **OFFERED** | still needed for held pairs only (N4, N10, N15, N19, N20, zone lights). Reached from Attention's "(Resolve Names)". One param: "Composer names to Hue (all N)" first, "Hue names to Composer (all N)", then two rows per device, a refused one with "cut to 32 characters in Hue" |
| Names From Hue (Ask / Follow), contract §1.4 | **RETIRE** (never built) | D6 replaced it |

## 7. Risks and open questions for the owner

Each has a recommended answer; one word decides it.

| # | Question | Recommended |
| --- | --- | --- |
| Q1 | At the update (and after a re-added bridge driver), names that already differ are **offered** in Resolve Names with "Composer names to Hue" first, not pushed by themselves? | yes |
| Q2 | Zone lights count as rooms: no automatic sync, differences stay in Resolve Names? | yes |
| Q3 | A name Hue refuses is never cut by itself: Attention, plus a "cut to 32" row? | yes |
| Q4 | A room prefix typed in Composer stays on the Composer side only (N30)? | yes |
| Q5 | More than 5 changes found in one pass are held and offered (N10)? | yes |
| Q6 | A re-link, by click or D7's MAC match, gives the Hue thing the Composer name (N16)? | yes |
| Q7 | Lift motion's "no writes" (motion-design D7, EM rule 6) for names only? | yes |
| Q8 | A Hue rename of a held device waits for Resolve Names instead of overwriting a Composer name that never agreed (5.1)? | yes |
| Q9 | Run the tests of §8 in D9's dev build before any code? | yes |

Risks without a question:

- **The family sees names move.** A Composer rename now shows up in the Hue
  app, and a Hue rename in Navigator and in anything that reads Control4
  names. Programming refers to devices, not names (A), so nothing breaks.
- **Project refreshes.** Composer reloads after each `RenameDevice` (E3);
  pacing and the bulk guard bound it, but its cost with Composer open on OS
  3.4.2 is unmeasured.
- **Area names** may not be writable (E12); then areas sync one way only.
- **A project backup's persisted values** (E20) are not tested, and the test
  is too long for the "no long test waits" rule. N10 covers both outcomes.

## 8. One-minute tests on the house (D9's dev build, through the Windows session and `tools/devctl.py`)

Each renames one throwaway-named thing and back, needs no reboot, and is
covered by the standing approval. The dev-loop commands are those of
[dev-loop.md](dev-loop.md).

| # | Test | Settles |
| --- | --- | --- |
| T1 | `Hue Request` PUT `/clip/v2/resource/device/<rid>` `{"metadata":{"name":"Test 1"}}` on a single-light lamp, Debug Mode on | which updates arrive (device, light, order); whether the light's own name follows (§2, N31) |
| T2 | PUT a scene's `metadata.name` to the name of another scene of the same room, then to 33 characters, then to 32 "é" | duplicate rule, the error shape, characters or bytes (N4, N25, E13, E14) |
| T3 | PUT `/motion_area_configuration/<rid>` `{"name":"Test area"}` on the house's one area | whether areas take a name (N27, E12) |
| T4 | `Probe Call` RenameDevice on a light's proxy with a 45-character name holding an emoji | whether our rename comes back as `OnItemNameChanged` (E22); what Composer keeps; the refresh's cost |
| T5 | Windows session renames an adopted device (no `proxy_id`) in Composer | the proxy lookup of 3.1; what `GetDeviceDisplayName(protocol id)` returns after it (E5) |

## 9. Evidence

- **E1 V** `OnItemNameChanged` data: `iditem` = proxy id, `name`, `itemtype` 7, `idroom`; Attention updated three seconds later (hardware 2026-10-21, `docs/design.md:1134-1144`).
- **E2 V** The bridge registers it with five other probe events and on it only refreshes rows, after late init only (`src/hue_bridge/driver.lua:2177-2205`); the specs fake it (`tests/spec/roundtrip_spec.lua:171-185`, `tests/spec/drivers_spec.lua:1467`).
- **E3 V** `RenameDevice` takes a proxy or device id, refreshes the project, works from late init, not in OnDriverInit (API `22_miscellaneous/_32-RenameDevice.md`). The OnItem events replace the deprecated OnProjectChanged (API `7_event/_1-RegisteringforSystemEvents.md`); their payloads are undocumented (C4, event ids row).
- **E5 V/A** `proxy_id` comes only from the AddDevice callback (`owner.lua:1039`); Adopt Hue Names skips entries without it (`owner.lua:1247`) and the comparison falls back to the protocol id (`owner.lua:1226`). **A:** the protocol device keeps its old name after a Composer rename (C4 row 1.5).
- **E6 V** The expected names: lights `lights.lua:1153`, `:1395` (#236); scenes `scenes.lua:252`, `:490`; base name `hue_model.lua:773`; zone lights `zone_lights.lua:387`; motion `motion.lua:716-723`; the child's own rules `hue_light/driver.lua:581-586`, `hue_scene/driver.lua:1099-1106` (#94).
- **E7 V** Hue renames reach the registries: `lights.lua:697`, `:1017`, `:1058-1080` (#87); `scenes.lua:672-680`; `zone_lights.lua:413-421`; `motion.lua:784-788`.
- **E8 V** `util.display_name`: control characters out, trimmed, at most 100 characters, idempotent (`util.lua:47-120`); all name comparisons use it (`owner.lua:1180-1234`).
- **E9 C** Device PUT `metadata.name` 1-32 ([openhue DevicePut](https://github.com/openhue/openhue-api/blob/main/src/device/schemas/DevicePut.yaml)); scene and smart-scene `metadata.name` 1-32 ([SceneMetadata](https://github.com/openhue/openhue-api/blob/main/src/scene/schemas/SceneMetadata.yaml), [SmartSceneMetadata](https://github.com/openhue/openhue-api/blob/main/src/smart_scene/schemas/SmartSceneMetadata.yaml)); aiohue's ScenePut and SmartScenePut carry `metadata` ([scene.py](https://github.com/home-assistant-libs/aiohue/blob/main/aiohue/v2/models/scene.py)).
- **E10 V/C** Neither [openhue LightPut](https://github.com/openhue/openhue-api/blob/main/src/light/schemas/LightPut.yaml) nor aiohue's LightPut has `metadata`, yet `PUT /light/<id>` `{"metadata":{"name":"X"}}` on the house bridge produced one event per call (`docs/dev-loop.md:710-714`); whether it renamed the device too is not recorded.
- **E11 V** `PUT /smart_scene` with `metadata.name` → 200 and one update event on the house ([smart-scenes-research.md](smart-scenes-research.md) §7, V13).
- **E12 C/A** aiohue's MotionAreaConfigurationPut has `name` ([motion_area_configuration.py](https://github.com/home-assistant-libs/aiohue/blob/main/aiohue/v2/models/motion_area_configuration.py)); openhue's has only `enabled` ([MotionAreaConfigurationPut](https://github.com/openhue/openhue-api/blob/main/src/motion_area_configuration/schemas/MotionAreaConfigurationPut.yaml)); HR §4.1 cites aiohue.
- **E13 A** No source says whether Hue refuses a scene name another scene of the group has; duplicates across rooms are the norm (HUE §6); one commercial driver demands unique scene names (UX, WhistleProjects).
- **E14 A** 32 counts characters, and any UTF-8 is accepted (HUE §6 "Limits").
- **E15 V** Motion never writes: `motion.lua:26`, [motion-design.md](motion-design.md) D7, EM rule 6, HR §4.2 ("Rename … forbidden without a click").
- **E17 V** New state goes in new keys; schema'd registries drop unknown fields at load (`registry.lua:34-45`; CMP §5.3 R3-R5).
- **E20 A** Persisted values live in Director's database (API `26.5_persistence/_0-Header.md`); whether a project backup restores them is not documented.
- **E22 A** Our own `RenameDevice` is reported back by `OnItemNameChanged`; the probe saw Composer's renames only (E1).
