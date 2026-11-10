# Hue lights in Control4 load groups (#435)

The contract for issue #435 and checklist row L67 of
[`c4-lighting-guidelines.md`](c4-lighting-guidelines.md). Every agent builds
against this text; the coordinator integrates.

## Contents

- [1. Summary](#1-summary)
- [2. Findings](#2-findings)
- [3. Decisions](#3-decisions)
- [4. Lifecycle edge cases](#4-lifecycle-edge-cases)
- [5. Control4 guidelines](#5-control4-guidelines)
- [6. Interfaces](#6-interfaces)
- [7. Implementation split](#7-implementation-split)
- [8. Tests and house checks](#8-tests-and-house-checks)
- [9. Reboot and changelog](#9-reboot-and-changelog)
- [10. Open questions for the owner](#10-open-questions-for-the-owner)

## 1. Summary

Owner, 2026-11-09 (#435): "yes hue lights should join c4 load groups, so they
can be used in lighting automation c4". The audit had recommended zone and
room lights instead; the owner overruled it.

What this contract builds:

- `hue_light.c4z` declares `load_group_support` True. Single lights, zone
  lights and room lights can then be members of a Control4 Load Group.
  Hue Scene devices stay out.
- The light device handles `JOIN_GROUP`, `LEAVE_GROUP`, `SET_GROUP_SYNC` and
  the four `GROUP_*` commands. Each one runs through the path its ordinary
  counterpart already uses (targets, ramps, holds, stops), so taps, stops and
  reports behave as they do today.
- The Hue Bridge driver collects the requests the members of one Load Group
  send for one group command, and sends them together. When the members
  happen to make up a whole Hue room or zone, it sends one grouped_light
  request instead of one per lamp. The lamps then move together: no
  "popcorn" effect, and one request instead of N.

It closes #435. It ships in 1.5 together with #429 and #427, so the
capability changes cost one controller reboot.

## 2. Findings

Tags: [verified: file] means read in the SDK reference or the code;
[assumed] means neither shows it. Paths under the SDK reference use the
short names of the checklist (`c4-lighting-guidelines.md` §2): LV2 is
`~/c4-tools/reference/docs-driverworks-proxyprotocol-lightv2/source/includes/`,
BP is `…/docs-driverworks-fundamentals/source/includes/27_proxy_specific_info/_50-LIGHTV2BESTPRACTICE.md`,
FUND is `…/docs-driverworks-fundamentals/source/includes/`.

### 2.1 What the light_v2 reference says

| Item | What it says (paraphrased) | Source |
| --- | --- | --- |
| `load_group_support` | Boolean, default false, **not** a dynamic capability. True means the light can take part in load groups and follows the Load Group API's requirements. The requirements themselves are written nowhere in the reference. | [verified: LV2 `5_light_v2_capabilities/_23-LOADGROUPSUPPORT.md`] |
| `JOIN_GROUP` | Sent when the driver is added to a Load Group. Parameters: GROUP ID, the device id of the Load Group driver; KEEP SYNC, 1 or 0. | [verified: LV2 `10_light_v2_commands/_14-JOIN_GROUP.md`] |
| `LEAVE_GROUP` | Sent when the Load Group drops the light. Parameter: GROUP ID. | [verified: LV2 cmds `_15-LEAVE_GROUP.md`] |
| `SET_GROUP_SYNC` | Sent when the group's "keep loads in sync" setting changes. GROUP ID, KEEP SYNC. When it is switched on, a group set-level comes just before it. | [verified: LV2 cmds `_16-SET_GROUP_SYNC.md`] |
| `GROUP_RAMP_TO_LEVEL` | The group ramps to a level. GROUP ID, LEVEL, TIME. | [verified: LV2 cmds `_17-GROUP_RTL.md`] |
| `GROUP_SET_LEVEL` | The group sets a level. GROUP ID, LEVEL. The page's heading spells it `SET_GROUP_LEVEL`, its signature `GROUP_SET_LEVEL`. | [verified: LV2 cmds `_18-GROUP_SET_LVL.md`] |
| `GROUP_START_RAMP` | The group starts a hold ramp. GROUP ID, RAMP UP (1 for up), RATE in ms. | [verified: LV2 cmds `_19-GROUP_START_RAMP.md`] |
| `GROUP_STOP_RAMP` | The group's hold ramp stops. GROUP ID. | [verified: LV2 cmds `_20-GROUP_STOP_RAMP.md`] |
| Delivery | The light_v2 commands are what the proxy accepts from Navigators, programming and services, and it passes many of them on to the protocol driver, which reports the result back with notifies. | [verified: LV2 cmds `_0-HEADER.md`] |
| No colour | None of the group commands carries a colour. A load group is brightness only. | [verified: the pages above] |
| Holds of a group | For a hold of a light, a scene or a group, the driver sends CHANGING toward the end of the range, and CHANGED where the ramp stopped. | [verified: BP "Brightness Target API"] |
| Snap One's own template | The jump-start sample configuration of a light_v2 driver declares `load_group_support` True. | [verified: FUND `26.5_jumpstart/_3-Configuration.md:288`] |
| Minimum OS | No "What's New" page mentions load groups, so no minimum OS is given. | [verified: LV2 `3_whats_new/`, grep] |
| Spellings | The reference prints parameter names with spaces. For `SET_COLOR_TARGET` the house's proxy sent underscores (`LIGHT_COLOR_TARGET_X`). | [verified: `src/hue_light/driver.lua:29-40`, hardware 2026-10-22] |

### 2.2 What the reference does not say (assumed; checked at H0 to H8)

- **A1. The Load Group is a device of its own.** Its device id is the GROUP
  ID [verified: `_14-JOIN_GROUP`]. A dealer adds it in Composer and picks
  its members from the lights that declare `load_group_support` [assumed].
- **A2. No leader.** The Load Group sends each `GROUP_*` to every member,
  each through its own proxy [assumed]. The reference names no leader and
  gives every group command the GROUP ID, which suggests a driver may be in
  several groups and is told which one acts.
- **A3. The Load Group works out its own state.** Its level, its tile and
  its keypad LEDs come from the members' `LIGHT_BRIGHTNESS_*` notifies
  [assumed]. Snap One's Lux Load Group documentation (behind a login) is
  described publicly as reporting the lowest level, the highest level, one
  chosen load, or, with "Keep Loads Synced", the most recently set load, and
  as hiding the members from the UIs while synced (web search, 2026-11-09).
- **A4. Keep sync.** With it on, Control4 keeps the members at one level.
  Who passes on a change made at one member is not documented [assumed: the
  Load Group, watching its members].
- **A5. Rates.** RATE of `GROUP_START_RAMP` is the time of the whole range,
  as a hold rate is (L14). TIME of `GROUP_RAMP_TO_LEVEL` is the ramp's
  length in ms [assumed].
- **A6. JOIN_GROUP comes once**, when the light is added, and not again at
  every Director start [assumed]. So the device persists its memberships.
- **A7. The Load Group's own keypad bindings** turn a tap into
  `GROUP_RAMP_TO_LEVEL` or `GROUP_SET_LEVEL`, and a hold into
  `GROUP_START_RAMP` and `GROUP_STOP_RAMP` [assumed].
- **A8. Deleting a Load Group** sends `LEAVE_GROUP` to each member
  [assumed].
- **A9. Timing.** Director delivers one group command to all members within
  some tens of ms [assumed].
- **A10. Colour lights.** A third-party driver listing on DriverCentral
  (2023, quoted in a search result; the page now answers 404) said Control4
  had no native load group support for colour-wheel lights. Since no group
  command carries a colour, a colour light in a load group dims and switches
  like a white one [assumed]; colour stays per device.

### 2.3 What the drivers do today

- `load_group_support` is False in `src/hue_light/driver.xml:166` and
  `src/hue_scene/driver.xml:139` [verified]. No group command has a handler.
  `common/dispatch.lua:23-27` logs a missing handler at debug and does
  nothing [verified].
- One driver, `hue_light`, serves single lights and zone and room lights
  (kind "group"), so a static capability applies to all three
  [verified: `src/hue_light/driver.lua:1-12`, `docs/zone-light-design.md` §2].
- The light device sends `HUE_SET` (absolute fields, `rate`, `urgent`) and
  `HUE_DIM` (up, down, stop) to the bridge [verified:
  `src/hue_light/driver.lua:613-653`, `:1302-1372`]. The bridge routes a zone
  or room rid to `zone_lights:set` and `zone_lights:dim`, and a light rid to
  the light queue [verified: `src/hue_bridge/driver.lua:1779-1836`].
- **Queues.** The light queue sends at most 10 requests a second after a
  burst of 10, with an 80 ms debounce per light and one request in flight
  per light. The grouped_light queue sends 1 a second after a burst of 3.
  Holds, stops and urgent states skip the bucket
  [verified: `src/hue_bridge/bridge/commands.lua:44-50`, `commands.urgent`;
  `src/hue_bridge/driver.lua:665-690`].
- **Director sends one transfer per host at a time**, strictly in turn. Two
  GETs to the bridge took 27 and 38 ms [verified: `docs/design.md`,
  "`C4:url` transfer scheduling"]. So N lamp requests leave one after
  another, never together.
- The owner's manual already says that a Control4 room Off reaches Hue
  lights one after another, about a tenth of a second per light beyond the
  first ten [verified: `src/hue_bridge/www/documentation.html:737`].
- **What a grouped_light honours.** An absolute change with
  `dynamics.duration` fades over that time [verified: house, 2026-11-09,
  `docs/tap-stop-design.md` §10 Z1]. A `dimming_delta` ignores its duration
  and covers the delta in about a second [verified: house, 2026-10-25,
  `docs/group-hold-design.md` §1]. So a whole-group request is good for
  levels and ramps, and wrong for holds.
- A change to a single light ends a running time-based scene in its room; a
  grouped_light dim leaves it running [verified: `docs/group-hold-design.md`
  G6a].
- `zone_lights:groups():groups()`, `zone_lights:grouped_light_of(rid)` and
  `zone_lights:member_lights(group)` give every Hue room and zone in the
  lights' cache with its grouped_light and member lights, read only
  [verified: `src/hue_bridge/bridge/zone_lights.lua:263-394`].
- The `HUE_SET` a level produces is the same for every lamp, except for a
  colour kept while the lamp was off, which rides along on the turn-on
  [verified: `src/hue_light/light/state.lua:256-272`]. Turn-on colours
  change with #427 (`docs/turn-on-design.md`).
- The light already keeps a ramp record, holds the bridge's reports back
  while a ramp runs, and stops ramps with a glide to the estimate
  [verified: `src/hue_light/driver.lua:366-590`, `docs/tap-stop-design.md`].
  Its hold code is tied to the keypad machine's press record:
  `dev.holding(h)` is true only for the press in progress
  [verified: `src/common/device.lua:644-646`; `src/hue_light/driver.lua:1302-1341`].
- Lua limits: `hue_light/driver.lua` main chunk has 93 locals, the bridge's
  138 of 180 [verified: `python3 tools/lua_limits.py --verbose`, 2026-11-09].
  New logic therefore goes into modules.
- `tools/build.sh` packs each driver's sub-folders whole, so a new module
  under `src/hue_light/light/` or `src/hue_bridge/bridge/` needs no build
  change [verified: `tools/build.sh:153-172`].

### 2.4 The popcorn effect, in numbers

Without this design, a group command to N Hue lamps becomes N `HUE_SET`
messages, N entries in the light queue and N requests that Director sends
one after another.

| Members | Spread of the requests (estimate) |
| --- | --- |
| 4 | about 0.1–0.15 s (Director's turn per request, ~30–40 ms) |
| 10 | about 0.3–0.4 s |
| 20 | about 1.3 s (10 at once, then 10 a second) |

The per-request time is measured for GETs and [assumed] similar for PUTs.
A ramp (a TIME above 0) hides most of the spread, since the fades overlap.
An instant change shows it. With one grouped_light request, Hue moves all
lamps of the room or zone at once [assumed: Hue sends one group message;
watched at H3].

## 3. Decisions

| # | Decision | Why |
| --- | --- | --- |
| D1 | **Ship it.** `hue_light/driver.xml` declares `<load_group_support>True</load_group_support>` in 1.5, the release that carries #429 and #427. `hue_scene` stays False. | Owner's decision. One reboot for all static changes (L82). |
| D2 | **Which devices.** Single lights, zone lights and room lights. A zone or room light in a load group is one member that drives its whole Hue group with one request. Hue Scene devices cannot join. | The capability is static and shared by the three kinds of `hue_light` (§2.1, §2.3), so Composer offers all three. A scene is no load: its level means "recall at that level", and combining scenes is the job of Advanced Lighting Scenes. Keeping it out also spares a second capability change. |
| D3 | **Each member acts on its own group command**, through the path of the matching ordinary command (§6.2 table): `GROUP_SET_LEVEL` as a target at rate 0; `GROUP_RAMP_TO_LEVEL` as a timed target, which is a ramp (#421 D6); `GROUP_START_RAMP` as a hold that no keypad button owns; `GROUP_STOP_RAMP` as that hold's release. | Control4 parity (#422) and one code path: holds, the stop, held-back reports, CHANGING and CHANGED all exist already. |
| D4 | **Turn-on rules come from `docs/turn-on-design.md`.** A group command names its level, so the On Mode (Preset or Previous, #429) does not apply. A group command that turns a lamp on from off applies the turn-on colour exactly as `SET_BRIGHTNESS_TARGET` from off does under that design (#427). If that design gives level changes without a rate a default rate (#430), `GROUP_SET_LEVEL` follows it. This contract adds no rule of its own. | One owner of the turn-on rules; the sibling contract is written at the same time. |
| D5 | **No leader; every request is tagged.** Every `HUE_SET` and `HUE_DIM` that comes from a group command carries `group` = the GROUP ID. What a lamp does never depends on the bridge knowing the membership: the membership only lets a batch close early (D7). | A2 is assumed. A design where the members act on their own commands works whether one or all members hear each command; stale membership costs at most a short wait, never a wrong command. |
| D6 | **The device keeps its memberships.** JOIN adds the GROUP ID, LEAVE removes it, SET_GROUP_SYNC records the sync flag, and a group command with an unknown GROUP ID adds it (learnt). The list is persisted, sent to the bridge as `HUE_LOAD_GROUPS` after every hello and every change, and shown in a read-only property **Load Groups**. | A6: JOIN may come only once. A group command is proof of membership. The dealer can see what Composer did. |
| D7 | **The bridge batches by GROUP ID.** The first tagged request of a group opens a batch. It closes when every expected member has sent one, or `BATCH_MS` (150 ms) after the first, whichever comes first. A second request for a lamp already in the open batch closes it at once and opens a new one with that request. Expected members are the devices that told the bridge they belong to the group and whose light or zone entry is linked and not gone. | Brings the members' requests to the queues at the same instant. Early close keeps the added delay at zero when the membership is known; 150 ms caps it otherwise (tuned at H2). |
| D8 | **Covers: one request for a whole Hue room or zone.** At the close, requests with identical absolute fields form a class. In a class: (a) a zone or room light member is sent as today, and lamp members that belong to its Hue group are folded into it; (b) of the remaining lamps, every Hue room or zone with at least 2 lights, **all** of whose lights are in the class, is a candidate; the largest go first, then by name, and chosen ones do not overlap; each chosen one is sent as one grouped_light request; (c) every other lamp is sent alone, in arrival order. A cover is used only when nothing is waiting or in flight for its grouped_light and its lamps, and the group queue has a token. Otherwise its lamps go alone. Holds and stops are never covered. A module constant `COVER` (true) turns covers off. | One request instead of N and the lamps move together (§2.4). A lamp outside the load group is never touched, because every light of a cover must be in the class. The idle check keeps an older lamp request from landing after a newer group request (the two queues have separate buckets). Holds cannot go to a grouped_light (§2.3). |
| D9 | **Holds go lamp by lamp.** `GROUP_START_RAMP` and `GROUP_STOP_RAMP` become each member's `HUE_DIM` up or down and stop. In a batch the first `PER_LIGHT_MAX` (10) lamps keep their urgency; the others are marked `paced` and take the light bucket's tokens. Starts and stops go out in the same order, so every lamp ramps for about as long as the button is held. A zone or room light member's hold goes to `bridge/group_hold.lua` as today. | Hue honours a hold's duration on a lamp, not on a group (§2.3). Pacing past 10 respects Hue's guidance, as group-hold's `PER_LIGHT_MAX` does. |
| D10 | **Urgency.** `GROUP_SET_LEVEL` and `GROUP_RAMP_TO_LEVEL` are not urgent, like `SET_BRIGHTNESS_TARGET`; the batch makes them leave together within the light bucket's burst of 10 and the group bucket's burst of 3. Hold starts and stops are urgent as today, apart from D9's pacing. | No new bypass of Hue's rate guidance. |
| D11 | **Other commands win.** A request for a lamp without a `group` tag (the lamp's own keypad, a tile, programming) first pulls that lamp's entry out of any open batch and sends it alone; the new request follows it into the queue. The queue's own rules then apply, including "a stop replaces an unsent start" (#421 D13). | A lamp's own stop must never be overtaken by a group start still sitting in a batch. |
| D12 | **Stops.** A member's own keypad tap, `SET_BRIGHTNESS_STOP` and `STOP_SCENE_RAMP` stop that member's ramp, whatever started it (#421 D5, D6, D7). `GROUP_STOP_RAMP` stops the hold of that GROUP ID; with no such hold, a ramp started by that group's `GROUP_RAMP_TO_LEVEL`; with neither, it only reports the cached level (CHANGED), as `SET_BRIGHTNESS_STOP` with nothing running does. | A group's stop should not cancel a hold the member's own keypad is doing. A member's own controls behave as a Control4 dimmer's. |
| D13 | **Keep loads in sync is recorded, never acted on.** The device stores the flag and shows it. Neither driver passes a change at one member on to the other members, also not a change made in the Hue app. | Control4's Load Group owns sync (A4). Bridge-side passing-on would act on its own across devices, could loop with the Load Group's own sync, and costs N requests per Hue-side change. Control4 is the source of truth. |
| D14 | **State and LEDs.** Each member reports its own state as today, including the hold-back during a ramp. Nothing group-level is reported by our drivers. The member's own Button Link LEDs follow the member. | A3: the Load Group derives its own level and LEDs. |
| D15 | **Self-healing membership on the bridge.** An expected member that is missing from `MISS_LIMIT` (3) batches in a row that closed by time leaves the expected set, with one info line, until its device sends `HUE_LOAD_GROUPS` or a tagged request again. | A light that left a group without a LEAVE (A8) must not slow every later batch by 150 ms. |
| D16 | **Logs.** The device logs JOIN, LEAVE and sync changes at info, and the first group command of each name in full once per driver run (to settle the spellings, as `SET_COLOR_TARGET` was settled). The bridge logs each batch at info, for example `load group 1234: 6 lights in 40 ms: Kitchen (room) as 1 request, 2 lights alone`, and the cover arithmetic at debug. | Dealers and the house checks can see what happened. |
| D17 | **Gate before code.** House check H0 (§8.2) runs before any agent starts. If Composer's Load Group does not accept third-party light_v2 devices on OS 3.4.2, or works materially unlike A1 to A3, the coordinator stops and opens a `question` issue for the owner. | The capability costs a reboot to try and another to take back. |
| D18 | **Not in this issue.** Creating Hue zones to match load groups (it would change the owner's Hue setup on its own and clutter the Hue app); batching untagged bursts such as a Control4 room Off; covers by the bridge's all-lights group; colour for load groups (Control4 has no group colour command). | Scope; each can be its own issue if wanted. |

## 4. Lifecycle edge cases

The bridge's batching acts on its own, but only on commands a person or
programming sent, within 150 ms. It creates, removes, renames and moves
nothing. Membership is advisory (D5), so a stale record costs time, never a
wrong command.

| # | Case | Side | What happens | Decision |
| --- | --- | --- | --- | --- |
| E1 | A light is added to a Load Group in Composer | C4 | `JOIN_GROUP`: the device adds the id, persists, sends `HUE_LOAD_GROUPS`, updates Load Groups. | Automatic |
| E2 | A light is removed from a Load Group | C4 | `LEAVE_GROUP`: the same, removed. | Automatic |
| E3 | A Load Group is deleted in Composer | C4 | Each member hears `LEAVE_GROUP` [A8]. If one does not, the id stays in its list and shows as `device 1234 (not found)` when no name is found; it is harmless, since no command will carry it. Dropping it because a name lookup came back empty is not done. | Automatic (LEAVE); forbidden (dropping on a lookup) |
| E4 | Keep loads in sync switched on or off | C4 | `GROUP_SET_LEVEL` then `SET_GROUP_SYNC`: the members go to the level as a batch; the flag is recorded. | Automatic |
| E5 | The Load Group is renamed | C4 | The Load Groups row reads names when it is written (each change, late init). | Automatic |
| E6 | A member device is renamed or moved to another room | C4 | Nothing; membership is by device id. | Automatic |
| E7 | A member device is deleted | C4 | Its `HUE_GOODBYE` also removes its memberships on the bridge. The Load Group keeps or drops it itself [assumed]. | Automatic |
| E8 | The project is restored from a backup | C4 | The devices' persisted lists come back with the project [assumed]. A JOIN may or may not follow. A group command with an unknown id is learnt (D6). A stale list costs at most `BATCH_MS` until D15 heals it. | Automatic |
| E9 | Director restart or controller reboot during a group ramp or hold | C4 | Timers and open batches are lost; nothing about them is persisted. Hue finishes a timed ramp, and runs a hold to the end of the range at its rate, as for a lost keypad release (L47). After the restart each member reports the real state. | Automatic |
| E10 | `GROUP_STOP_RAMP` never arrives | C4 | The group hold record ends itself at its whole-range time plus `FALLBACK_MS`; Hue has reached the end of the range. | Automatic |
| E11 | Driver update | C4 | Lua keeps the persisted lists. The capability takes effect only after the reboot; until then no JOIN arrives and the new code is idle. | Automatic; the reboot is the owner's (§9) |
| E12 | A member light deleted or forgotten in Hue | Hue | Its device is gone: it drops group commands with its reason in Status, as any command. The bridge leaves it out of the expected set. Link Device and Forget Device are the remedies, as today. | Automatic; remedies offered as today |
| E13 | A member light replaced in Hue (re-linked by radio, or Link Device) | Hue | The rid changes, the device id does not; memberships are by device id. | Automatic |
| E14 | A member light renamed in Hue | Hue | Names follow as today; nothing here. | Automatic |
| E15 | Lamps moved between Hue rooms or zones, a zone edited | Hue | Covers are worked out from the live cache at every batch close; a zone light member follows its zone (`docs/zone-light-design.md` Decision 7). | Automatic |
| E16 | A Hue room or zone deleted | Hue | It is no longer a cover; a zone light member becomes gone as today. | Automatic |
| E17 | One member changed in the Hue app while Keep sync is on | Hue | The member reports its new level. Whether Control4 brings the others along is the Load Group's business [A4]. | Forbidden: our drivers passing it on (D13) |
| E18 | Bridge unreachable or key refused (#428) | Hue | Members refuse group commands as they refuse any (`docs/offline-design.md`); nothing waits in a batch or a queue beyond today's bounds (L89). | Automatic, per that design |
| E19 | Bridge driver restarts | C4 | Memberships on the bridge live in memory only; every member's hello is followed by `HUE_LOAD_GROUPS`, which rebuilds them. | Automatic |
| E20 | Bridge replaced or paired again | Hue | Memberships are by device id and survive; devices are re-linked by today's flows. | Automatic |
| E21 | A room light and its own lamps in one Load Group | C4 | The lamps are folded into the room light's one request when their fields match (D8 a). | Automatic |
| E22 | Two Load Groups that share lamps, commanded together | C4 | Separate batches; the queue's "latest wins" per lamp settles the overlap. | Automatic |
| E23 | A Load Group mixing Hue and other lights | C4 | The Hue members batch; the others are their drivers' business. | Automatic |
| E24 | A time-based scene runs in the room | Hue | Lamps sent alone end it (G6a); a cover may leave it running [assumed]. Same as any Control4 command today. | Automatic |
| E25 | The owner goes back to a build without support | C4 | After a reboot the capability is False again. Whether Composer keeps the membership is unknown; an older build ignores group commands with a debug line. | Nothing to do |

## 5. Control4 guidelines

Rows of [`c4-lighting-guidelines.md`](c4-lighting-guidelines.md) that apply.

| Row | How this design meets it |
| --- | --- |
| L67 | Met by D1 to D3: the capability, JOIN, LEAVE, SYNC and the four group commands. The row moves to Partial at merge and to Meets after H1 to H6. |
| L2, L3, L4, L55, L69 | Each member sends CHANGING when a group command starts a change and CHANGED where it ends, through `set_brightness` and the hold code. A group hold names the end of the range, as BP asks for group holds. Every CHANGING is closed, also when a send fails. |
| L7 | Reports stay held back during a group ramp, as for any ramp (#421 D10). |
| L8, L9 | Unchanged: levels in whole percents; a lit lamp never reads off. |
| L13 | A colour command during a group ramp leaves it running (#421 D11); a group command and a colour command still merge in the queue. |
| L14 | `GROUP_START_RAMP`'s RATE is used as the whole-range time [A5], from any level. |
| L17, L20, L32, L33 | Turn-on rules as `docs/turn-on-design.md` decides (D4). Group commands carry explicit levels, so On Mode does not apply. |
| L31 | Unchanged: a colour set while off waits for the next turn-on, a group turn-on included. |
| L42, L43, L47, L48 | A group hold ramps and stops where released; up from off starts at 1 %, down from off does nothing; a lost stop does no harm (E9, E10). |
| L44 | A member's own tap stops its ramp, including one a group started (D12). |
| L53 | Unchanged: the member's LEDs follow the real state. |
| L56, L86, L87, L89 | Offline and refused-key behaviour as `docs/offline-design.md` and today's queue bounds; a group command to an offline member is dropped with its reason. |
| L62, L63 | Unchanged: Advanced Lighting Scenes keep using targets and stops. |
| L68 | The proxy's events fire per member, for group changes too. |
| L72, L73, L88 | The Load Groups row is read-only, under 75 characters, and says what Composer did. |
| L77, L78, L79 | No proxy, connection, command or event is removed or retyped; one capability and one property are added. |
| L82, L84 | `load_group_support` is static by the reference, so it needs the reboot of §9. No minimum OS is documented for it; the declared 3.3.0 stays. |
| **Departure** (new §5 entry for the checklist) | A Control4 dimmer group moves as one. Hue lamps move as one only when the members make up whole Hue rooms or zones (D8). Otherwise their requests leave one after another (§2.4), because Director sends one request at a time to the bridge and Hue's API has no request for an arbitrary set of lamps. Ramps hide most of it; instant changes show up to about 0.4 s for 10 lamps. |

## 6. Interfaces

### 6.1 Capability and property (`src/hue_light/driver.xml`, coordinator)

- `<load_group_support>True</load_group_support>`.
- A read-only string property `Load Groups`, right after `Status`.
  Texts: `None`; `Kitchen Group`; `Kitchen Group (in sync), Hallway Group`;
  over 75 characters: `3 load groups: Kitchen Group, …`. An id without
  a name: `device 1234 (not found)`.

### 6.2 Proxy commands the light device takes

All arrive through `ReceivedFromProxy` on 5001 [verified for light_v2
commands, LV2 cmds `_0-HEADER`]. Parameter keys are tried in this order;
values are strings.

| Key | Spellings tried |
| --- | --- |
| group | `GROUP_ID`, `GROUP ID` |
| sync | `KEEP_SYNC`, `KEEP SYNC` |
| level | `LEVEL` |
| time | `TIME` |
| up | `RAMP_UP`, `RAMP UP` |
| rate | `RATE` |

| Command | What the device does |
| --- | --- |
| `JOIN_GROUP` | Add the group with its sync flag (`1` true, else false). Persist, send `HUE_LOAD_GROUPS`, write Load Groups. |
| `LEAVE_GROUP` | Remove it; the same. An unknown id: nothing. |
| `SET_GROUP_SYNC` | Record the flag (learning the id if unknown); the same. |
| `GROUP_SET_LEVEL`, alias `SET_GROUP_LEVEL` | `set_brightness(level, 0)` with the group tag (D3, D4). |
| `GROUP_RAMP_TO_LEVEL` | `set_brightness(level, time)` with the group tag; the ramp record remembers the group. |
| `GROUP_START_RAMP` | A group hold: `up` is `1`; down while off does nothing; up while off turns on at 1 % and dims up 600 ms later (as `device.lua`'s `DIM_AFTER_ON_MS`); otherwise `HUE_DIM` up or down with `duration` = rate, capped at `HOLD_MAX_MS`; a missing rate uses the device's Hold Rate Up or Down. CHANGING toward 100 or 1, the estimate ticking every 100 ms. A new start ends a running group hold first. |
| `GROUP_STOP_RAMP` | D12: the group hold's stop (`HUE_DIM` stop with the estimate, then the fallback as `dev.on_finish` arms it); else `stop_ramp` for a ramp tagged with that group; else CHANGED with the cache. |

A group command with an id not in the list adds it first (D6). A group
command while the device cannot be driven is dropped with its reason, as
any command (`ready`). Group commands that arrive before late init wait for
it, as other early commands do (`dev.after_late_init`).

### 6.3 Messages from the light device to the bridge

- `HUE_SET` and `HUE_DIM` gain an optional `group` (string, the GROUP ID).
  Sent only for requests a group command caused, including the stop and the
  1 % turn-on of a group hold.
- New `HUE_LOAD_GROUPS { device_id, rid, kind, groups }`: `kind` is `group`
  for a zone or room light and absent for a light; `groups` is
  `1234:1,5678:0` (id and sync flag) or `none` (SendToDevice drops empty
  values). Sent after every hello and after every change of the list.

### 6.4 Persisted on the light device

- Key `hue_load_groups`: a table `{ ["1234"] = { sync = true }, … }`
  (`C4:PersistSetValue` stores tables, as the saved level does,
  `src/hue_light/driver.lua:975`). A value that is not such a table, or an
  entry whose key is not a positive integer string, is dropped at load (L83).

### 6.5 Light module: `src/hue_light/light/load_group.lua` (new)

```lua
local load_group = require("light.load_group")
load_group.KEY = "hue_load_groups"
load_group.COMMANDS = {             -- proxy command -> op
	JOIN_GROUP = "join", LEAVE_GROUP = "leave", SET_GROUP_SYNC = "sync",
	GROUP_SET_LEVEL = "set", SET_GROUP_LEVEL = "set", GROUP_RAMP_TO_LEVEL = "ramp",
	GROUP_START_RAMP = "start", GROUP_STOP_RAMP = "stop",
}
-- §6.2 spellings; numbers clamped (level 0..100, time and rate >= 0).
load_group.parse(command, params)
	--> { op, group = "1234", sync = bool|nil, level = n|nil, time = ms|nil, up = bool|nil, rate = ms|nil }
	--> or nil, why    ("no group id", "unknown command")
local m = load_group.new({
	persist_get = function(key) end, persist_set = function(key, value) end,
	display_name = function(device_id) end,   -- C4:GetDeviceDisplayName [verified: API 32/_6]; nil or "" when unknown
	log = log,
})
m:load()                     -- the persisted list; bad values dropped
m:join(id, sync)  --> changed   m:leave(id) --> changed
m:set_sync(id, sync) --> changed   m:learn(id) --> changed (false when known)
m:has(id) --> bool           m:ids() --> sorted list of id strings
m:wire() --> "1234:1,5678:0" or "none"
m:text() --> the Load Groups row (§6.1)
-- The whole-range hold arithmetic start_ramp uses, as a pure function.
load_group.hold_plan(from, up, rate_ms, max_ms) --> { to, duration, full, step }
```

### 6.6 Light driver changes (`src/hue_light/driver.lua`, coordinator)

- Create the module at load; `m:load()` in `OnDriverLateInit` before the
  hello; write Load Groups there.
- Send `HUE_LOAD_GROUPS` (`m:wire()`) right after each `hello`, and after
  each change from §6.2.
- `set_brightness(target, rate, urgent, tap, group)`: a fifth argument puts
  `group` in the params; `begin_ramp` keeps it in the ramp record.
- `stop_ramp(why)` copies the ramp's group into its `HUE_SET` or `HUE_DIM`,
  so a group's stop is batched with its siblings.
- A group hold record `{ group, level, step, to, timer, full }` separate from
  the keypad's: `start_ramp` takes a liveness test instead of calling
  `dev.holding(h)` directly (the keypad's record passes `dev.holding`, the
  group record its own `active` flag). A keypad hold or press ends a running
  group hold (the keypad wins, as a keypad hold ends a ramp today).
- Register the seven handlers of §6.2 with `dispatch.proxy`, wrapped by
  `after_late_init`.
- The main chunk's locals stay under 180 (`tools/lua_limits.py`).

### 6.7 Bridge module: `src/hue_bridge/bridge/load_groups.lua` (new)

```lua
local load_groups = require("bridge.load_groups")
load_groups.BATCH_MS = 150
load_groups.MISS_LIMIT = 3
load_groups.PER_LIGHT_MAX = 10
load_groups.COVER = true
local lg = load_groups.new({
	light_set   = function(rid, fields) end,   -- limits + light queue :set (fields as HUE_SET maps them, dims too)
	zone_set    = function(params) end,        -- zone_lights:set(params)
	zone_dim    = function(params) end,        -- zone_lights:dim(params)
	group_set   = function(grouped_light_rid, fields) end, -- group_hooks.group_set
	zone_lights = function(zone_rid) return grouped_light_rid, { light_rid, … } end, -- nil when unknown
	covers      = function() return { { grouped_light = rid, label = "Kitchen (room)", lights = { rid, … } }, … } end,
	rid_of      = function(device_id) return rid, kind end,   -- linked and not gone, else nil
	light_idle  = function(rid) return bool end,              -- light queue :idle
	group_idle  = function(grouped_light_rid) return bool end, -- group queue :idle
	group_token = function() return bool end,                -- group queue :token_ready
	set_timer   = function(ms, fn) return timer end,          -- timer:Cancel()
	now = function() return ms end, log = log,
})
lg:memberships(device_id, groups_wire)  -- HUE_LOAD_GROUPS: replaces that device's set ("none" clears it)
lg:forget_device(device_id)             -- HUE_GOODBYE
lg:command(op, params)                  -- op "set" | "dim"; params as received, with params.group
                                        --> true when taken into a batch
lg:release(rid)                         -- D11: send that rid's open entry alone now
lg:stop_all()                           -- teardown: cancel timers, drop open batches
```

Rules inside (D7 to D9, D15):

- An entry is `{ rid, kind = "light" | "zone", op, fields, params, at }`.
  Fields are mapped from the params exactly as the `HUE_SET` and `HUE_DIM`
  handlers map them today, `urgent` included.
- Close when the entries cover every expected member, at `BATCH_MS`, or when
  a second entry for the same rid arrives.
- Class key for `set` entries: `on`, `brightness`, `x`, `y`, `mirek`, `rate`,
  each rounded as `commands.body` rounds it; `urgent` is not part of it. A
  cover's fields are urgent when any entry of it was.
- `dim` entries go out alone in arrival order; zone entries through
  `zone_dim`; light entries past the first `PER_LIGHT_MAX` get
  `paced = true`.
- Nothing is sent from inside `command` except at a close; everything runs
  pcall-wrapped from a timer or the caller, as the other bridge modules do.

### 6.8 Queue additions (`src/hue_bridge/bridge/commands.lua`)

- `commands:idle(rid)`: true when that rid has nothing pending, in flight or
  on a timer.
- `commands:token_ready()`: true when a non-urgent request would leave now;
  it refills the bucket but takes no token.
- A pending field `paced`: `commands.urgent(pending)` is false while
  `pending.paced == true`, even for a dim. A merged state stays paced only
  when the newest fields carry `paced`; any fields with `urgent` clear it.
  Neither field ever goes into a PUT body.

### 6.9 Bridge driver changes (`src/hue_bridge/driver.lua`, coordinator)

- Build `state.load_groups` with the hooks of §6.7 where the queues are
  built; `stop_all()` where they are torn down (with `group_hold:stop_all()`).
  The `covers` hook walks `zone_lights:groups():groups()`, keeps groups with
  a `grouped_light_of` and at least 2 `member_lights`, and labels them as
  `zone_lights` does.
- `HUE_SET` and `HUE_DIM`: after today's checks, a `group` param hands the
  request to `lg:command`; without one, `lg:release(rid)` runs first, then
  today's path.
- New handler `HUE_LOAD_GROUPS` → `lg:memberships`. `HUE_GOODBYE` also calls
  `lg:forget_device`.
- `HUE_SET` and `HUE_DIM` log lines add ` group <id>` when tagged.

## 7. Implementation split

Disjoint file sets; no agent runs git; others edit the rest of the checkout
at the same time.

| Part | Files it owns |
| --- | --- |
| **A** light module | new `src/hue_light/light/load_group.lua`, new `tests/spec/light_load_group_spec.lua` |
| **B** bridge batching | new `src/hue_bridge/bridge/load_groups.lua`, new `tests/spec/load_groups_spec.lua` |
| **C** queue | `src/hue_bridge/bridge/commands.lua`, `tests/spec/commands_spec.lua` |
| **D** driver-level specs, written against §6 before the glue exists | new `tests/spec/light_load_group_driver_spec.lua`, new `tests/spec/load_group_roundtrip_spec.lua` |
| **E** docs | `src/hue_light/www/documentation.html`, `src/hue_bridge/www/documentation.html` (a load groups section; chapter 11's pacing paragraph), `docs/composer-checklist.md` (section N, text in §8.2), `docs/c4-lighting-guidelines.md` (L67, question 4 answered, the new §5 departure) |
| **Coordinator** | `src/hue_light/driver.lua` (§6.6), `src/hue_light/driver.xml` (§6.1), `src/hue_bridge/driver.lua` (§6.9), `CHANGELOG.md`, `docs/status.md`, `docs/design.md` ("Commands and rate limiting": batches and covers), `docs/README.md` (index entry for this file), H0 before spawning, integration, `tools/check.sh`, `tools/build.sh`, commits |

`tools/build.sh` needs no change (§2.3). Every brief names
`docs/c4-lighting-guidelines.md`, BP, the LV2 pages of §2.1, this contract,
`docs/tap-stop-design.md`, `docs/group-hold-design.md` and
`docs/turn-on-design.md`. Conventions: Lua 5.1, tabs, `.luacheckrc`, busted
with the fake C4 runtime of `tests/`, comments citing `#435 D<n>` and
marking API claims [verified] or [assumed]. Done means `luacheck src tests
tools`, `busted tests`, `python3 tools/lua_limits.py` and (Part E)
`python3 tools/check_links.py` pass.

## 8. Tests and house checks

### 8.1 Busted specs

`light_load_group_spec.lua` (A):

- parses each command with underscore and space spellings, and both
  set-level names;
- rejects a command without a group id;
- join, leave, sync and learn report "changed" only on a change;
- the list survives `load` after `persist_set`; a bad persisted value and a
  bad key are dropped;
- `wire()` and `text()` for none, one, two in sync, a long list, a missing
  name;
- `hold_plan` matches `start_ramp`'s arithmetic for up, down and a rate
  above the cap.

`load_groups_spec.lua` (B):

- a batch closes as soon as every expected member has sent, and at
  `BATCH_MS` otherwise;
- members that make up a whole zone become one `group_set`; a missing lamp
  sends all of them alone;
- two disjoint rooms in one class become two group requests, largest first;
  overlapping candidates never both;
- a zone light member folds in its lamps when fields match, not when they
  differ;
- differing fields (a turn-on colour on one lamp) split the class;
- dims are never covered; lamps past the tenth are `paced`, in the same
  order for starts and stops;
- `release(rid)` sends that entry alone and leaves the rest in the batch;
- a second request for a rid closes the batch and opens a new one;
- a cover is refused when `group_idle`, `light_idle` or `group_token` says
  no;
- `COVER = false` sends every lamp alone;
- a member missing from three timed-out batches leaves the expected set,
  and comes back with `memberships`;
- `forget_device` and `stop_all` cancel and forget.

`commands_spec.lua` additions (C): `idle` across pending, in flight and
retry; `token_ready` takes no token; a paced dim waits for a token; urgent
fields clear paced.

`light_load_group_driver_spec.lua` (D):

- JOIN persists, writes Load Groups and sends `HUE_LOAD_GROUPS`; LEAVE and
  SET_GROUP_SYNC likewise; a hello is followed by `HUE_LOAD_GROUPS`;
- `GROUP_SET_LEVEL` sends CHANGING and a `HUE_SET` with `group` and rate 0;
- `GROUP_RAMP_TO_LEVEL` starts a ramp: reports held back, a keypad tap
  stops it with a tagged level `HUE_SET`, CHANGED with the estimate;
- `GROUP_START_RAMP` up, down, up from off (1 % then the dim), down from
  off (nothing); `GROUP_STOP_RAMP` stops it; a stop for another group id
  leaves it running; a lost stop ends the record after the whole range plus
  the fallback;
- a keypad hold during a group hold ends the group hold;
- an unknown group id is learnt; a device that cannot be driven drops the
  command with its Status;
- the same on a zone light device.

`load_group_roundtrip_spec.lua` (D): two light devices and the bridge on
the fake runtime; a group set-level to both makes one grouped_light PUT
when they are a whole zone, and two light PUTs when they are not; a member's
own tap during a group ramp stops only that member.

### 8.2 House checks (text for `docs/composer-checklist.md`, section "N. Load groups (#435)")

Each step is under a minute. The Windows session clicks and reads under the
owner's standing approval; the owner watches lamps where noted.

```
N. Load groups (#435)

H0 (before any code; read only, plus one temporary device). In Composer
   search Items for "Load Group". Add one to a test room, open its
   Properties and Documentation tabs and screenshot them, open its member
   picker and note which devices it offers (Hue devices should not appear
   yet), then delete it. Record in #435: the driver's name, its properties
   (sync, level reporting), what its documentation says about members,
   commands and keypads. Confirms or corrects A1 to A4, A7 and A8.
H1 (after the 1.5 install and the reboot). The Load Group's picker offers
   Hue Light devices (a single light, a zone light, a room light) and no
   Hue Scene device.
H2 Add two lamps of one Hue zone. Each lamp's Load Groups row names the
   group. With Debug Mode on, the bridge log shows each lamp's JOIN and
   the spelling of its parameters, and for the next group command the
   arrival time of each member's request (sets BATCH_MS).
H3 Owner watching: group tile on, off and 40 % from a Navigator. The
   two lamps move together; the bridge log says "as 1 request". Remove the
   zone's other lamps from the picture (a group of lamps from two rooms):
   the log says "alone" and the owner reports any visible stagger.
H4 Bind a keypad button to the Load Group. Tap, double tap, hold and
   release, tap during a ramp. Record which group commands arrive, that
   the hold stops where released, and that the keypad LED follows.
H5 Keep loads in sync on: both lamps go to one level. Change one lamp in
   the Hue app: record whether the other follows (A4).
H6 Remove one lamp from the group: its Load Groups row reads None. Delete
   the Load Group: record whether the other lamp hears LEAVE (A8).
H7 Restart Director (Composer). Rows unchanged; record whether JOIN came
   again (A6). A group command still moves both lamps.
H8 Put the zone light and both its lamps in one group: one request per
   group command.
```

## 9. Reboot and changelog

- **Reboot.** `load_group_support` is a static capability: after the update
  the owner reboots the controller from System Manager (Composer's "Restart
  Director?" does not load it). It ships in 1.5 with the capability changes
  of #429 and #427, so the release needs one reboot in all. The install
  brief's `start --note` says so. The Lua and the new property need no
  reboot.
- **`CHANGELOG.md`, `## Unreleased`, under `### Added`:**

```
- Hue Light devices (single lights, zone lights and room lights) can join
  Control4 load groups and follow the group's on, off, level, ramp and hold
  commands, so a load group can drive Hue lights in Control4 programming.
  When the Hue lights of a load group make up whole Hue rooms or zones, each
  such room or zone gets one request and its lamps move together; other
  lamps get one request each, a few hundredths of a second apart. Each
  light's new Load Groups row shows its groups. Hue Scene devices cannot
  join. After this update, reboot the controller from System Manager once
  (#435).
```

## 10. Open questions for the owner

Answered by the owner on 2026-11-09: Q1 yes, one request per whole Hue room or zone is on by default; Q2 no, the bridge never propagates "Keep loads in sync".

1. **Covers on by default?** D8 makes members that form whole Hue rooms or
   zones one grouped_light request. It is the only way to make Hue lamps
   move together, and it cuts the requests, but the request then goes to a
   Hue group rather than to each lamp (for example a time-based scene in the
   room may keep running, E24). **Recommended: on**, with `COVER` as the
   switch should H3 show a problem.
2. **If Control4's "keep loads in sync" does not pass Hue-app changes on
   (H5), should the bridge do it?** It would mean the bridge commanding the
   other members whenever one lamp changes outside Control4. **Recommended:
   no** (D13): Control4 owns sync, a loop with the Load Group is possible,
   and Control4 is the source of truth.
