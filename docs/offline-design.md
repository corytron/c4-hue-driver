# Hue devices offline while the bridge is unreachable (#428)

Contract for issue #428, "Bridge unreachable: show Hue devices offline
instead of assuming commands landed". Checklist rows L87 and L56 (bridge
outage) of `docs/c4-lighting-guidelines.md`, with L4, L53, L86, L88 and L89
touched. Release target: 1.5. Lua and documentation only: no `driver.xml`
change, no controller reboot (§9).

## 0. Summary

The owner decided on 2026-11-09, as recommended in #428:

- Hue devices (Hue Lights, zone lights, room lights, Hue Scenes, and Hue
  Motion Sensors where it applies) **go offline once the bridge has been
  unreachable, or has refused the application key, for 5 minutes**. That is
  when the bridge driver already starts looking for a moved bridge
  (`away.FIND_AFTER_S`). A bridge restart takes minutes and stays under it.
- **While a command cannot be delivered, the device must not show it as
  done.** It shows the level it knows, not the target.

What this contract adds:

1. A **link state** on the bridge (`bridge/link.lua`): up, in trouble, or
   offline. It goes offline after 300 s of continuous trouble, and comes back
   at the first proof of contact.
2. One new bridge → device message, **`HUE_BRIDGE_LINK`**, sent to every
   Hue device. Each device treats "offline" as one more reason it cannot be
   reached. It sends `ONLINE_CHANGED` false, says why in Status, and drops
   commands.
3. **Undelivered feedback.** Every command the bridge fails to deliver is
   answered with the bridge's last known state, `reason = "undelivered"`. The
   device closes its target with that state instead of the target.

Closes #428.

## 1. Findings

### 1.1 Control4

| # | Fact | Source |
|---|---|---|
| C1 | The light_v2 proxy starts every device online, for older drivers that never reported. The driver reports changes with `ONLINE_CHANGED { STATE }`. While a light is offline its UI functions are disabled. | [verified: `docs-driverworks-proxyprotocol-lightv2/source/includes/35_Light_v2_protocol_notifications.5_Light_v2_protocol_notifications/_15-ONLINECHANGED.md`] |
| C2 | `GET_SETUP`'s sample answer lists `ONLINE_CHANGED` among the setup values. | [verified: `docs-driverworks-proxyprotocol-lightv2/source/includes/10_light_v2_commands/_16.5-GETSETUP.md:28`] |
| C3 | Fundamentals, dropped connections: a driver should notice that its connection is down (a heartbeat or poll, then a forced reconnect), and handle commands sent meanwhile. A command sent while the device is unavailable fails, and may need to be sent again. The sample polls every 5 s and reconnects after three missed answers. It names no time after which a device counts as offline. | [verified: `docs-driverworks-fundamentals/source/includes/23_command_handling_and_dropped_connections/_1-COMMANDHANDLINGANDDROPPEDCONNECTIONS.md`] |
| C4 | The motion driver's proxy is `contactsingle_motionsensor` (`src/hue_motion/driver.xml:150`). The contact proxy's notifications are `CLOSED`, `OPENED`, `STATE_CLOSED` and `STATE_OPENED` only, so it has **no online mechanism**. The motion driver's own `Online` variable, row and Offline/Online events (ids 5 and 6) are the only ones. | [verified: `docs-driverworks-proxyprotocol/source/includes/112_non_proxy_device_contacts_notifications/` lists those four files; `docs/motion-design.md:76,94-95`] |
| C5 | `C4:SendToDevice` returns nothing and gives no confirmation that the message arrived. Whether it runs the receiver's `ExecuteCommand` before it returns is not documented. | [verified: `docs-driverworks-api/source/includes/32_serial_network_device/_19-SendToDevice.md`]; synchronicity [assumed: unknown] |
| C6 | Static capability changes need a controller reboot on OS 3.4.2. Lua-only changes take effect at once. | [verified: `docs/c4-lighting-guidelines.md` L82; project rules] |

### 1.2 What "unreachable" means in the code today

The bridge driver measures the outage in `src/hue_bridge/bridge/away.lua`.
The fields live in the driver's `state` table (`src/hue_bridge/driver.lua:87-93`).

| Signal | When it is set | When it ends | Source |
|---|---|---|---|
| `stream_down_ms` | Any stream status that is not "Connected since…", including deliberate stops. | The next connect's tier decision. | [verified: `away.lua:215-240`, `:242-257`] |
| A drop of a running stream | `stream_status` sees `was_up` and `stream:running()`. That arms the identity check after `CHECK_S` = 60 s. | — | [verified: `away.lua:225-228`, `:78`] |
| Identity check | Runs at start, at an address change, and 60 s after a drop. It is a keyless `GET /api/0/config`. Until it passes, `identity_ok ~= true` and `bridge_request` refuses every keyed request with "bridge identity not verified yet". A failure is retried every 30 s. | Passing calls `away:answered(ip)`. | [verified: `identity.lua:157-233`, `:54`; `driver.lua:387-395`] |
| `unreachable_ms`, `away_ms` | The identity check found nothing answering (`away:unreachable`), or another bridge at the address (`away:other_bridge`, `away_ms` only). | `away:answered`. | [verified: `away.lua:162-204`] |
| Address follow-up | `want_find` once `unreachable_ms` is 300 s old (`FIND_AFTER_S`), at the last good address only. | — | [verified: `away.lua:76`, `:198-200`] |
| `key_rejected` | A 401/403 on the stream, or one confirmed by a keyed `GET /clip/v2/resource/bridge`. Stops the stream. The background re-check runs at 5 min, 15 min, 1 h, then hourly. | Pair Bridge, an address change, a re-check or connection check that the bridge accepts. | [verified: `driver.lua:340-385`, `:1161-1210`] |
| TLS `not_pinned`, unsupported model | `identity_ok = false` or `tls_verdict = "not_pinned"`: nothing keyed goes out. | The next start or address change. | [verified: `identity.lua:115-150`, `:186-197`] |
| Attention | Bridge away or missing an hour; stream down an hour while the bridge answers. | When the cause ends. | [verified: `away.lua:122-160`, `:67`] |

Facts about how fast an outage is noticed:

- **Request timeouts.** Every `C4:url` request has a 5 s connect timeout and
  a 15 s total timeout. [verified: `src/hue_bridge/bridge/http.lua:26-27`]
