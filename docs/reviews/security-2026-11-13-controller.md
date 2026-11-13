# Security review C, 2026-11-13: the Hue Bridge driver's controller surface (#480)

Reviewer C of [`../security-review-design.md`](../security-review-design.md):
the Hue Bridge driver as a receiver of input from Composer, from programming
and from other drivers in the project. Read-only review of the worktree on
branch `security/review-480`. Nothing was sent to the house's bridge, the
controller or any LAN host. Line numbers are those of this worktree.

Read whole: `src/hue_bridge/driver.lua`, `driver.xml`, `src/common/dispatch.lua`,
`log.lua`, the signature, command and reload parts of `devloop.lua`,
`bridge/devtools.lua` (install, the handlers that stay in the dispatch table,
`persist_refusal`, `path_refusal`, the redactor), `bridge/actions.lua` (runners
and aliases), `credentials.lua`, `rows.lua`, `project.lua`, `tasks.lua`,
`config.lua`. Read for their input handling: `automations.lua` (every write
path), `names.lua` (resolve, push, the name forms), `owner.lua` (hello,
goodbye, defaults, the names handed to `AddDevice`/`RenameDevice`),
`registry.lua` (load), `commands.lua` (merge, body), `group_hold.lua`,
`load_groups.lua` (memberships, command), the scene messages of `scenes.lua`,
`housekeeping.lua` (header and timers), `sweep.lua` (header),
`bridges_found.lua` (`on_pick`), the identity check's use of `/api/0/config`
(`identity.lua`), `tools/build.sh` (release strip).

SDK citations: "API x/_y" is
`~/c4-tools/reference/docs-driverworks-api/source/includes/x/_y-*.md`,
"FUND x/_y" the same under `docs-driverworks-fundamentals`.

## Summary

No critical, high or medium finding. A release build contains nothing that
compiles or runs Lua it receives. No command takes a method or a path for a
Hue request, and nothing returns, logs or shows the application key. The
earlier fixes in this area hold, with two exceptions. 2026-10-25 finding 9
has partly regressed in dev builds (C-2). 2026-10-25 finding 8 left two
property rows unfixed (C-4).

The finding that matters most is C-1, the DriverWorks trust model. Every
bridge action and every device message runs for an `ExecuteCommand` from any
driver in the project. Since the last review that also covers two writes to
the Hue side: switching Hue automations off or on, and bulk renames.

| Id | Rating | Build | Title |
|---|---|---|---|
| C-1 | Low | release | Any driver in the project can run every bridge action, now including Hue-side writes (automations, names) and Forget Pairing; the Confirm parameters are not authorisation |
| C-2 | Low | dev only | Four development handlers are back in `dispatch.commands`, reachable unsigned by any driver, one of them contacting an internet host; forwarded log lines are retained without a length cap |
| C-3 | Info | release | NaN and infinity from `HUE_SET` / `HUE_DIM` reach the light PUT body; the light path does not clamp `rate` |
| C-4 | Info | release | Text from callers and from the bridge reaches Composer rows unescaped or uncapped: Last Action echoes, Bridge Model and Bridge Firmware, list rows and pickers |
| C-5 | Info | release | Debug Mode never turns itself off; while On, Director logs every bridge-to-device message with names, levels and presence |

## Findings

### C-1 (Low, release): every action and device message trusts any driver in the project

- **Attacker:** "The controller" (contract §3). A driver in the same project,
  third-party or compromised, buggy or malicious. It needs only the bridge's
  device id and `C4:SendToDevice`. `ExecuteCommand` has no sender parameter
  [verified: API 5_director_command/_1-ExecuteCommand]. A command named
  `LUA_ACTION` with an `ACTION` parameter is exactly what Composer's Actions
  tab sends (same page), so it can be forged too.
