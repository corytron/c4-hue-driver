# Security review 2026-11-13, reviewer D: the device drivers (#480)

Read-only review of the Hue Light, Hue Scene and Hue Motion drivers
(`src/hue_light/`, `src/hue_scene/`, `src/hue_motion/`, Lua and XML), the
shared device plumbing (`src/common/device.lua`, `link.lua`, `dispatch.lua`)
and the bridge side of the bridge-to-device messages (`bridge/lights.lua`,
`scenes.lua`, `zone_lights.lua`, `motion.lua`, `owner.lua`, and the
`HUE_SET` / `HUE_DIM` / `HUE_HELLO` / `HUE_LOAD_GROUPS` handlers of
`hue_bridge/driver.lua`), against the contract
[`../security-review-design.md`](../security-review-design.md). The code is
the worktree `security/review-480` as of 2026-11-13; line numbers are its.

Method: every file in the area read whole; the earlier reviews and
[`../security-fixes-design.md`](../security-fixes-design.md) rechecked
item by item; findings tried with `lua5.1` and with three throw-away busted
probes on the fake runtime (`tests/helpers/fake_c4.lua`), kept in a scratch
directory outside the repository. Nothing was sent to the controller, the
bridge or any LAN host; no `git` command was run.

SDK citations: "API x/_y" is
`~/c4-tools/reference/docs-driverworks-api/source/includes/x/_y-*.md`;
"LV2 cmds _n" is
`~/c4-tools/reference/docs-driverworks-proxyprotocol-lightv2/source/includes/10_light_v2_commands/_n-*.md`.
"[verified: fake]" means a scratch probe on the fake runtime showed it;
"[verified: lua5.1]" a scratch run of the Lua 5.1 interpreter (Ubuntu,
x86-64); "[verified: read]" reading only.

## Verdict

No Critical, High or Medium finding. The devices hold no secret, build no
URL, decode no JSON and talk to nothing but the bound Hue Bridge through
`C4:SendToDevice`. Every entry point runs under `pcall` (`dispatch.lua:22-33`),
so nothing here can stop Director or another driver; the worst a bad input
does is make one handler raise, keep one device's tile wrong, or grow one
device's memory and store.

The theme of this area is trust. A device takes every bridge message from
any driver in the project, and the inputs it does check are checked against
ranges that NaN slips through. Six Low findings, two Info. The cheapest
useful change is D-1's first two fixes (rid match, no silent re-target), then
D-3's cap and the NaN-proof checks of D-4 and D-5.

## Summary

| ID | Rating | Title |
|---|---|---|
| D-1 | Low | Every device takes every bridge message from any driver in the project, rid-less ones included; a spoofed configure re-targets a light or silences a motion sensor and is persisted |
| D-2 | Low | A hello can register a light rid with path characters, which the bridge pastes into its keyed PUT path (bridge side; overlaps reviewer C) |
| D-3 | Low | Load group memberships are learnt and persisted without bound, with name lookups quadratic in their number |
| D-4 | Low | Non-finite and out-of-range numbers from the proxy reach `HUE_SET`, `C4:SetTimer` and the keypad machine |
| D-5 | Low | Motion readings: NaN passes the range checks (a NaN baseline silences Light Level Changed for good; "nan" reaches a bound thermostat) |
| D-6 | Low | Timestamps reach `os.date` unchecked in the devices (`gone_since`, a persisted `offline_since`), the device-side twin of 2026-10-24 finding 6 |
| D-7 | Info | Proxy commands are accepted on every binding, the Button Links included |
| D-8 | Info | The light and scene drivers' messages are always logged by Director; Debug Mode never switches itself off |

## Findings

### D-1 (Low): every device takes every bridge message from any driver

