# 2.0 beta stage 3: routing and sequencing, in every wiring

The coordinator's contract for the third of the four beta stages of #514
(design [`hdmi-sync-design.md`](hdmi-sync-design.md) §5.2 to §5.4 and §5.8,
contracts [`hdmi-sync-contracts.md`](hdmi-sync-contracts.md) C3 and C4,
research [`syncbox-wirings-research.md`](syncbox-wirings-research.md) §7),
issue #557. Every builder works against this text; a change goes
through the coordinator.

Five agents edit disjoint files at the same time (§8). The coordinator
integrates, runs `tools/check.sh` (which now includes the end-to-end run
against the fake box) and `tools/build.sh`, and commits.

## 1. What stage 3 delivers

1. **In line** (design 5.2, 5.3; contracts C4): Director routes through the
   box. `ON`, `SET_INPUT`, `OFF`, `DISCONNECT_OUTPUT` become writes to the
   box through one coalescing queue, confirmed to the proxy only when a read
   shows them done, retried and answered as undelivered otherwise.
2. **Behind a receiver** (design 5.8): Director still routes through the
   box (always HDMI 1); the sync mode comes from the room's current source.
3. **From a receiver's second output** (design 5.8): Director never routes
   through the box; the driver follows a room (**Follow Room**) and drives
   wake, sync, mode and power save from that room's power and source.
4. **The sync mode per source** (O5): Video, Game or Music, from the box's
   input type in line, or from the source in the other wirings; overridable
   per input (in line) or per source (the other two).
5. **No CEC reliance** (O18): nothing here depends on the box's own input
   switching; the offers to turn it off stay stage 4.