- **What such a driver can make a release bridge do**, through the 52
  command names in `dispatch.commands` (all listed by scratch probe P1):
  - **Forget the pairing.** `Forget Pairing` with `Confirm = "Yes, forget"`
    deletes the key from the store and stops the stream (`driver.lua:2449-2459`,
    `:2020-2051`). Getting it back needs someone to press the bridge's link
    button. [verified: probe P2. After one plain `ExecuteCommand`, the key's
    store entry is gone and Status reads "Not paired".]
  - **Change Hue automations (#280).** `Hue Automations` with
    `Automation = "off:all"` switches off every Hue automation that is in
    conflict with Control4. `"other:<rid>"` switches on an automation that
    the household switched off in the Hue app, and `"on:all"` restores
    everything (`driver.lua:2402-2406`, `automations.lua:2133-2231`).
    [verified: read; `tests/spec/automations_roundtrip_spec.lua:187-191`
    drives these writes with the same `ExecuteCommand("LUA_ACTION", …)`.]
  - **Rename in bulk on either side.** `Resolve Names` with `"c2h:all"` or
    `"h2c:all"` (`names.lua:1209-1233`).
  - **Delete or create devices.** `Forget Device` forgets devices, and so do
    the hidden aliases `Forget Light`, `Forget Scene` and
    `Forget Motion Device`, which fill in `Confirm` themselves
    (`actions.lua:1390-1392`, `:1405-1407`, `:1419-1421`). `HUE_GOODBYE`
    with only a registered rid tombstones the entry (`owner.lua:689-727`).
    `Add From Hue` with `"all:lights"` or `"f:scenes:<group>"` creates
    devices.
  - **Pairing, lights and the stream.** `Pair Bridge` opens the two-minute
    pairing window. `HUE_SET`, `HUE_DIM` and `HUE_SCENE_*` control any
    registered light, zone or scene. `Diagnostics` with `diag:disconnect`
    stops the event stream until the next start.
- **What it cannot do** [verified: read]:
  - Send an arbitrary Hue request. No release handler takes a method or a
    path. Every request is a literal `/clip/v2/resource/<type>/` prefix plus
    a registered rid or an automation instance from the current view
    (`automations.lua:1671-1676`, `:1835-1840`, `:1936-1940`).
  - Read the key. No handler returns, prints or shows it. `SendToDevice`
    returns nothing to its caller [API 32_serial_network_device/_19-SendToDevice],
    and the persistence calls take no device id, so they work on the
    driver's own store only [API 26.5_persistence/_3-PersistGetValue].
- **Impact:** This touches the pairing (contract §2) and the owner's Hue-side
  configuration. Everything is reversible, and every action writes Last
  Action, so a forged action is visible there. It is the trust model that
  2026-10-24 finding 9 accepted. It is listed again because the surface now
  includes Hue-side writes (the #280 automations, the 1.2 names), and #280
  D1 promises that "the remedy only follows a click". In code that means it
  follows an `ExecuteCommand`, which any driver can send. A driver that can
  do this can also command every other device in the house, so the extra
  harm is small.
- **Where:** `src/common/dispatch.lua:35-45` (`execute_command`);
  `src/hue_bridge/driver.lua:2402`, `:2431-2435`, `:2449-2459`, `:2473-2475`.
- **Suggested fix:**
  - Write the boundary down in `SECURITY.md` and the manual: any driver in
    the project can run the bridge's actions, so only trusted drivers
    belong in the project.
  - Make the #280 contract's D1 say "a click or an `ExecuteCommand`".
  - Cheap hardening: accept `Forget Pairing`, `Hue Automations` writes and
    `Resolve Names` bulk rows only in their `LUA_ACTION` form, as Composer
    sends them. That stops accidental name collisions, not a deliberate
    forger.
  - For device messages, the bridge could give each bound device a random
    token in its configuration message and require it on `HUE_GOODBYE`,
    `HUE_FORGET` and the scene commands (2026-10-24 finding 14's idea).
    That limits forgery to drivers bound as devices.

### C-2 (Low, dev builds only): unsigned development handlers back in the dispatch table

- **Attacker:** Any driver in the project, while a `--dev` build is
  installed.
- **What changed:** The 2026-10-25 fix of finding 9
  (`docs/security-fixes-design.md` §2) kept in `dispatch.commands` only what
  Composer itself sends: the three actions of the DEV-ONLY block of
  `driver.xml`, plus `HUE_LOG`. In 1.2 those three actions moved into
  Diagnostics' list (`docs/simplify-actions-design.md` §3.3), and the
  DEV-ONLY block now holds only the `Diagnostic Server` and `Dev Server`
  properties (`driver.xml:239-253`). `devtools.install` still registers the
  handlers in `dispatch.commands` (`devtools.lua:907-912`), and adds
  `Probe_Picker_Folders`. None of them is a Composer action any more, so
  each answers an unsigned `ExecuteCommand` from any driver.
- **What each one does:**
  - `Check CA Pinning` makes the controller open a TLS connection to an
    internet host, `pinning.PUBLIC_HOST` = example.com
    (`devtools.lua:731-736`). The owner's rule is "no internet reliance".
  - `Connection Test` stops the event stream and runs the connection
    experiment with the key against the verified bridge
    (`devtools.lua:741-795`). With `Target = "Diagnostic Server"` it uses
    unverified TLS against the owner's `Diagnostic Server` host, without the
    key.
  - `Reload Credentials` prints the credential summaries, which include the
    key's length, the bridge id and the address.
  - `Probe Picker Folders` prints every parameter it is given.
  - Neither `HUE_LOG` (`devtools.lua:387-396`) nor `Probe Picker Folders`
    caps the length of a line. The loop keeps up to 500 captured lines of
    any size (`devloop.lua:87`, `:183-188`) and ships them in clear with
    `POST /log`. While the dev server is unreachable, a driver can make the
    bridge's Lua state hold 500 lines of its choosing [assumed: no other
    cap].
- **Verified:** scratch probe P3 in a dev configuration. All four are in the
  table. One plain `ExecuteCommand("Check CA Pinning", {})` started a
  transfer to `https://example.com/` and set Status to "Checking CA pinning
  against example.com". `Probe Picker Folders` printed a parameter that the
  "other driver" supplied.
- **Impact:** No key exposure. It is the dev-only surface of 2026-10-25
  finding 9 (rated Medium then, because of the key), back in a smaller form.
  The documents now describe what the code no longer does:
  `docs/dev-loop.md:84` and `:619`, `devtools.lua:24` and `:874`,
  `docs/security-fixes-design.md` §2.
- **Suggested fix:**
  - Keep the four handlers in a private table: `devtools.diagnostics`, read
    by `dev_command` in `driver.lua:2246-2251`, and the signed table (where
    `Probe_Picker_Folders` already is).
  - Register only `Dev_Server` and `HUE_LOG` in the dispatch tables.
  - Cap `HUE_LOG`'s line, for example at 2,000 bytes, and cap each line in
    `capture`.
  - Update the four documents.
  - Add one spec: an unsigned `ExecuteCommand` for each handler starts no
    transfer and prints nothing.

### C-3 (Info, release): NaN and infinity reach the light PUT body

- **Attacker:** Any driver sending `HUE_SET` or `HUE_DIM` for a registered
  rid, or a device driver that computes a bad number.
- **Cause:** `tonumber` under Lua 5.1 accepts `"nan"` and `"inf"`.
  `commands.lua` `clamp` (`:98-102`) lets NaN through, because both
  comparisons are false. `merge` (`:217-221`) and `body` (`:301-350`) keep
  it. `rate` and `HUE_DIM`'s `duration` are not clamped on the light path
  (`driver.lua:1915`, `:1968`), while scenes and zone lights clamp theirs to
  `DIM_MAX_DURATION` (`scenes.lua:2379-2383`).
- **Verified:** a `lua5.1` run of `commands.body`. `{brightness = nan, x = nan, rate = inf}`
  gives `dimming.brightness = -nan`, `color.xy.x = -nan` and
  `dynamics.duration = inf`. A rate of 1e15 passes as it is.
- **Impact:** One malformed PUT for one light. What `C4:JsonEncode` writes
  for NaN is not documented; the bridge's 4xx then drops the state
  (`commands.lua` final 4xx) [assumed]. No loop, no wider effect.
- **Suggested fix:** In `merge`, treat a value that is not finite as absent
  (`n ~= n or n == math.huge or n == -math.huge`). Clamp `rate` to
  6,000,000 ms, as the scenes do. Add one spec.

### C-4 (Info, release): text reaches Composer rows unescaped or uncapped

- **Attacker and input:**
  - (a) Values that a driver puts in action parameters.
  - (b) Text from a peer at the bridge address that presents a Signify-issued
    certificate. That does not have to be an attacker: another genuine
    bridge after a DHCP change qualifies.
- **(a) Echoed parameter values.** `actions.lua` echoes an unknown picker
  value into Last Action with `%q` (`:1070`, `:1166`, `:1193`, `:1236`,
  `:1328`). Under Lua 5.1, `%q` escapes only quote, backslash, newline,
  `\r` and `\0`, so ESC, BEL and other control characters land in the
  property. The same values go into warning lines with `%s`, for example
  `HUE_SET for unknown light %s` (`driver.lua:1907`) and
  `scenes: %s for unregistered scene %s` (`scenes.lua:1857`). A newline
  there forges extra lines in the Lua output. The full value is printed
  whatever its size. [verified: probe P4. ESC and BEL reached Last Action,
  and a 200 kB `Device` value produced a 200 kB log line. The rows
  themselves stay capped at 6 × 72 characters (`rows.lua`).]
- **(b) Bridge Model and Bridge Firmware.** `identity.lua:186-190` calls
  `show_bridge_info` before comparing the bridge id. `show_bridge_info`
  writes `config.model_label(modelid)` and
  `config.firmware_label(swversion, apiversion)` raw (`driver.lua:988-999`,
  `config.lua:60-72`, `:92-104`). Only `Bridge Name` passes through
  `util.display_name`. That is what 2026-10-25 finding 8 left open.
- **(b) List rows and picker texts.** `util.sanitise` (`util.lua:42`) and
  `rows.commaless` (`rows.lua:113`) strip control characters but put no
  limit on length. Hue names have no length limit in `hue_model.lua`, so a
  hostile peer's very long name goes whole into `UpdatePropertyList` and
  into every picker.
- **Impact:** Display only. A misleading or bloated row, or a forged Lua
  output line. No property can carry the key.
- **Suggested fix:**
  - Pass the model and firmware text through `util.display_name`.
  - Cap `util.sanitise` and `rows.commaless` at `util.NAME_MAX`.
  - Echo caller values through one helper that replaces `%c` and cuts at
    about 80 characters, in `actions.lua` and in the warning lines that
    quote `params`.

### C-5 (Info, release): Debug Mode has no expiry

- **Position:** A dealer or the owner turns Debug Mode on for a support
  session and forgets it.
- **Cause:** `Debug Mode` is a plain LIST property (`driver.xml:27-37`,
  `driver.lua:1137-1139`). While it is On:
  - `device_send` passes `logCommand = true` (`driver.lua:473`), so
    Director logs every message's parameter table. That covers the names in
    configuration messages, every level change and every motion state. The
    SDK says that `false` keeps a message out of the logs [verified: API
    32_serial_network_device/_19-SendToDevice]. Where Director keeps that
    log is not documented [assumed: on the controller, rotated].
  - `print` goes only to Composer's Lua output while the tab is open
    [verified: API 9_helper/_14-print; `docs/composer-remote.md` rule 13].
- **Impact:** Privacy at rest on the controller: names and presence in
  Director's log for as long as Debug Mode stays On. The key is not in it.
- **Suggested fix:** Switch Debug Mode back to Off after a fixed time (for
  example 4 hours, from a timer that is re-armed at late init), with
  `log.always` saying when it will end. Alternatively, keep
  `logCommand = false` even in Debug Mode, since the driver's own debug
  line already shows the parameters (`driver.lua:467-469`).

## Earlier fixes rechecked

| Earlier finding | Status now | Where |
|---|---|---|
| 2026-10-24 #1 identity before any keyed request | Holds in this area. `bridge_request` refuses until `identity_ok`. The stream's `connection()` re-checks. `choose_stream_address` and Test Connection wait for the identity check. (Reviewer N owns the check itself.) | `driver.lua:302-325`, `:397-404`, `:1056-1065`, `:1321-1328` |
| 2026-10-24 #3 caller-supplied `tls` | Holds: `req.tls = nil`. | `driver.lua:413` |
| 2026-10-24 #7 unbounded retries | Holds. `FINAL_ERRORS` now also holds `TLS check failed`. | `commands.lua` `FINAL_ERRORS` |
| 2026-10-24 #8 stream 401/403 | Holds. New since then: the background re-check (D8) sends the rejected key once an hour, only to the verified bridge (task guards `paired`, `identity_ok`). | `driver.lua:350-367`, `:1283-1309`; `tasks.lua` `key_recheck` |
| 2026-10-24 #9 inter-driver trust | Accepted then; the surface is wider now (C-1). | see C-1 |
| 2026-10-24 #10 control characters | Holds for `AddDevice`, `RenameDevice` and both name directions (`util.display_name`). Not done for Bridge Model, Bridge Firmware and list-row length (C-4). | `owner.lua:1226`, `:1372`; `names.lua:148-162`, `:388-420` |
| 2026-10-24 #11 one reconcile per binding burst | Holds. | `driver.lua:2107-2115` |
| 2026-10-24 #12 release-stage assertion | Holds, and now also covers `probe12.lua`. Strip emulated on `driver.xml`: no DEV-ONLY marker, no dev property, the 10 release actions only. | `tools/build.sh:141-161` |
| 2026-10-24 #13 dev loop remote code execution | Holds. The MAC (with domain labels) is checked before anything is decoded. The command list must echo the fresh nonce. Command ids only grow. `same()` compares the full length, and the expected MAC is never said. A bundle reaches `loadstring` only after verification (`reload` reuses only `S.bundle`). | `devloop.lua:412-465`, `:1162-1190`, `:1106-1149` |
| 2026-10-24 #14 `DEV_RELOAD` from any device | Holds: checked with the device's own key, a device tree only. A replay of an older signed bundle is still accepted (documented). | `devloop.lua:1388-1427` |
| 2026-10-24 #15 dev Host and Path | Holds: `spells_bridge_address` and `path_refusal`, identity check first. | `devtools.lua:66-113` |
| 2026-10-24 #16 reports in clear | Accepted. The redactor holds (C-2 adds the uncapped lines). | `devtools.lua:852-870`, `devloop.lua:172-188` |
| 2026-10-25 #1 Test Connection gate | Holds: `keyed_refusal(true)`, then the identity check, before the keyed GET. | `driver.lua:1311-1359` |
| 2026-10-25 #2 sticky `not_pinned` | Holds: `tls_gate` answers false at once, and `keyed_refusal` checks the verdict. | `identity.lua:121-123`; `driver.lua:189-201` |
| 2026-10-25 #4 confirm a REST 401/403 | Holds: one keyed GET at a time; only its own 401/403 locks. | `driver.lua:377-395`, `:420-422` |
| 2026-10-25 #6 non-table container | Holds. | `driver.lua:945-947` |
| 2026-10-25 #8 display names | Partly (C-4). | `driver.lua:992` |
| 2026-10-25 #9 dev handlers out of `dispatch.commands` | Regressed for four handlers (C-2). `Probe Call`'s refusal of the credential store's names and the redactor hold. | `devtools.lua:332-350`, `:907-912` |
| 2026-10-25 #10 dev Path | Holds. | `devtools.lua:105-113` |

## Looked at, no finding

- **Code execution in a release build:**
  - Nothing in `src/` outside `common/devloop.lua` calls `loadstring`,
    `load`, `loadfile`, `dofile` or `setfenv`, and every `require` takes a
    literal name.
  - `driver.lua:44-61` loads the dev loop with `pcall`, and `devtools` only
    when the loop loaded. `probe12`, `conntest` and `pinning` are required
    only from `devtools`.
  - The release build removes all five files and the DEV-ONLY block, and
    refuses a stage that still has them (`build.sh:141-161`).
  - Without `C4:AllowExecute(true)`, which dp3 adds only with
    `--allowexecute` (`--dev`), Composer's Lua command window stays locked
    by default [verified: FUND 6_Understanding .c4z Drivers/_3-C4ALLOWEXECUTE;
    the API page 22_miscellaneous/_2-AllowExecute is written for encrypted
    drivers, and this driver is not encrypted]. No `AllowExecute` call
    exists in `src/`.
  - The release `Diagnostics` refuses the dev entries' values and starts
    nothing (probe P5).
- **Dev key signature, attacks on the check:**
  - Downgrade: the HMAC backend has to pass the RFC 4231 test, and either
    backend gives the same MAC.
  - Replay of a command list: the nonce is a key-MAC over a per-load mark
    and a counter, so it cannot be predicted.
  - Timing: the full-length compare.
  - Unsigned paths: none reach `loadstring`.
  - Bundle rollback remains (documented in `dev-loop.md`, "What is left").
- **Release dispatch surface** (probe P1):
  - 52 commands and 12 properties.
  - No proxy handler; `ReceivedFromProxy` only logs.
  - `<commands/>` is empty, so Composer programming reaches none of them.
  - `OnBindingValidate` accepts the `HUE_BRIDGE` class only.
  - A forged hello naming a registered rid with another device id only
    records a conflict. The configuration goes to the registered device,
    never to the claimant (`owner.lua:600-607`).
- **The key at rest and in logs:**
  - It is stored with the encrypted flag under one name
    (`credentials.lua:11`, `:25`) [API 26.5_persistence/_4-PersistSetValue],
    and deleted by Forget Pairing.
  - It is never in a property, a list row, Last Action, Attention or a
    device message.
  - `credentials.summary` prints its length only. `http.lua` logs the URL
    and the body, never headers. Motion diagnostics scrub the key, the
    address and the bridge id (`driver.lua:2669-2673`).
  - A dealer's screenshot cannot show it. It does show the address and the
    bridge id, which are not secret (earlier reviews).
- **Format strings and patterns:**
  - Every format string is a literal, and every `log.*` call runs
    `string.format` under `pcall` (`log.lua:28-41`).
  - Searches with data are plain `find`s.
  - No Lua pattern is built from data.
- **Robustness:**
  - The dispatcher runs every command, property and proxy handler under
    `pcall` (`dispatch.lua:22-33`). Commands that arrive before late init
    are bounded: 200, hellos only (`driver.lua:2181-2203`).
  - `OnDriverLateInit` survived all 20 persisted keys it reads, each set to
    seven wrong shapes (140 runs, probe P6; no raise), so a bad store does
    not leave the driver half-initialised.
  - Group holds end within `DIM_MAX_DURATION` (6,000,000 ms). The scene
    recall duration is clamped. No timer is armed with a zero delay.
  - No handler calls itself or another handler in a cycle. The name sync
    has a loop breaker (`names.lua` N7, N9, N10).
- **Hue automations without a click (#280):**
  - The only write is `PUT behavior_instance/<rid> {enabled}` from
    `automations:put` (`automations.lua:1643-1646`). It is called only from
    `disable_one`, `restore_one` and `turn_on_other`, which are reached only
    from `automations:run`, the `Hue Automations` command.
  - Nothing writes from an event, a resync, a timer or Forget Pairing (which
    only adds text, `driver.lua:2455`), or from `OnDriverRemovedFromProject`
    (a log line, `driver.lua:2757-2762`).
  - The driver therefore never changes an automation by itself. The command
    is reachable from any driver (C-1).
- **Two-way names:**
  - Composer to Hue: `util.display_name`, a cut at 32 bytes, and pacing.
  - Hue to Composer: `util.display_name`, at most 100 characters.
  - A rename by any driver (`C4:RenameDevice`) reaches Hue through
    `OnItemNameChanged`, as D6 intends.
- **Composer-only inputs:**
  - `Bridge IP Address`: `config.parse_ipv4` refuses leading zeros and
    octets over 255.
  - `Stream Timeout` and `Stream Watchdog` are clamped.
  - `Bridges Found` acts only on labels it offered itself
    (`bridges_found.lua:248-262`).
  - The list rows snap back to their summary.
- **Background tasks:**
  - `tasks.lua` and `housekeeping.lua` read only. Their writes are the
    resync's, through `bridge_request`.
  - `find_bridge` changes `Bridge IP Address` by itself only to the address
    where discovery found the paired id (reviewer N owns discovery and its
    identity check).
  - The sweep covers private and documentation networks only, at most two
    /24 networks (`sweep.lua:28-38`).

## Tool runs

| Run | Result |
|---|---|
| `python3 -I tools/parallel.py busted` (the repository's specs, unchanged) | 3558 successes, 0 failures, 0 errors, 1 pending |
| Scratch busted probes P1 to P6, outside the repository, on the fake runtime with the documented placeholders (10.0.2.143, 001788fffe123abc) | as cited above |
| `lua5.1` on `commands.body` (C-3), and on `%q` escaping (C-4) | as cited above |
| Release strip of `driver.xml` emulated with `build.sh`'s `awk` into the scratch directory | 0 dev markers or names; 10 actions |