- **Position:** the controller. Any driver in the project: `ExecuteCommand`
  carries no sender [verified: API 5_director_command/_1-ExecuteCommand],
  `C4:SendToDevice` reaches any device id [verified: API
  32_serial_network_device/_19-SendToDevice], and any driver can bind two
  devices with `C4:Bind` [verified: API 9_helper/_1-bind]. It needs only the
  message names, which are in this public repository. A `LUA_ACTION` with
  `ACTION = "HUE_STATE"` works too (`dispatch.lua:35-45`).
- **What the devices check:** only `params.rid ~= st.rid`, and only when both
  are present: a message without `rid` is always taken
  (`hue_light/driver.lua:1369`, `:1408`; `hue_scene/driver.lua:1612`, `:1674`,
  `:1764`; `hue_motion/driver.lua:1326`, `:1391`). `HUE_BRIDGE_LINK` has no rid
  at all (`common/device.lua:499-520`, `hue_motion/driver.lua:1373-1384`).
  Configures take any rid and persist it (`light/state.lua:116-118` with
  `hue_light/driver.lua:1198-1206`; `hue_scene/driver.lua:1452-1474`;
  `hue_motion/driver.lua:1259-1289`).
- **What a spoofing driver can do** [verified: fake, each one]:
  - Report false state to programming, the proxy's events and the keypad LEDs:
    `HUE_STATE { on = "false" }` without a rid reaches the proxy as
    `LIGHT_BRIGHTNESS_CHANGED 0` and the Button Links as `MATCH_LED_STATE`.
  - Forge motion: `HUE_MOTION_STATE { motion = "true" }` without a rid sends
    `OPENED` ("senses motion"), `motion = "false"` sends `CLOSED`. Motion
    often drives alarms and lighting. (`Test Motion Programming` and its two
    hidden aliases do the same by design, `hue_motion/driver.lua:1409-1439`.)
  - Silence a motion sensor: `HUE_MOTION_CONFIGURE { rid = "<anything>" }`
    persists the new rid; every real `HUE_MOTION_STATE` is then dropped as
    "for rid … ignored". It lasts until the bridge sends this device a
    configure again (at its next start, `bridge/owner.lua:473-488`).
  - Re-target a light: `HUE_CONFIGURE { rid = "<another light's rid>" }` is
    persisted as `hue_rid`; the next Navigator or keypad command goes out as
    `HUE_SET` for the other light, which the bridge accepts from any sender
    (`hue_bridge/driver.lua:1896-1932`). The device's next hello names a rid
    another device holds, which the bridge answers as a conflict and does not
    correct (`bridge/owner.lua:600-607`). The real light's states are dropped
    as foreign. A scene device can be pointed at a scene of the `bridge_home`
    group the same way, so its OFF turns the whole home off.
  - Deny control: `HUE_BRIDGE_LINK { state = "offline" }` makes every proxy
    command drop with a false Status ("Hue Bridge refuses the pairing since
    …") until the bridge's next link change or hello answer; the
    `HUE_*_FORGOTTEN` messages do the same until the next configure.
  - Crash: no. Each handler is under `pcall`; D-4 and D-6 make single
    handlers raise.
- **Impact:** integrity of what Control4 shows and runs on; a motion sensor
  that lies or goes quiet. No key, no code execution, no reach beyond what
  the same driver could already do through the bridge directly
  (2026-10-24 finding 9: inter-driver messages trust the project, an accepted
  residual risk). The device side of that risk was never written down, and
  three parts of it (rid-less messages, persisted re-targets, silenced
  sensors) are cheap to narrow.
- **Where:** as listed above.
- **Fix:**
  1. Once a device has a rid, drop any state, group or forgotten message
     whose `rid` is absent or different. Every bridge message
     already carries it (`hue_model.state_params` `:352-353`,
     `scenes:state_params` `:873-876`, `zone_lights:state_params` `:533-535`,
     `motion:send_state` `:1225-1227`), so nothing legitimate is lost.
  2. Take a configure that changes an established rid only as the answer to
     the device's own hello (a window of a few seconds after it), else warn
     and ignore it. The bridge's re-link (Link Device) then needs to say so
     (`relink = "true"`) or to go through a hello.
  3. Optional, stronger: a per-start token from `C4:UUID("Random")`
     [verified: API 9_helper/_19.5-uuid, OS 3.3.0, the drivers' declared
     minimum], sent in the hello with `logCommand` false, echoed by the bridge
     in every message to that device; once set, messages without it are
     dropped. `HUE_BRIDGE_LINK` would carry it too.
  4. Say in the motion manual that, as for any DriverWorks device, motion
     events can be raised by any driver in the project.

### D-2 (Low): a hello can register a light rid that leaves the light path

- **Position:** the controller: a driver in the project that is bound to the
  bridge's binding 1 (it can bind itself with `C4:Bind` if it declares a
  `HUE_BRIDGE` consumer connection [verified: API 9_helper/_1-bind]), or that
  sends a hello in the name of a bound device that has no registry entry yet.