- **Silence.** The bridge sends no keepalive on the stream. A connection
  whose far end died without closing it is noticed only by the silence
  watchdog: 600 s by default, 60–3600 s. TCP keepalive would take about 2 h.
  [verified: `docs/design.md:312`, `docs/raw-stream-design.md:320-324`,
  `stream.lua:64`, `netstream.lua:129`]
- **Bridge restart.** A bridge that restarts closes the stream, which
  reconnects with a backoff of 1 to 60 s.
  [verified: `docs/edge-cases-hue.md:108`, `stream.lua:65-66`]
- **Motion.** The motion module has its own grace: 60 s after the stream
  goes down, every motion device says "Bridge not answering since 14:02;
  motion not current". Online is left alone ("about the sensor, not the
  bridge"). [verified: `bridge/motion.lua:156`, `:989`, `:1339-1352`;
  `docs/edge-cases-motion.md:253,280`]

### 1.3 How the bridge talks to devices

- **Messages.** Bridge → light: `HUE_CONFIGURE`, `HUE_STATE`,
  `HUE_FORGOTTEN`. Bridge → scene: `HUE_SCENE_CONFIGURE`, `HUE_SCENE_STATE`,
  `HUE_SCENE_GROUP`, `HUE_SCENE_FORGOTTEN`. Bridge → motion:
  `HUE_MOTION_CONFIGURE`, `HUE_MOTION_STATE`, `HUE_MOTION_FORGOTTEN`.
  Devices → bridge: the `*_HELLO`, `*_GOODBYE`, `*_FORGET` messages, plus
  `HUE_SET`, `HUE_DIM` and the scene commands. No message today carries the
  bridge's own state. [verified: `grep '"HUE_[A-Z_]*"' src`;
  `docs/lights-design.md:42-49`; `docs/scenes-design.md:54`]
- **Unknown commands.** `common/dispatch.lua` routes `ExecuteCommand` by
  name, so a device driver of an older build ignores a message it does not
  know. [verified: `src/common/dispatch.lua:36-46`]
- **Shared plumbing.** All three device drivers build on
  `common/device.lua` (`device.new`, `after_late_init`). Every `src/common/`
  file ships in every `.c4z`. [verified: `src/hue_motion/driver.lua:187-196`;
  `tools/build.sh:103`]
- **Device ids.** `zone_lights:device_ids()` and `motion:device_ids()`
  return `{ [device_id] = true }`. The lights and scenes registries hold
  `device_id` per entry. [verified: `zone_lights.lua:245`, `motion.lua:464`,
  `owner.lua:434-443`]

### 1.4 Commands and what the tile shows today

- **Hue Light, zone and room lights**:
  - The device sends `HUE_SET`/`HUE_DIM` with `C4:SendToDevice`. Its
    `send()` fails only when no bridge is bound.
  - After a send that "succeeds", `arm()` starts a fallback at the ramp plus
    `FALLBACK_MS` = 1000 ms. If no `HUE_STATE` has confirmed by then, the
    target goes into the cache and out as `CHANGED`.
  - With the bridge gone, the tile therefore shows the requested level a
    second after the ramp. This is L87's complaint.
  - #421 D10 holds back reports during a ramp until the ramp ends.
  - [verified: `src/hue_light/driver.lua:23-25`, `:415-439`, `:606-648`;
    `docs/tap-stop-design.md`]