Stage 3 writes `execution` only (`mode`, `syncActive`, `hdmiActive`,
`hdmiSource`, `brightness`, the mode's `intensity`). Intensity and
brightness at sync start are the box's current values until stage 4's
periods exist. No `behavior`, `hue`, `device` or `hdmi` write.

## 2. Provisional owner answers (#536)

Built with the recommended answers, each behind one constant or property
default so the owner's answer is a one-line change:
- Follow Room's default: **this device's room**.
- Listen behind a receiver (Director takes the box off the path):
  **start music sync anyway** when the followed room selects a Listen source.
- Game guessed from a source driver's file name: **applied as part of
  Automatic, shown as a guess** (Source Sync Modes reads `PS5: Game
  (guessed from its driver)`).

## 3. The queue and the AV side (agent A)

- `syncbox/queue.lua`: `queue.new{ client, poller, timer, now, log }`;
  `q:set(fields, tag)` merges fields into the pending write (latest wins);
  `q:flush()` sends one `PUT /execution` with the fields in the order the
  box applies them (behaviour SB55: `hdmiActive`, `hdmiSource`, `mode`,
  then the mode's object with `intensity`, `brightness`, `syncActive`);
  after a 2xx it asks the poller for a read in 1 s (`poller:soon`), and
  `on_done(tag, ok, model)` fires when a read shows every field landed, or
  `ok = false` after 4 tries 2 s apart (contracts C4). A code 16 (another
  app streams) is reported as `busy`, not retried; stage 4's take-over acts
  on it.
- `syncbox/av.lua`: contracts C4's table, plus the wiring:
  - `av.new{ queue, state_now, wiring_now, sources, room, notify, last_action,
    properties }`; `a:received(command, params)`; `a:confirm(model)`.
  - In line: input n from the ids of C4; mode from HDMI n Sync Mode (else
    Music for an audio-only route, else the input's type, else Video).
  - Behind a receiver: `SET_INPUT` names HDMI 1 for every source; the mode
    from `sources:mode_for(room.selected, …)`.
  - Second output: proxy commands only logged (none expected, research
    §4.2); `follow.lua` drives instead.
  - `INPUT_OUTPUT_CHANGED`, `ON`, `OFF` notifies only after the read shows
    the change; a change the box made by itself never notifies (C4).
- Specs: `tests/spec/syncbox_queue_spec.lua`, `syncbox_av_spec.lua`.

## 4. The room, the sources and Follow Room (agent B)

Research §7.4's modules, as written there:
- `syncbox/room.lua`: room variables by name through `GetDeviceVariables`,
  falling back to the ids of research §1.2; listeners through
  `C4:RegisterVariableListener`; `on_baseline` once, `on_change` after a
  1 s settle; every value checked (`common/num.lua`, capped text).
- `syncbox/sources.lua`: a device id → `{ id, name, proxy_kind,
  driver_file }` through `C4:GetDevices`; `upstream()`; `mode_for(selection,
  wiring, input)` with research §7.2's precedence; the per-source modes
  stored by device id (PersistData) with the name they had.
- `syncbox/follow.lua`: the second-output wiring's intents for the queue:
  wake and sync on a Watch or Listen selection, the At Room Off and When The
  Source Leaves The Box settings on power off and on a selection that does
  not pass the receiver; nothing on the baseline (a driver restart changes
  nothing on the box); research W10's guard (two boxes on one area never
  take a stream from each other).
- The fake runtime (`tests/helpers/fake_c4.lua`): `RegisterVariableListener`
  (an immediate first callback, an error for a variable that does not
  exist), `UnregisterVariableListener`, `UnregisterAllVariableListeners`,
  `GetDeviceVariables`, `GetDevices` for rooms and sources, and
  `fake.room_variable(room_id, id, value)` that calls
  `OnWatchedVariableChanged`. Agent B owns these additions.
- Specs: `tests/spec/syncbox_room_spec.lua`, `syncbox_sources_spec.lua`,
  `syncbox_follow_spec.lua`; the lifecycle cases W1 to W24 of research §5
  each in a spec.

## 5. The driver (agent C)

- `src/hue_syncbox/driver.lua`: wires queue, av, room, sources, follow;
  `ReceivedFromProxy` on 5001 goes to `av` (still logged verbatim first);
  `OnWatchedVariableChanged` goes to `room`; the wiring row drives which
  path is live, and a wiring change at run time switches it cleanly.
- `src/hue_syncbox/driver.xml` (no `<capabilities>`, connection or proxy
  change; properties and an action only):
  - **HDMI 1 Sync Mode … HDMI 4 Sync Mode** (contracts C1.4), shown in line
    only;
  - **At Room Off**, **When The Source Leaves The Box** (C1.4);
  - **Follow Room** (DYNAMIC_LIST, research §7.2), shown on the second
    output (and behind a receiver, where it names the room whose source
    sets the mode);
  - **Source Sync Modes** (read-only), behind a receiver and second output;
  - action **Set Source Sync Mode** (Source CUSTOM_SELECT, Mode LIST).
  - Properties that do not apply to the wiring are hidden
    (`C4:SetPropertyAttribs(name, 1)`).
- `tests/spec/syncbox_driver_spec.lua`: each wiring end to end against the
  Lua fake box, the proxy commands of C4 in every order P1–P4 may show,
  retries and undelivered answers, code 16, a restart mid-route, a wiring
  change while routed.

## 6. End to end and docs (agent D)

- `tests/e2e/syncbox_e2e.lua` gains a routing suite: Director's commands
  replayed through the real transport against the Python fake for each
  wiring, room variables driven through the fake runtime, the box's state
  read back from the fake's control API; `tools/e2e_syncbox.sh --only
  routing`.
- `tests/fixtures/syncbox_scenarios.json` gains the scenarios the queue
  relies on (combined PUTs in order, wake plus input plus sync in one PUT),
  passed by both fakes.
- `src/hue_syncbox/www/documentation.html`: routing per wiring, the new
  properties and action, what a dealer connects in each wiring;
  `CHANGELOG.md` Unreleased.

## 7. Probes on the house (the coordinator, after the build)

Research §6: P8 (room variables, a dev-loop bundle, no Composer change)
first; P9 to P11 and P12 in a scratch room of generic drivers with the
paired box device pointed at the fake box, deleted afterwards; P13 waits
for the owner's next reboot. Results amend this contract before stage 3
merges. Probe code lives under `tools/probes/` and dev-loop bundles only,
never in a release build.

## 8. Writers (one per file)

| Agent | Files |
|---|---|
| **A** | new `src/hue_syncbox/syncbox/queue.lua`, `av.lua`; new `tests/spec/syncbox_queue_spec.lua`, `syncbox_av_spec.lua` |
| **B** | new `src/hue_syncbox/syncbox/room.lua`, `sources.lua`, `follow.lua`; `tests/helpers/fake_c4.lua` (the room additions only); new `tests/spec/syncbox_room_spec.lua`, `syncbox_sources_spec.lua`, `syncbox_follow_spec.lua` |
| **C** | `src/hue_syncbox/driver.lua`, `driver.xml`, `tests/spec/syncbox_driver_spec.lua`, `tests/fixtures/ledger.lua` |
| **D** | `tests/e2e/syncbox_e2e.lua`, `tools/e2e_syncbox.sh`, `tests/helpers/real_url.lua`, `tests/fixtures/syncbox_scenarios.json`, `docs/syncbox-behaviour.md` (rules the new scenarios cite), `tests/helpers/fake_syncbox.lua` and `tools/fakebox/model.py` (only where a new scenario needs it), `src/hue_syncbox/www/documentation.html`, `CHANGELOG.md` |
| **P** | new `tools/probes/` (probe bundles P8 to P12 and their run notes), new `docs/syncbox-probes.md` |
| Coordinator | this file, `tools/build.sh`, `tools/check.sh`, `CLAUDE.md`, `docs/README.md`, `docs/status.md`, `docs/hdmi-sync-contracts.md` amendments, integration |

## 9. Done

- `tools/check.sh` passes, the e2e routing suite included; five packages
  build; no `<capabilities>` change (Lua and properties only: no reboot).
- Probes P8 to P12 run on the house through the Windows session and the dev
  loop, against the fake box; their findings are in the contract.
- The owner's checks are only those that need a real box (the conformance
  list of #547).