- **What happens** [verified: fake, `bridge/lights.lua` with
  `bridge/owner.lua`]: `HUE_HELLO { rid = "x/../../grouped_light/<id>",
  device_id = <bound device> }` is adopted "from its own persisted rid"
  (`owner.lua:641-645`; `registry.lua:151-153` accepts any non-empty string),
  marked gone, and `lights:device_for` still answers for it
  (`lights.lua:374-377`). `HUE_SET` for that rid then queues and the queue
  sends `PUT /clip/v2/resource/light/x/../../grouped_light/<id>` with the
  application key (`hue_bridge/driver.lua:706-711`, `:1905-1931`). libcurl
  removes dot segments from a URL path by default, which would make that
  `/clip/v2/resource/grouped_light/<id>` [assumed: that C4:url does so]. The
  2026-10-25 review (its row 5) judged unchecked persisted rids safe because
  the host cannot move; the resource type can.
- **Impact:** keyed PUTs with a light-state body to resources the drivers
  never write: any room, zone or the whole home's grouped_light (on, off,
  level, colour). Persisted in `hue_lights`. Other resource types would
  refuse the body [assumed].
- **Where:** `bridge/owner.lua` `hello` `:575-650` and `adopt`;
  `bridge/registry.lua` `valid_rid` `:151-153`; `hue_bridge/driver.lua`
  `HUE_SET` `:1896`, `HUE_DIM` `:1940` (no state check on the entry).
- **Fix (bridge side, for reviewer C to confirm and own):** check every rid
  that enters the registry, from a hello, an adoption or the store, with
  `hue_model.resource_id` (`^[%w%-]+$`); in `HUE_SET` and `HUE_DIM` refuse an
  entry that is not `linked`. Device side, D-1 fix 2 keeps a spoofed rid out
  of the device's own hello.

### D-3 (Low): load group memberships are learnt without bound

- **Position:** anything that reaches the light's `GROUP_*` proxy handlers: a
  driver bound to one of its Button Links (D-7), or a driver that sends the
  command to the light's proxy [assumed: that the light_v2 proxy forwards a
  `GROUP_SET_LEVEL` sent to it with `SendToDevice`]. A Load Group deleted in
  Composer also leaves its id behind for ever, at a slow rate.
- **What happens:** every group command with an unknown `GROUP ID` is learnt
  (`load_group.ASSUME.learn`, `light/load_group.lua:763-765`); any positive
  integer below 1e15 is an id (`:178-189`). Each learn persists the whole list
  (`:384-390`, `:479-488`), sends the whole wire to the bridge as
  `HUE_LOAD_GROUPS` and rewrites the Load Groups row, which looks up the name
  of every id (`:519-556`). Measured [verified: fake]: 1 500 fresh ids gave a
  persisted list of 1 500 entries, 1 500 `HUE_LOAD_GROUPS` (the last one
  13.5 KB), 1 127 250 `C4:GetDeviceDisplayName` calls and 7.7 s of Lua time
  on the VM. The list survives restarts and is sent and named again at every
  hello; only a `LEAVE_GROUP` per id removes an entry. The bridge's
  `parse_groups` takes the wire uncapped (`bridge/load_groups.lua:260`, `:428`).