- **Bridge queue** (`bridge/commands.lua`):
  - The queue debounces 80 ms. `set()` always arms a timer, so `flush()`
    runs from a timer or from a previous PUT's `done()`, never inside the
    device's own message.
  - A PUT that fails with a transport error, 429 or 5xx is retried for up to
    30 s after the last change, then dropped (L89, #43). Other 4xx answers
    are dropped at once. So are the final refusals ("not paired",
    "key rejected", "TLS check failed").
  - "bridge identity not verified yet" carries no HTTP code, so it is
    retried.
  - **The device is never told about a failure.**
  - [verified: `commands.lua:25-36`, `:49-58`, `:354-376`, `:476-536`]
- **Scenes**:
  - A recall is one PUT without a retry. On failure, the bridge sends
    `HUE_SCENE_STATE` with the current status, `reason = "recall"`.
  - The scene device's own fallback (2000 ms) may already have assumed the
    recall. A synchronous refusal (identity not verified) answers inside the
    `HUE_SCENE_RECALL` handler.
  - OFF goes through the grouped_light queue. The bridge reports "inactive"
    at once, before the PUT.
  - Level moves also use the grouped_light queue. Their failures are not
    reported.
  - [verified: `bridge/scenes.lua:1661-1685`, `:1870-1887`, `:1981-2024`;
    `src/hue_scene/driver.lua:29`, `:34`]
- **The manuals say so.** The light manual states the current behaviour, as
  do the bridge manual's "When the bridge is offline" and the scene manual.
  [verified: `src/hue_light/www/documentation.html:35`,
  `src/hue_bridge/www/documentation.html:234-239`,
  `src/hue_scene/www/documentation.html:42`]

### 1.5 Per-light reachability today

- Hue reports a bulb's Zigbee reachability in `zigbee_connectivity.status`.
  Anything but `connected` reaches the device as `HUE_STATE online=false`.
  [verified: `bridge/lights.lua:1240-1259`; `docs/edge-cases-hue.md:59`]
- The light's `is_online()` is `blocker() == nil and st.online ~= false`.
  `blocker()` covers forgotten, unbound, no rid, gone and no lights. A scene
  is online when `blocker() == nil`. [verified:
  `src/hue_light/driver.lua:227-249`; `src/hue_scene/driver.lua:203-219`]
- A motion device's Online is the sensor's, from `HUE_MOTION_STATE online`.
  [verified: `src/hue_motion/driver.lua:636-651`, `:1214-1216`]

## 2. Decisions

| # | Decision | Reason |
|---|---|---|
| D1 | The bridge keeps one **link state**: `up`, `trouble` (since a time), or `offline`. `offline` is reached after `OFFLINE_AFTER_S` = **300 s** of continuous trouble. | The owner's decision. It equals `away.FIND_AFTER_S`, and a bridge restart takes minutes. |
| D2 | **Trouble begins** (if not already) at: (a) a drop of a running, connected stream (the point where `away.lua` arms the outage check); (b) an identity check that finds nothing, or another bridge (`away:unreachable`, `away:other_bridge`); (c) a keyed request whose transfer failed with no HTTP status (timeout, refused, no route), except the local `invalid request path`; (d) the condition "not paired, key rejected, TLS `not_pinned`, or `identity_ok == false`", evaluated at every `refresh_status()`. **Contact ends trouble**: (e) the stream connects ("Connected since"); (f) any keyed request answered 2xx; (g) the identity check passes while `keyed_refusal()` is nil. **Neither**: 429/5xx, other 4xx (401/403 go through the existing key confirmation, which reaches (d)), `bridge_request`'s own refusals, a deliberate stream stop, a stream connect attempt that fails before it was ever connected. | Every input already exists in the code (§1.2). Counting only drops of a connected stream (not every failed reconnect) means a bridge that answers while its stream does not is cleared by (g) and never goes offline. Commands work there, and Attention's hour-old "stream down while the bridge answers" covers it. A watchdog reconnect in a quiet house is trouble for about a second: harmless. |
| D3 | The **reason** is derived when the link reports, not passed by the callers, in this order: `not_paired`; `key_rejected`; `blocked` (TLS `not_pinned`, unsupported model); `other_bridge` (`away_other` set); else `not_answering`. A reason change while offline is reported again. `since` stays the start of the trouble. | One place decides the words. A stream drop that turns out to be a key refusal reads right. |
| D4 | The bridge tells devices with **`HUE_BRIDGE_LINK`** (§6.1), sent to every device registered in lights, zone lights, scenes and motion: at the change to offline, at the change back online, at a reason change while offline, and at the **first evaluation of a run** (whatever the state). It is also sent **first in every hello answer** (`HUE_HELLO`, `HUE_SCENE_HELLO`, `HUE_MOTION_HELLO`), before the configure and state, once the first evaluation has run. Nothing is sent during trouble before offline. | One small message. The bridge driver can restart while devices do not, and the reverse. The first broadcast and the hello rule correct either side. Sending the link before the configure stops a restarted device from reporting online and then offline within milliseconds. |
| D5 | **On the device, offline is a blocker**, after forgotten, unbound, unlinked and gone and before no-lights. The device sends `ONLINE_CHANGED` false, Status shows the link text (§6.3), and the Online row reads `Offline`. Commands from any source (Navigator, programming, keypads, Button Links, lighting scenes) are dropped by the existing `ready()` path, before any `CHANGING`, with a log line. LEDs keep the last known state. A target pending or a ramp running when the link goes offline is settled with the cached state and reported. | This is how a light that cannot be reached behaves today (L56). Control4 disables the UI of an offline light (C1). A command sent to an unavailable device fails (C3). Queuing it for later would replay a stale command, which L89 forbids. |
| D6 | **Per-light Zigbee reachability stays as it is.** A device is online only when the link is not offline, its own blockers are clear and Hue does not report it unreachable. While the link is offline, Status shows the link text: the light's Zigbee state is not current then. After recovery the resync's `zigbee_connectivity` decides again. | Two independent conditions, combined with AND. The bridge's text is the fix the owner can act on. |
| D7 | **Back online at the first contact** (D2 e–g), with no settling wait. The state follows from the resync every stream connect already runs: full after anything but a watchdog reconnect (`away:connect_tier`). Contact through (f) or (g) while the stream stays down leaves the state to the 10-minute list reads that already run then. | Control comes back as soon as it works. Flapping is bounded by D1: after contact, a new trouble needs another 300 s, so there is at most one offline/online pair per 5 minutes and no flicker within it. |
| D8 | **Commands during trouble, before offline**, go to the bridge as today. The 30 s retry and drop rule is unchanged (L89). **Every PUT that fails** (each retry, the final drop, the immediate final refusals, a non-retriable 4xx) answers the device with the bridge's cached state, `reason = "undelivered"` (§6.2). This covers lights, zone and room lights, scene level moves and scene OFF. A scene recall or time-based activation that fails sends its existing `HUE_SCENE_STATE` with `reason = "undelivered"` instead of `"recall"`. Undelivered answers that can arise inside a device's own `SendToDevice` (the scene recall path) are sent from a 1 ms timer. | The bridge knows when a command did not land. The device does not (C5). A retry that later succeeds is reported by the stream event or by the resync after reconnect, as any change is. The 1 ms timer covers the unknown synchronicity of `SendToDevice` (C5): an answer handled before the device has armed its fallback would be overwritten by that fallback. |
| D9 | **On an undelivered answer the device**: ends the brightness ramp (#421 D10 does not hold it back); settles every pending target of the kinds the answer carries (for a light, brightness and colour); applies the fields as the bridge's word; and reports `CHANGED` with them. When the answer has no level (a plug, or a light without a model), it reports the level its last `CHANGING` started from (L4). A hold in progress is not ended: its release sends its stop as usual, and that stop's own failure brings the next undelivered answer. | The tile then shows the level the bridge last knew, not the target (the owner's second decision). |
| D10 | The device's **fallback assumption stays** for the case where the bridge says nothing: the link is up, the PUT was accepted, no event came (Hue sends none for an unchanged value). | Removing it would leave tiles stuck in CHANGING (L4). It can only be wrong for a command sent in the first seconds of an outage the bridge has not noticed yet. That is corrected when the PUT fails: at most 5 s (connect timeout) or 15 s (total) later. Recorded as a departure in §5. |
| D11 | **No new probing of a silent stream.** A bridge that lost power without closing the stream is noticed by the first failed keyed request (D2 c) or by the watchdog (600 s). A house with no command meanwhile then goes offline about 15 minutes after the power cut. | An extra keyless probe after a failed command would also fail when Director's four-transfer cap is the cause (`docs/design.md`, "Concurrent transfers"). It would then lock keyed requests and restart a healthy stream: a cure worse than the gap. |
| D12 | **Persistence**: the key `hue_bridge_link` = `{ since = <ms>, reason = <text> }` is written only at the change to offline, and deleted at contact and at an address change that brings contact. On load a stored `since` is kept, so a restart does not reset the 5 minutes. The **first evaluation** of a run waits for the first identity answer or contact, or `FIRST_LOOK_S` = 60 s, whichever comes first. A failed first check with a stored `since` more than 300 s old goes offline at once. Without a stored key, trouble at start counts from the start. | One write per real outage, not one per watchdog reconnect. A controller reboot or driver update during a long outage keeps the tiles grey instead of showing them usable for 5 more minutes. A bridge that came back during the reboot is never shown offline. |
| D13 | **Composer on the bridge**: while offline, Attention gets one item (§6.4), placed right after `away`'s items. It goes by itself at contact. Status, Event Stream and the hour-old items are unchanged. Log lines at info: going offline (with the reason) and coming back (with the duration). | Navigator greys tiles at 5 minutes, so Composer must say why at the same moment. The hour-old items still bring the remedies (check power, Bridges Found). |
| D14 | **Hue Motion Sensor** (where it applies, C4): while the link is offline, the driver's own **Online is No**, the **Offline event fires**, the temperature output says unavailable once, and the readings rows are marked old with the link's `since`. **The contact stays as it is** (motion Q1). On recovery Online returns to the sensor's own value (the Online event fires if that is true), and the resync reports the readings as after a sensor comes back. The 60 s "Bridge not answering…; motion not current" text stays for the first 5 minutes. The proxy itself gets nothing: it has no online mechanism. | The motion device's Online is the only online it has. Its manual already tells programming to check Online before acting on a stale state (`docs/edge-cases-motion.md` C7). This supersedes that document's "bridge away longer: Online unchanged" row (`:280`, the manual's table row `documentation.html:64`) after 5 minutes. Open question Q1. |
| D15 | **No property.** `OFFLINE_AFTER_S` is a module field. Dev builds get a signed dev-loop command, `Link_Offline_After { Seconds }` (10–3600), in `bridge/devtools.lua`, which changes it for the run. Release builds do not ship it. The specs use the fake clock. | The owner chose the time. No dealer setting, and no house-specific tooling in a shipped driver. House checks stay short ("nothing more than about a minute away"). |
| D16 | **No `driver.xml` change**: no capability, property, event, variable or connection is added, removed or renumbered. | No reboot (L82). Nothing released is removed (L79). |

## 3. The link, precisely

```
            trouble (D2 a-d)                 300 s without contact
   up ───────────────────────────▶ trouble ─────────────────────────▶ offline
    ▲                                 │                                  │
    └─────────── contact (D2 e-g) ────┴──────────── contact ─────────────┘
                                                (broadcast "online",
                                                 delete hue_bridge_link)
```

- **`trouble()`**: when up, `since = now`, and a timer is armed for
  `OFFLINE_AFTER_S`. When already in trouble or offline, nothing changes,
  except that a reason change while offline is reported again (D3).
- **Timer fires** (still in trouble): the state becomes offline. The key is
  persisted, every device is told, and Attention refreshes.
- **`contact()`**: the timer is cancelled and `since` cleared. From offline:
  every device is told "online", the key is deleted, and Attention
  refreshes. From trouble: silent.
- **`evaluate()`**: called from the driver's `refresh_status()`. Calls
  `trouble()` when the condition of D2 (d) holds. Never calls `contact()`.
- **First evaluation of a run** (D12): until it has run, `tell()` sends
  nothing and the timer is not armed. It runs at the first identity answer,
  contact, or after `FIRST_LOOK_S`. Then it always broadcasts the current
  state: "offline" when the stored `since` is 300 s old and the trouble
  holds, otherwise "online".

Examples:

- **Bridge restart, 3 min.** t0 the stream drops: trouble since t0. From t0+60
  s, identity checks fail every 30 s. At t0+3 min the identity check passes:
  contact, silent. The stream connects and the full resync runs. Devices
  never go offline. Commands in between are answered "undelivered" about
  80 ms after the command (the identity refusal), and the tiles show the
  known levels.
- **Bridge off for 20 min.** Devices go offline at t0+5 min. The follow-up
  search starts once `unreachable_ms` is 300 s old (about t0+6 min) and finds
  nothing. Attention's hour item never appears. At power-on, contact brings
  everything back: online, then the resync.
- **Key rejected.** Trouble starts at the refusal. Devices go offline 5 min
  later. The key re-check at 5 min (existing) or Pair Bridge brings contact.

## 4. Lifecycle edge cases

"Automatic" means the driver does it by itself. Nothing in this feature is
"offered". The forbidden column lists what must never happen without a
click.

| # | Case (side) | What happens | Decision | Forbidden |
|---|---|---|---|---|
| E1 | Bridge restart or firmware update under 5 min (Hue) | Trouble, then contact. Nothing visible except undelivered answers. | Automatic | Greying tiles before 300 s |
| E2 | Bridge restart over 5 min (Hue) | Offline at 5 min, online at contact, resync. | Automatic | Replaying commands older than 30 s (L89) |
| E3 | Brief Wi-Fi or LAN blip (either) | As E1. A command in the first seconds may show its target until its PUT fails (D10). | Automatic | — |
| E4 | Watchdog reconnect in a quiet house (Control4) | Trouble for about a second, cleared at the reconnect. | Automatic (no effect) | — |
| E5 | Flapping bridge or link (either) | At most one offline/online pair per 5 minutes (D1, D7). | Automatic | Any offline before 300 s of continuous trouble |
| E6 | Bridge address changed by DHCP (Hue) | Trouble from the drop. Offline at 5 min unless found sooner. The existing follow-up search (at 300 s of unreachable) moves the address, then contact. | Automatic (the search is the existing one) | New search triggers; touching an address the owner typed |
| E7 | Owner types a wrong address (Control4) | Trouble from the first failed identity check. Offline after 5 min. Attention's existing "answers at…, not at the typed…" offer applies. | Automatic offline; the fix is the owner's (Bridges Found) | Rewriting the typed address |
| E8 | Owner types the right new address (Control4) | Contact at the identity pass, then online. The stored key is deleted. | Automatic | — |
| E9 | Key revoked or bridge factory-reset (Hue) | `key_rejected`, offline after 5 min. Back at the existing re-check, or at Pair Bridge. | Automatic offline; re-pairing is a click | Re-pairing by itself (the link button needs a person) |
| E10 | Forget Pairing (Control4) | Reason `not_paired`, offline after 5 min. Pair Bridge brings it back. | Automatic | — |
| E11 | TLS check failed, unsupported model, another bridge at the address (either) | Reasons `blocked` or `other_bridge`, offline after 5 min. Remedies unchanged. | Automatic | — |
| E12 | Bridge answers but its stream stays down (Control4 transport) | The identity pass is contact. Never offline. The hour-old Attention item. | Automatic (no effect) | — |
| E13 | Bridge lost power with the stream half-open (Hue) | Noticed at the first failed request or by the watchdog (D11). | Automatic, with a documented delay | A probe that can lock a healthy bridge out |
| E14 | Controller reboot while the bridge is down (Control4) | Proxies start online (C1). With a stored key older than 300 s, offline at the first failed check. Otherwise 5 min after the start. | Automatic | — |
| E15 | Controller reboot; the bridge came back meanwhile (Control4) | The first contact deletes the stored key. Never shown offline. | Automatic | — |
| E16 | All four drivers updated while down (Control4) | As E14. Device hellos get the link first (D4). | Automatic | — |
| E17 | Only the device drivers updated, or reloaded in the dev loop, while offline | Each hello answer starts with `HUE_BRIDGE_LINK` offline. | Automatic | — |
| E18 | Only the bridge driver updated, or reloaded in the dev loop, while devices show offline | The first evaluation always broadcasts, which corrects devices both ways. | Automatic | — |
| E19 | A bulb unreachable while the bridge is fine (Hue) | Unchanged: `HUE_STATE online=false` (D6). | Automatic (existing) | — |
| E20 | Bridge down and a bulb also unreachable (Hue) | Offline by the link. After recovery the resync's Zigbee state decides. | Automatic | — |
| E21 | A device bound or re-linked during the outage (Control4) | Its hello gets the link first. | Automatic | — |
| E22 | A device forgotten or deleted during the outage (Control4) | Its own deliberate text wins (D5 order). A link message to it is harmless. | Automatic | Unbinding or deleting devices because of an outage |
| E23 | Hue items added, removed or renamed during the outage (Hue) | Seen by the resync after contact, as today. | Automatic (existing) | — |
| E24 | Project restored from a backup (Control4) | A restored `hue_bridge_link` behaves as E14 or E15. Hellos get the link first. | Automatic | — |
| E25 | Commands while offline (Control4) | Dropped at the device, with no `CHANGING` and nothing queued (D5). | Automatic | Queuing for later |
| E26 | Commands during trouble before offline (Control4) | Sent. 30 s bounded retry. An undelivered answer at every failure (D8, D9). | Automatic | Showing the target after a failure |
| E27 | Diagnostics stops the stream on purpose (Control4) | Not trouble (D2). Devices stay online, and commands work over REST. | Automatic (no effect) | — |
| E28 | Programming on motion Online or the Offline event (Control4) | Now changes after 5 minutes of bridge outage (D14). | Automatic, in the changelog | — |
| E29 | Dev or test round (Control4) | `Link_Offline_After` in dev builds only (D15). | Click (dev loop) | A release property |

## 5. Control4 guidelines

Sources read: `27_proxy_specific_info/_50-LIGHTV2BESTPRACTICE.md`,
`_51-LIGHTV2EXTRAS.md` (Fundamentals), the light_v2 `ONLINE_CHANGED`
notification (C1, C2), Fundamentals §23 (C3), and the contact proxy's
notifications (C4).

| Row | How this meets it |
|---|---|
| L4 (every CHANGING closed) | An undelivered answer closes the target with the bridge's state, or with the CHANGING's start level when the bridge has none (D9). Offline commands send no CHANGING (D5). The fallback stays (D10). |
| L53 (LEDs show the real state) | LEDs follow the cache, which an undelivered answer resets to the bridge's word (D9). While offline they keep the last known state. |
| L55 (slider settles) | The slider settles at the bridge's level after a failed command, not at the dragged one. |
| L56 (offline tile disabled; driver must report) | `ONLINE_CHANGED` false after 300 s of trouble, true at contact. The proxy's start-up "online" is corrected at the first evaluation or hello (D4, D12). |
| L86 (report at start and on every change) | The link becomes one more input of `is_online()` on every device (D5, D6), reported at each link change. |
| L87 (commands must not look delivered; offline after a while) | Meets with this contract: D1, D8, D9. **Departure** (D10): for a command sent in the first seconds of an outage the bridge has not yet noticed, the tile can show the target for up to 5–15 s before the failed PUT corrects it. Hue has no acknowledgement other than the PUT's answer, and its event, which a dead bridge cannot send. |
| L88 (status rows say what is wrong and what to do) | Device Status names the bridge's condition and since when (§6.3). The bridge's Attention item says the devices come back by themselves, or names the click (§6.4). |
| L89 (bounded retry, then drop) | Unchanged: 30 s retry during trouble, then drop. Offline commands are dropped at once. |
| L79, L82 | No events, variables or capabilities change (D16). |

## 6. Interfaces

### 6.1 `HUE_BRIDGE_LINK` (bridge → every device)

| Param | Values | When |
|---|---|---|
| `state` | `"online"` or `"offline"` | always |
| `reason` | `not_answering`, `other_bridge`, `key_rejected`, `blocked`, `not_paired` | with `offline` |
| `since` | epoch **seconds** as a decimal string: when the trouble began | with `offline` |

A device ignores a message with an unknown `state`, and logs it once. A
device of an older build ignores the whole message (§1.3).

### 6.2 `reason = "undelivered"` on existing messages

| Message | Sent by | Carries |
|---|---|---|
| `HUE_STATE` (light) | `lights:undelivered(rid)` after a failed PUT on that rid | The cached model, as `send_state(rid, "undelivered")`. With no model: `{ rid, reason }` only. |
| `HUE_STATE` (zone or room device) | `zone_lights:undelivered(grouped_rid)`, for each zone device on that grouped_light | `send_state(rid, "undelivered")` |
| `HUE_SCENE_GROUP` | `scenes:undelivered_group(grouped_rid)`, for each linked scene on that group | The cached `on` and `level` of the group, plus `reason`. |
| `HUE_SCENE_STATE` | Scene recall or activate failure (today's `send_state(rid, "recall")` on the failure paths, `scenes.lua:1683`, `:1885`; not the success paths, not `:2014`) | `active` = the current status, `reason = "undelivered"`, sent from `ctx.set_timer(1, …)` |

Device handling (D9):

- **Light** `HUE_STATE` with `undelivered`: skip `hold_back`, run
  `end_ramp()`, `settle("brightness")`, `settle("color")`, apply the fields,
  then `report_brightness()` and `report_color()`. When
  `report_brightness()` reports nothing, send
  `LIGHT_BRIGHTNESS_CHANGED` with the `from` that `arm()` now stores (the
  CHANGING's current level).
- **Scene** `HUE_SCENE_STATE` with `undelivered`: skip `hold_status`, end the
  ramp, `settle()`, take the status, `report_brightness()`.
- **Scene** `HUE_SCENE_GROUP` with `undelivered`: end the ramp, settle a
  pending `level` or `switch` target, take on and level, and report.

### 6.3 Device texts (Status; Online row `Offline`)

| reason | Light, zone, room, scene Status (at most 60 chars) |
|---|---|
| `not_answering` | `Hue Bridge not answering since 14:02` |
| `other_bridge` | `Hue Bridge not at its address since 14:02` |
| `key_rejected` | `Hue Bridge refuses the pairing since 14:02` |
| `blocked` | `Hue Bridge not usable since 14:02 (see its Status)` |
| `not_paired` | `Hue Bridge not paired since 14:02` |

- **Time format.** `14:02` for today, `10-26 14:02` for another day: the
  same rule as `away:clock`. It is computed from `since` whenever Status is
  refreshed.
- **Motion.** The motion device appends `; motion not current`. Its Online
  row reads `No`.
- **Log.** The device logs at info: `offline: <text>` and
  `online: the Hue Bridge answers again`. It logs a dropped command as today:
  `<command> dropped: <reason>`. `blocker()` returns the Status text with
  its first letter lowered.

### 6.4 Bridge Attention item (while offline)

`Hue devices offline since 14:07: the bridge <phrase> since 14:02; they come back by themselves when it answers`

| reason | phrase | tail instead of "they come back…" |
|---|---|---|
| `not_answering` | `has not answered` | — |
| `other_bridge` | `is not at its address` | — |
| `key_rejected` | `refuses the pairing` | `they come back once it accepts it (re-pair with Pair Bridge if it stays)` |
| `blocked` | `cannot be used` | `see Status` |
| `not_paired` | `is not paired` | `run Pair Bridge` |

The first time is `since + OFFLINE_AFTER_S`. The item wraps onto the
Attention continuation rows like every other.

### 6.5 Constants and persisted keys

| Name | Value | Where |
|---|---|---|
| `link.OFFLINE_AFTER_S` | 300 | `bridge/link.lua` |
| `link.FIRST_LOOK_S` | 60 | `bridge/link.lua` |
| `link.KEY` | `"hue_bridge_link"`, `{ since = ms, reason = text }`. A malformed value is deleted on load (L83). | `C4:PersistSetValue` / `PersistGetValue` / `PersistDeleteValue` [verified: API 26.5, as `away.lua` uses them] |
| Timer | `C4:SetTimer(ms, fn)` with `:Cancel()` | [verified: API 34/_1, as `away.lua:306`] |

### 6.6 Changes by file

**New `src/hue_bridge/bridge/link.lua`.**

- `link.new(ctx)`. ctx fields:
  - `state`;
  - `paired()`, `keyed_refusal()`;
  - `now_ms()`;
  - `device_ids()`: the union set of all four modules;
  - `send(device_id, cmd, params)`;
  - `refresh()` (Attention);
  - `log`;
  - `clock(ms)`: `away:clock`.
- Methods: `load()`, `trouble()`, `contact()`, `evaluate()`, `first_look()`
  (the identity callback, D12), `status()` returning `"up"`, `"trouble"` or
  `"offline"`, `offline()`, `params()`, `tell(device_id)`,
  `attention_items()`, `cancel()` (for `OnDriverDestroyed`), and
  `reason()` (D3).
- Every timer callback is pcall-wrapped and ignores a destroyed driver
  (`state.destroyed`).

**`src/hue_bridge/bridge/away.lua`.** ctx gains an optional `link`; every
call is nil-safe.

- `stream_status`: on a drop of a running, connected stream (beside
  `arm_outage_check`), call `link:trouble()`. On "Connected since", call
  `link:contact()`.
- `unreachable` and `other_bridge`: call `link:trouble()`.
- `answered`: call `link:contact()` when `ctx.keyed_refusal() == nil`, and
  `link:first_look()` in every case.
- The failure branches of the identity check reach `first_look` through
  `unreachable` and `other_bridge`.

**`src/hue_bridge/bridge/commands.lua`.**

- New option `on_undelivered(rid, err)`, pcall-wrapped. It is called in
  `on_done` for every non-ok result: the final refusal, each retriable
  failure (before the retry or the drop), and other 4xx.
- It is also called when a raising `send` drops the state.
- It is not called for `ok`.

**`src/hue_bridge/bridge/lights.lua`.**

- `lights:undelivered(rid)`: `send_state(rid, "undelivered")`, or the bare
  `{ rid, reason }` when the light has no model.
- Returns false for an unregistered rid.

**`src/hue_bridge/bridge/zone_lights.lua`.**

- `zone_lights:undelivered(grouped_rid)`: `send_state` to each registered
  entry whose grouped_light is `grouped_rid`.

**`src/hue_bridge/bridge/scenes.lua`.**

- `scenes:undelivered_group(grouped_rid)`: `send_group_for` with the cached
  group state and `reason = "undelivered"`.
- The failure `send_state` calls use `reason = "undelivered"` through
  `ctx.set_timer(1, …)`.
- The success paths and the "nothing queued" path keep `"recall"`.

**`src/hue_bridge/bridge/devtools.lua`.**

- The signed dev command `Link_Offline_After { Seconds }`, clamped to
  10–3600. It sets `link.OFFLINE_AFTER_S` for the run and writes
  `Last Action`.
- Dev builds only.

**`src/hue_bridge/driver.lua`** (coordinator).

- Wiring:
  - `state.link = link_mod.new{…}` after `state.away`, passed to `away` as
    `ctx.link`;
  - `link:load()` in late init after `away:load()`;
  - `link:cancel()` in `OnDriverDestroyed`.
- `bridge_request`'s callback:
  - `r.ok` → `link:contact()`;
  - `r.code == nil and r.err ~= http.INVALID_PATH` → `link:trouble()`.
  - Only results that came back through `http.request` count, not the early
    refusals.
- `refresh_status()` → `link:evaluate()`.
- Queues: `new_queue` passes `on_undelivered = state.lights:undelivered`.
  `new_group_queue` passes both `zone_lights:undelivered` and
  `scenes:undelivered_group`.
- Hello handlers: `HUE_HELLO`, `HUE_SCENE_HELLO` and `HUE_MOTION_HELLO` call
  `state.link:tell(tonumber(params.device_id))` first.
- `attention_text()`: `link:attention_items()` after `away`'s items.
- A `link_device_ids()` helper builds the union of the four modules.
- Keep the main chunk under the local limits: `python3 tools/lua_limits.py`
  (137 of 180 today). `state.link` lives in the state table, and only the
  `require` is a new local.

**New `src/common/link.lua`** (pure, shared by the three device drivers).

- `parse(params)` → `{ offline, reason, since }` or nil.
- `text(link, now_s)` → the §6.3 text.
- `clock(since_s, now_s)`.

**`src/common/device.lua`.**

- Registers `dispatch.commands["HUE_BRIDGE_LINK"] = after_late_init(...)`.
- Keeps `dev.link` (nil until told).
- Exposes `dev.link_offline()` and `dev.link_text()`.
- Calls the hook `dev.on_link(link, changed)`. The default does nothing.

**`src/hue_light/driver.lua`.**

- `blocker()` gains the link text after `gone` and before `no_lights`.
- `refresh_status()` shows it.
- `dev.on_link`: when going offline, settle pending targets and end the ramp
  with the cache reported; then `report_online()` and `refresh_status()`.
- The `HUE_STATE` `undelivered` branch (§6.2).
- `arm()` keeps `from`.

**`src/hue_scene/driver.lua`.**

- `blocker()` and the Status text, as for the light.
- `dev.on_link` the same.
- The `undelivered` branches of `HUE_SCENE_STATE` and `HUE_SCENE_GROUP`.

**`src/hue_motion/driver.lua`.**

- Effective Online = `pv.online ~= false and not dev.link_offline()`, with
  Online true needing `pv.online == true`. Events, the variable, the row,
  `offline_since` and the temperature output follow the effective value.
- `pv.online` keeps the sensor's word, persisted as today.
- Status: the link text plus `; motion not current`, after the deliberate
  ends (gone, forgotten, unbound).
- The contact is never touched (D14).

**Manuals.** Four `documentation.html` files, at the places in §1.4 and
`src/hue_motion/www/documentation.html:44,64,136`.

**Docs.**

- `docs/c4-lighting-guidelines.md`: L87 and L4 notes, L56; §4 item 3 done.
- `docs/edge-cases-hue.md:108`: the bridge restart row.
- `docs/edge-cases-motion.md:280`: the bridge-away row, after 5 min.
- `docs/lights-design.md`, `docs/scenes-design.md`, `docs/motion-design.md`:
  the message tables (`HUE_BRIDGE_LINK`, `undelivered`).

## 7. Implementation split

Disjoint file sets. Each part runs its own specs, `luacheck` on its files,
and `busted` on its specs. Lua 5.1, tabs, `.luacheckrc`, the fake C4 runtime
under `tests/`.

| Part | Owns (create or edit) | Specs |
|---|---|---|
| A: bridge link | `src/hue_bridge/bridge/link.lua` (new), `src/hue_bridge/bridge/away.lua`, `src/hue_bridge/bridge/devtools.lua` | `tests/spec/link_spec.lua` (new), `tests/spec/away_spec.lua` |
| B: undelivered on the bridge | `src/hue_bridge/bridge/commands.lua`, `lights.lua`, `zone_lights.lua`, `scenes.lua` | `tests/spec/commands_spec.lua`, `lights_spec.lua`, `zone_lights_spec.lua`, `scenes_spec.lua` |
| C: light and scene devices | `src/common/link.lua` (new), `src/common/device.lua`, `src/hue_light/driver.lua`, `src/hue_scene/driver.lua` | `tests/spec/common_link_spec.lua` (new), `device_spec.lua`, `light_driver_spec.lua`, `scene_driver_spec.lua` |
| D: motion device | `src/hue_motion/driver.lua` | `tests/spec/motion_driver_spec.lua` |
| E: documentation | the four `src/*/www/documentation.html`, `docs/c4-lighting-guidelines.md`, `docs/edge-cases-hue.md`, `docs/edge-cases-motion.md`, `docs/lights-design.md`, `docs/scenes-design.md`, `docs/motion-design.md` | `python3 tools/check_links.py` |

- Part D uses `dev.link_offline()` and `common/link.lua` from Part C. Both
  are fixed by §6. D may stub them in its spec until C lands.
- **Coordinator:** `src/hue_bridge/driver.lua` (§6.6), a new
  `tests/spec/offline_roundtrip_spec.lua` (end to end through the fake
  harness), `tests/fixtures/ledger.lua` (a G row: the
  `HUE_BRIDGE_LINK` message for `hue_light`, `hue_scene` and `hue_motion`),
  `CHANGELOG.md`, `docs/composer-checklist.md` (§8.2), `docs/status.md`.
  No `driver.xml` and no `tools/build.sh` change.
- **Siblings.** `docs/turn-on-design.md` (#429, #427, #430) and
  `docs/load-groups-design.md` (#435) may also touch
  `src/hue_light/driver.lua` and `src/common/device.lua`. The coordinator
  runs Part C after or apart from their device-side parts, never at the same
  time on the same files.

## 8. Tests

### 8.1 Busted specs

- **`link_spec.lua`**:
  - trouble then 299 s: still online, nothing sent; at 300 s: one broadcast,
    offline, key persisted;
  - contact at 299 s: silent, timer cancelled;
  - contact while offline: "online" to every device, key deleted, Attention
    refreshed;
  - flapping: contact then trouble resets the count;
  - reason order (D3), and a reason change while offline re-sends;
  - `evaluate()` with key rejected, not paired, TLS or `identity_ok == false`
    starts trouble, and never clears it;
  - first look: silent before it, always broadcasts after it, stored
    `since` older than 300 s → offline at the first failed check, contact →
    online and key deleted, `FIRST_LOOK_S` fallback;
  - a malformed stored value is deleted;
  - `tell()` before and after the first look;
  - Attention texts for every reason; `cancel()`.
- **`away_spec.lua`**:
  - a connected-stream drop calls `link:trouble()`; a deliberate stop and a
    failed attempt do not;
  - "Connected since" calls `contact()`;
  - `unreachable` and `other_bridge` call `trouble()`;
  - `answered` calls `contact()` only without a keyed refusal, and always
    calls `first_look()`;
  - a nil `link` is safe.
- **`commands_spec.lua`**:
  - `on_undelivered` once per failed PUT: retry, age drop, final refusal,
    other 4xx, raising send; never on ok;
  - a callback that raises does not break the queue.
- **`lights_spec.lua`, `zone_lights_spec.lua`, `scenes_spec.lua`**:
  - `undelivered` sends the cached state with the reason; a bare
    `{ rid, reason }` without a model;
  - zone and scene fan-out per grouped_light;
  - recall failure → `HUE_SCENE_STATE undelivered` from a timer, never
    synchronously; success still `"recall"`.
- **`common_link_spec.lua`**: parse, the texts (all five, under 60 chars),
  the clock for today and another day, unknown states.
- **`device_spec.lua`**: `HUE_BRIDGE_LINK` before late init is buffered; the
  hook runs with `changed`.
- **`light_driver_spec.lua`**:
  - offline → `ONLINE_CHANGED` false, Status and Online rows, commands
    dropped with no CHANGING, keypad press dropped, LEDs unchanged;
  - link offline + Zigbee online → offline; online + Zigbee unreachable →
    offline; both online → online;
  - undelivered during a tap ramp ends it and reports the cache; undelivered
    before the fallback → no later assumption; no cached level → CHANGED at
    the CHANGING's start;
  - going offline with a target pending settles it;
  - a hello answer with the link first → no online-then-offline;
  - zone device the same.
- **`scene_driver_spec.lua`**: offline blocker; undelivered recall during a
  tap fade; undelivered `HUE_SCENE_GROUP` settles a level move and an OFF.
- **`motion_driver_spec.lua`**:
  - link offline → Online No, Offline event once, temperature unavailable
    once, contact unchanged, Status text;
  - online again → the Online event only if the sensor is online;
  - sensor unreachable during the outage → stays offline, no extra events;
  - `pv.online` persisted as the sensor's.
- **`offline_roundtrip_spec.lua`** (coordinator):
  - bridge driver plus a light, a zone, a scene and a motion device on the
    fake runtime;
  - stream drop, identity failures, 300 s → every device offline; stream
    connect → every device online, then the resync's states;
  - a light command at t0+90 s → `undelivered` and the tile at the cached
    level;
  - a restart with a stored outage → offline at the first failed check.

Done means: `tools/check.sh` (all four CI checks) and `tools/build.sh`
pass.

### 8.2 Composer and house checks (text for `docs/composer-checklist.md`)

```
## N. Bridge outage: devices offline (#428)

Needs a dev build with the dev loop (docs/dev-loop.md). The Windows session
acts on the owner's standing approval. No controller reboot: nothing in
driver.xml changes.

99. **Short offline time for the test.** `tools/devctl.py run
    "Link_Offline_After" Seconds=30`. The bridge's Last Action confirms 30 s.
    - **Done:** open.
100. **Make the bridge unreachable.** Note the Hue Bridge's Bridge IP
    Address, then set it to an address nothing answers at (for example
    192.0.2.250). Within a few seconds Status reads `Bridge at 192.0.2.250
    not reachable (…); checking again in 30 s`. Paste Status and Event Stream.
    - **Done:** open.
101. **A command during the grace** (within 30 s of step 100). On a
    Navigator, tap a Hue Light tile from off to on. The tile does not stay
    on: within about a second it shows the light off again. The light's Lua
    output (Debug Mode On) shows the HUE_STATE with reason undelivered.
    Paste the tile and the lines.
    - **Done:** open.
102. **Offline after 30 s.** About 30 s after step 100: every Hue Light,
    zone light, room light and Hue Scene tile is disabled on the Navigator.
    Their Status reads `Hue Bridge not answering since <time>` and Online
    reads `Offline`. The Hue Bridge's Attention reads `Hue devices offline
    since <time>: the bridge has not answered since <time>; they come back by
    themselves when it answers`. A Hue Motion Sensor reads Online `No`, and
    Status `Hue Bridge not answering since <time>; motion not current`.
    Paste each.
    - **Done:** open.
103. **Keypad while offline.** Tap the top button of a keypad bound to a Hue
    Light: the lamp does nothing, the LED stays as it was, and the light's
    Lua output says the command was dropped.
    - **Done:** open.
104. **Back online.** Set Bridge IP Address back to the noted value. Within
    a few seconds Status reads `Paired`, Event Stream `Connected since …`,
    every tile is usable again and shows the lamps' real state, the
    Attention item is gone, and the motion device reads Online `Yes`. Paste
    the rows and the time from the Set to usable tiles.
    - **Done:** open.
105. **Release build.** Install the release build as usual. The 30 s
    setting is gone (5 minutes again). Nothing else to check.
    - **Done:** open.
```

## 9. Reboot and changelog

- **Controller reboot:** none. No `driver.xml` change (D16). Lua and the
  Documentation tabs only, effective at the update.
- **`CHANGELOG.md`, `## Unreleased`:**

```
### Changed
- When the Hue bridge has not answered, or has refused the pairing, for 5
  minutes, every Hue Light, zone light, room light and Hue Scene goes
  offline: Navigators disable its tile and keypad buttons do nothing until
  the bridge answers again, when they come back by themselves. The Hue
  Bridge's Attention says why. Shorter outages, such as a bridge restart,
  change nothing (#428).
- A Hue Motion Sensor's Online turns No after the same 5 minutes, and its
  Offline event fires; its motion state stays as it was. Programming that
  uses Online or the Offline event now also sees a long bridge outage
  (#428).
- A command that does not reach the Hue bridge no longer shows as done: the
  tile and keypad LEDs go back to what the light last reported (#428).
```

## 10. Open questions for the owner

Answered by the owner on 2026-11-09: yes, motion devices go offline after the same 5 minutes (D14).

1. **Motion Online and the Offline event during a long bridge outage
   (D14).** The contact proxy has no online notification. The only "where it
   applies" for a motion device is its own Online, which fires the Offline
   event other programming may use (for battery or sensor faults, say).
   Recommended: yes, after the same 5 minutes, as decided in D14. The
   alternative is to leave motion Online alone (today's rule) and rely on its
   Status text.