- **Impact:** CPU time in Director per command (quadratic), a store entry and
  a per-hello message that grow without limit. Availability only.
- **Where:** `src/hue_light/light/load_group.lua` `learn`, `handle`, `text`,
  `announce`; `src/hue_light/driver.lua:2160-2215`.
- **Fix:** cap the list (a few dozen; warn and refuse beyond it); learn an id
  only when `C4:GetDeviceDisplayName` [verified: API
  32_serial_network_device/_6-GetDeviceDisplayName] knows it (the proxy
  reference calls it the Load Group's driver id [verified: LV2 cmds
  _18-GROUP_SET_LVL.md]); look names up once per row write, not per learn
  burst (a 1 ms deferral coalesces a burst). Cap `parse_groups` on the bridge
  (reviewer C).

### D-4 (Low): non-finite and out-of-range numbers from the proxy

- **Position:** programming, a Navigator, a bound Button Link or a driver
  sending through the proxy. Navigators and Composer's programming
  editor bound these values [assumed]; other drivers do not.
- **Lua 5.1 facts** [verified: lua5.1]: `tonumber` accepts "nan", "inf" and
  "1e999"; NaN fails every comparison; `math.min(100, NaN)` is 100 while the
  bridge's `clamp` returns NaN unchanged (`bridge/commands.lua:98-102`);
  `string.format("%d", inf)` and `("%d", NaN)` give "-9223372036854775808"
  on x86-64 (the conversion is undefined in C; another CPU may answer
  otherwise [assumed]); `t[NaN] = v` raises.
- **What happens** [verified: fake unless noted]:
  - Light (`set_brightness`, `hue_light/driver.lua:995-1000`; `light/state.lua`
    `str` `:92-97`, `from_brightness_target` `:295-310`; `set_color` `:1067`):
    `LIGHT_BRIGHTNESS_TARGET = "inf"` goes out as `HUE_SET brightness =
    "-9223372036854775808", on = "true"`, which the bridge's queue turns into
    a plain "on" at the old level (`commands.lua` `merge` `:217`); "nan" goes
    out as `brightness = "nan"`, and `LIGHT_COLOR_TARGET_X = "nan"` as
    `x = "nan"`. The bridge's queue keeps NaN and writes it into the PUT body
    (dkjson writes `null`; what `C4:JsonEncode` writes is [assumed]), so the
    bridge sends a malformed request [verified: lua5.1 on `commands.body`].
    The proxy is told `LIGHT_BRIGHTNESS_TARGET` inf or NaN in the CHANGING.
  - Scene (`set_target`, `hue_scene/driver.lua:1186-1191`): the rate gets a
    floor of 0 but no ceiling, unlike the light's `clamp_rate` (#430 D20).
    `SET_LEVEL { LEVEL = 0, TIME = "inf" }` calls `C4:SetTimer(inf)` twice
    (`arm` `:535-545`, `begin_ramp` `:723-730`; the API asks only for a delay
    above 0 [verified: API 34_timer/_1-SetTimer]; what Director does with inf
    is [assumed]), sends `HUE_SCENE_OFF duration = "-9223372036854775808"`
    (`:1103`), which the bridge drops (`scenes.lua` `off_options` `:2237`, an
    instant off), and starts a ramp that never ends. That ramp holds back the bridge's
    group-off and inactive reports (`hold_group` `:770`): the tile and the
    keypad LEDs stay on while the room is off, until the next command. A huge
    finite TIME does the same for as long as the number says.
  - Keypad machine (`common/device.lua` `BUTTON_ACTION` `:1183-1197`):
    `BUTTON_ID` and `ACTION` are taken as any number, while the reference
    defines 0 to 2 for both [verified: LV2 cmds _1-BUTTONACTION.md].
    `BUTTON_ID = "nan"` raises "table index is NaN" after the echo; every other
    id opens its own double-tap window, so 20 clicks on 20 ids gave 20 urgent
    `HUE_SET`s (20 clicks on button 0 gave one); presses never released stay
    in `down` and each gets a release notify at `OnDriverDestroyed`;
    `ACTION = 4` is echoed to the proxy (a triple-tap notification).
- **Impact:** wrong or malformed requests to the bridge, a scene tile and
  keypad stuck on, `urgent` requests that skip the bridge's token bucket
  (still one in flight per light). No crash beyond one handler.
- **Fix:** one `finite(v)` helper in `common/device.lua` (as
  `light/load_group.lua:165-171` and `light/turnon.lua` `num` already have),
  used for every proxy number; clamp brightness targets to 0..100 before
  `str()`; pass the scene's rates through a `clamp_rate` like the light's
  (0..`device.RATE_MAX`); take `BUTTON_ID` and `ACTION` only in 0..2. The
  bridge's `commands.merge` should drop non-finite fields too (reviewer C).

### D-5 (Low): motion readings let NaN through

- **Position:** a driver sending `HUE_MOTION_STATE` (D-1). The bridge itself
  cannot produce NaN (JSON carries none, and an infinite temperature fails
  the range check); a corrupt store can.
- **What happens** [verified: fake]: `take_lux` refuses only `lux < 0`
  (`hue_motion/driver.lua:787-804`) and `take_temperature` only `c < -100 or
  c > 100` (`:808-829`); NaN passes both.
  - A first lux of "nan" sets `lux_fired` to NaN, which is persisted in
    `motion_values`; every later reading compares false against it, so
    Light Level Changed never fires again, across restarts (three real
    readings after it fired 0 events; a restart and 9 000 lux fired 0).
  - A temperature of "nan" sets the Temperature C and F variables to "nan"
    and sends `VALUE_CHANGED { CELSIUS = "nan", FAHRENHEIT = "nan" }` on the
    TEMPERATURE_VALUE output, where a thermostat may read it as its room
    temperature [assumed: what it then does].
  - `load_values` (`:490-515`) takes the stored numbers with `tonumber` only,
    so a NaN stored by an older or tampered version has the same effect.
- **Impact:** a programming event silenced for good; a bad value to a
  thermostat until the next reading.
- **Fix:** NaN-proof the checks (`if not (lux >= 0) then`, `if not (c >= -100
  and c <= 100) then`); in `load_values` drop non-finite numbers.

### D-6 (Low): timestamps reach `os.date` unchecked in the devices

- **Position:** a driver sending a configure (D-1), a bridge whose stored
  registry holds an odd `gone_since` (it is coerced with `tonumber` and never
  range-checked, `bridge/registry.lua:239-241`), or a corrupt device store.
- **What happens:** `os.date` returns nil for a time it cannot convert, and
  `..` or `%s` with nil raises [verified: lua5.1].
  - Light and scene `gone_status` (`hue_light/driver.lua:281-288`,
    `hue_scene/driver.lua:218-221`) format `gone_since` straight from the
    configure. With `state = "gone", gone_since = "1e300"` the
    `HUE_CONFIGURE` handler raises in `refresh_status`, and so does every
    command dropped afterwards (`ready` calls it) [verified: fake]; the
    light's `hello` then stops before `groups:announce()`.
  - Motion `mark()` (`hue_motion/driver.lua:382-387`, via `clock`
    `:239-241`) formats the persisted `offline_since`. With
    `motion_values = { online = false, offline_since = 1e300 }` late init
    raises in `commit()` (`:634-643`): the rows and Status are not written and
    `dev.replay_bindings()` never runs; every later commit raises the same way
    while the sensor stays offline [verified: fake].
- **Impact:** a device whose Status and rows stop updating; no reach beyond
  it. The 2026-10-24 finding 6 fixed exactly this on the bridge
  (`util.date_of`); the devices kept their own `os.date` calls.
- **Fix:** read both through `common/link.lua`'s `seconds()` rule (a positive
  number below 2^32, else no time shown), as `link_since` already is at
  `hue_motion/driver.lua:509-511`; on the bridge, range-check the stamps at
  load (reviewer C).

### D-7 (Info): proxy commands are accepted on every binding

- **Position:** a driver bound to a Button Link (200 to 202) of a light or
  scene device, by the dealer or by `C4:Bind`.
- **What happens:** `dispatch.received_from_proxy` ignores the binding id
  (`common/dispatch.lua:53-56`), and only the four keypad handlers look at it.
  `SET_BRIGHTNESS_TARGET` on binding 200 sent a `HUE_SET`, and
  `SET_PRESET_LEVEL 5` on binding 201 changed the persisted Default On
  Brightness [verified: fake]. Real keypads send only `DO_PUSH`, `DO_RELEASE`,
  `DO_CLICK` and `REQUEST_BUTTON_COLORS` there.
- **Fix:** route by binding: the four keypad commands on 200 to 202, the
  proxy's commands on 5001 only (the motion driver's `GET_SENSOR_VALUE` on 2).

### D-8 (Info): Director logs every light and scene message; Debug Mode stays on

- The light and scene drivers call `C4:SendToDevice` without `logCommand`
  (`common/device.lua:357-366`, `:1386-1399`; `hue_light/driver.lua:1167`,
  `:1473`; `hue_scene/driver.lua:1249`, `:1823`), so Director logs each
  `HUE_HELLO` (name, model, rid) and each `HUE_SET` [verified: API
  32_serial_network_device/_19-SendToDevice: logging is on unless the flag is
  false]. The motion driver and the bridge pass it only in Debug Mode
  (`hue_motion/driver.lua:1172-1183`).
- Debug Mode is a plain property that never switches itself off; a motion
  device left in it prints every `OPENED` / `CLOSED` to the Lua output.
- By design and not a finding: the motion device's Hue Motion row shows
  presence with a time ("Motion since 14:02"), visible to anyone with
  Composer access and in screenshots.
- **Fix:** pass `false, log.enabled("debug")` in the light and scene sends, as
  the motion driver does; optionally switch Debug Mode off after a few hours.

## Answers to the brief's questions

1. **Who can send a device its HUE_\* messages:** any driver in the project;
   no device can tell the bound bridge from another sender (D-1). A spoofing
   driver can report false state, forge or silence motion, re-target a light
   or scene device persistently, and block control; it cannot crash the
   driver or Director (handlers are `pcall`ed).
2. **What a device sends:** always its own `st.rid`; a proxy command cannot
   change it. The load group tag only batches: the bridge covers a room only
   when every lamp of it sent the same set (`bridge/load_groups.lua` header,
   D8). Rates are clamped by the light and by the bridge for scenes. Two
   gaps: a rid planted by D-1 or D-2, and `urgent` requests multiplied by
   fresh button ids (D-4). A whole-home off is reachable only through a
   scene device of the `bridge_home` group, by design.
3. **Input validation:** the keypad settings, default rates, colours, turn-on
   presets, Raise / Restore and load-group levels and times are range-checked
   and NaN-safe. The brightness and colour targets, the scene's rates, the
   button ids and the motion readings are not (D-4, D-5).
4. **Timers and memory:** every timer is tracked and cancelled on unbind and
   destroy (one per kind, re-armed rather than added). The unbounded ones: the
   load-group list (D-3) and the per-button tables of D-4; the turn-on
   module's colour list grows with distinct preset ids but is memory only.
5. **Persistence:** identity (rid, Hue name, model, kind, group type), keypad
   settings, colours and rates, turn-on presets, the saved level, load group
   ids, motion readings and the hold record. Nothing secret: no key, no
   address, no bridge id. A value of the wrong type is coerced (`tostring`) or
   validated and dropped, except the motion `offline_since` and NaN numbers
   (D-5, D-6) and the list length (D-3).
6. **Privacy:** names and rids in warnings and Status; presence and times only
   in the motion rows and in Debug Mode lines; Director's log gets the light
   and scene messages (D-8).

## Earlier fixes rechecked

| Earlier item | Then | Now |
|---|---|---|
| 2026-10-24 #4, device early buffer | capped at 200 | Holds: `common/device.lua:425-437`; bindings before late init keep only the latest per binding (`:533-548`). |
| 2026-10-24 #6, timestamps | fixed on the bridge (`util.date_of`) | Holds on the bridge; the devices' own `os.date` calls were never covered (D-6). |
| 2026-10-24 #9 and 2026-10-25 row 9, inter-driver trust | accepted | Unchanged; the device side is D-1. |
| 2026-10-24 #10 and 2026-10-25 #8, names | `util.display_name` | Holds: every configure the bridge builds passes names through it (`lights.lua:819-830`, `zone_lights.lua:488`, `scenes.lua:851`, `:864`, `motion.lua:938-940`, `owner.shown`). A spoofed configure bypasses it (D-1): display only. |
| 2026-10-24 F12, recall duration | clamped on the bridge | Holds: `scenes.lua:2118-2124`, `off_options`. The scene device itself has no ceiling (D-4). |
| 2026-10-25, keypad settings sent as the bare value | fixed | Holds: `report_setting`, `common/device.lua:740-744`. |
| 2026-10-25, keypad values range-checked, NaN refused | fixed | Holds for settings, default rates and colours (`:233-239`, `:678-680`, `:749-752`); not for `BUTTON_ACTION` ids and actions (D-4). |
| Code analysis item 15, `OnBindingChanged` before late init | open in 2026-10-24 | Fixed: `dev.binding_changed` and `replay_bindings` (`:533-572`). |
| Device timers cancelled on unbind and destroy | sound | Holds: light `:2315-2356`, scene `:2220-2257`, `common/device.lua:1355-1378`; the motion hold record is kept on purpose (#371). |
| 2026-10-24 #14 and 2026-10-25 #14 (dev), `DEV_RELOAD` | fixed (#52) | Release builds register none (`common/device.lua:259-281`), pinned by `tests/spec/device_spec.lua:78-88`. |
| 2026-10-25 row 5, persisted rids | host cannot move | True for the host; the resource type can move (D-2). |

## Looked at, no finding

- `light/turnon.lua`: every number through `num` (NaN and infinities
  refused); persisted On Modes and presets validated at load and dropped with
  one warning; the GET_SETUP parser's patterns are linear.
- `light/state.lua`: `to_proxy_brightness` and the mirek clamp keep the
  proxy's values in range even with NaN in the cache; `caps.params` clamps
  the CCT bounds to 500..20 000 K.
- Raise Level By and Restore Saved Level: parameters range-checked and
  NaN-safe; the stored saved level validated, its `at` tolerated as unknown.
- `common/link.lua`: `since` range-checked, unknown reasons fall back.
- Motion: hold record validated at load (`:545-553`), `resumable` rejects
  clock skew and NaN, a resumed hold never exceeds the hold time; Occupancy
  Hold Time clamped NaN-safely; `TestCondition` reads only its own variables.
- Keypad colours (`SET_BUTTON_COLOR`, `SET_ALL_LED`): six-digit hex only.
- `dev.send` and every bridge send are `pcall`ed; the proxy always hears a
  CHANGED for its CHANGING when a send fails.
- No `loadstring`, no pattern built from input, no format string from input;
  `Adopt Hue Name` renames only the device's own proxy, from a name the
  bridge sanitised (or a spoofer chose, D-1; any driver may rename any device
  itself [verified: API 22_miscellaneous/_32-RenameDevice]).
- A scene of the `bridge_home` group: OFF turns the whole home off. That is
  the scene's group, by design.
