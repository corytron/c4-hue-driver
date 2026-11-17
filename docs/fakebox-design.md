# A fake Hue Sync Box: testing the box driver without a box

The coordinator's contract for issue #547 (part of #514). The owner has no
box to test with for a few days (2026-11-17) and wants the box driver
tested end to end before his final checks, with very high confidence. Every
builder works against this text; a change goes through the coordinator.

Branch `feat/fakebox-547`. Six agents edit disjoint files at the same time
(§8). The coordinator integrates, runs `tools/check.sh` and
`tools/build.sh`, and commits.

## 1. What it gives

Two fakes of one box, held to one behaviour:

1. **The Lua fake** (`fake.syncbox` in the fake runtime) for the busted
   specs: fast, deterministic, every corner reachable.
2. **The Python fake** (`tools/fakebox/`) on the VM: a real HTTPS server
   with its own CA, a real `_huesync._tcp` mDNS answer, a button pressed
   from the command line, faults on demand. It serves two harnesses:
   - **the end-to-end harness** (§6): the real box driver's Lua, run in
     `lua5.1` with the fake runtime, whose `C4:url` goes over real HTTPS
     through `curl` (the library Director uses) to the Python fake;
   - **the house** (§7): a development build of the box driver, installed
     through the Windows session, pairs with the Python fake from the real
     controller.

**One behaviour.** `docs/syncbox-behaviour.md` (§3) states what a box does,
each rule with its public source. `tests/fixtures/syncbox_scenarios.json`
(§4) turns the rules into steps; both fakes must pass every scenario. A
rule with no public source is marked [assumed] and so is its scenario; the
owner's final checks on the real box settle those first.

## 2. The model (both fakes)

The box is a state machine over the `GET /api/v1` document of
`docs/syncbox-api-research.md` §2 (fields `device`, `execution`, `hdmi`,
`behavior`, `hue`, `ir`, `registrations`, `presets`), starting from a
fixture of `tests/fixtures/hue_syncbox.lua` (HSB1, HSB2, HSB3,
HSB3_standalone and the two wirings). Both fakes read the same fixtures:
`tests/fixtures/hue_syncbox.json` is generated from the Lua file by
`tools/fakebox/export_fixtures.lua` (agent F4), so Python never re-types
them; a check (§9) fails when the two drift.

It covers:
- **Requests:** everything in the research: `GET` of the whole state and
  each resource and sub-path; `PUT /execution` with every field and
  command field (`syncActive`, `hdmiActive`, `mode`, `hdmiSource`,
  `hueTarget`, `brightness`, `incrementBrightness`, `toggleSyncActive`,
  `toggleHdmiActive`, `cycleSyncMode`, `cycleHdmiSource`, `cycleIntensity`,
  `toggleSyncMode`, the per-mode `intensity`, `backgroundLighting`,
  `palette`, `preset`), `PUT /behavior` (box-wide and per input),
  `PUT /hdmi/inputN` (name, type) and `PUT /device` (name),
  `POST`/`DELETE /registrations`, the error codes of §2.14 for each
  invalid request.
- **Events the house would cause** (not requests): the button held; a
  source sending CEC Active Source or hot-plug on input n; the TV's CEC
  standby; USB power lost; a source's signal appearing or going
  (`hdmi.inputN.status`); idle time passing (`inactivePowersave`); the
  bridge going busy (another app streams), coming back, losing the link;
  the box renamed in the Hue Sync app; a registration deleted in the app; a
  firmware update (version and API level change, a restart); a reboot
  (nothing answers for a while, then the same state); an address change.
- **Faults:** silence (no answer), latency (ms), a 5xx, a dropped
  connection, a body cut short, an oversized body, a redirect, a wrong
  certificate (another CA), another box id behind the same address.
- **Time** is the fake's own clock: the Lua fake runs on the fake
  runtime's clock; the Python fake on wall time, scaled by `--time-scale`.

## 3. `docs/syncbox-behaviour.md` (agent F4)

The normative behaviour: one numbered rule per line (`SB1`, `SB2`, …), each
with its source (aiohuesyncbox, Home Assistant's `huesyncbox`
integration, openHAB's binding, community reports, or [assumed]), read from
the public sources online and never copied: rules are written in our own
words, field names only. Groups: transitions between powersave,
passthrough and the sync modes; what each execution field and command
does, alone and together, and in what order a combined PUT applies; value
ranges and what is refused with which code; `behavior` flags and what the
box then does by itself on each event; registrations (many at once, names,
deletion, a token that stops working); `hue` link states and code 16 while
another app streams; how `hdmi.inputN.status` moves; what changes when, and
what a box does after a reboot or a firmware update. It ends with the list
of rules marked [assumed], each with the house check that settles it.

## 4. `tests/fixtures/syncbox_scenarios.json` (agent F4)

```json
{ "version": 1,
  "scenarios": [
    { "id": "SC-PAIR-1", "rules": ["SB40"], "model": "HSB2",
      "steps": [
        { "do": "POST", "path": "/registrations", "body": {"appName": "c4-hue", "instanceName": "Bedroom"},
          "expect": { "status": 400, "code": 16 } },
        { "event": "button" },
        { "do": "POST", "path": "/registrations", "body": {"appName": "c4-hue", "instanceName": "Bedroom"},
          "expect": { "status": 200, "has": ["registrationId", "accessToken"] }, "save_token": "t1" },
        { "do": "GET", "path": "", "token": "t1",
          "expect": { "status": 200, "state": { "execution.mode": "video" } } }
      ] } ] }
```

- `do`: `GET`, `PUT`, `POST`, `DELETE`; `path` after `/api/v1`; `token`:
  a saved name, `"wrong"` or absent.
- `event`: `button`, `cec_active_source` (`input`), `hotplug` (`input`),
  `signal` (`input`, `status`), `tv_standby`, `usb_power_lost`, `idle`
  (`minutes`), `bridge` (`state`), `rename` (`name`), `app_deletes`
  (`registration`), `firmware` (`version`, `api_level`), `reboot`,
  `advance` (`ms`).
- `expect`: `status`, `code` (the box's error code), `has` (keys present),
  `state` (dotted paths into the whole state read after the step, exact
  values), `absent` (paths that must not exist).
- At least 120 scenarios across every group of §3, and every rule of §3 in
  at least one.

**Runners**, both written by F4: `tests/spec/syncbox_scenarios_spec.lua`
(against `fake.syncbox`) and `tools/tests/test_fakebox_scenarios.py`
(against the Python model, and once through the HTTPS server). A scenario
the other fake fails is a bug in that fake, never a skipped test.

## 5. The Python fake (`tools/fakebox/`, agents F1 and F2)

Standard library only (plus the `openssl` command for the CA). Python
3.14 as on the VM; `python3 -I` safe; no third-party code.

- `tools/fakebox/model.py` (F1): the state machine of §2, pure (no I/O):
  `Box(fixture, clock)`, `box.request(method, path, headers, body) ->
  (status, body)`, `box.event(name, **args)`, `box.state()`.
- `tools/fakebox/server.py` (F1): HTTPS on `--port` (default 8443; 443
  needs root and is not used), TLS from the CA of F2, threads, at most one
  request served at a time per box as a real box (others wait), the faults
  of §2; several boxes at once (`--box HSB2:0A1B2C3D4E5F`, repeatable, each
  on its own port).
- `tools/fakebox/control.py` + `tools/fakebox.py` (F1): a control API on
  `127.0.0.1` only and a CLI: `tools/fakebox.py serve|button|event|fault|
  state|set|log|stop`, e.g. `tools/fakebox.py button --box 0A1B2C3D4E5F`.
  It logs every request (method, path, status, ms; the token as
  `<redacted>`).
- `tools/fakebox/ca.py` (F2): a per-VM CA (EC P-256, `CN=c4-hue fake
  sync box CA`) and one leaf per box (`CN=<box id>`, `OU=<model>`,
  SAN none), under `~/.config/c4-hue-driver/fakebox/` (0700), never in the
  repository, never in a release build.
- `tools/fakebox/mdns.py` (F2): answers `_huesync._tcp.local` PTR queries
  on 224.0.0.251:5353 (multicast and legacy unicast, the form the drivers'
  `common/mdns.lua` sends) with SRV (the fake's port), TXT (`uniqueid`,
  `devicetype`, `name`, `path=/api`, as the research lists) and A
  records; coexists with avahi (`SO_REUSEADDR`/`SO_REUSEPORT`).
- Tests: `tools/tests/test_fakebox_model.py`, `test_fakebox_server.py`
  (F1), `test_fakebox_ca.py`, `test_fakebox_mdns.py` (F2). Parallel-safe:
  ports picked free, no fixed paths outside a temp dir.

## 6. The end-to-end harness (agent F5)

- `tests/helpers/real_url.lua`: a `C4:url` transport for the fake runtime
  that runs `curl` through `io.popen` with the options the driver set
  (`--cacert` from `ssl_cabundle`, `-k` never, no hostname check like
  `ssl_verify_host = false` via `--resolve`/`--connect-to` as needed,
  timeouts, headers, body, `-w` for the status), and delivers
  `OnHeaders`/`OnBody`/`OnDone` as Director does (the shapes the fake
  runtime already models). It plugs into the hook F3 adds
  (`fake.set_url_transport(fn)`).
- `tests/e2e/syncbox_e2e.lua` and `tools/e2e_syncbox.sh`: start the Python
  fake (one HSB2, then the other models), load `src/hue_syncbox/driver.lua`
  in the fake runtime with the real transport, and drive the owner's flows:
  add the device, discovery finds the fake (through `tools/fakebox/mdns.py`
  where the VM allows multicast to itself, else the typed address), Pair
  Sync Box with the button pressed through the control API, the rows
  filled, polling, the fake changed by events and the rows following,
  silence → offline after the 5-minute rule (time scaled), back online, a
  401 after `app_deletes`, a wrong box at the address, Forget Pairing.
  Prints one line per check and exits non-zero on any failure.
- Not part of `busted tests` or CI (it needs the network and `curl`);
  `tools/check.sh --only e2e` runs it when the coordinator asks (the
  coordinator adds that check).

## 7. Development builds against the fake (agent F6)

Only `tools/build.sh --dev` builds carry any of this; a release build fails
if it does (as `devloop.lua` today).
- `src/hue_syncbox/syncbox/devhooks.lua` (new, dev only): (1) Box Address
  and Pair Sync Box's Address accept `host:port`; (2) discovery accepts an
  SRV port other than 443; (3) nothing else. The driver, `client.lua` and
  `discovery.lua` call it through `pcall(require, "syncbox.devhooks")` and
  behave exactly as today without it. F6 adds those call points with the
  smallest change, and specs that prove the release behaviour is
  unchanged without the module.
- `tools/build.sh --dev` (the coordinator): appends the VM's fake CA
  (`~/.config/c4-hue-driver/fakebox/ca.pem`, when it exists) to the dev
  package's `certs/hsb_ca.pem`, deletes `syncbox/devhooks.lua` from release
  stages, and refuses a release stage that carries either.
- The dev loop's `syncbox` tree: `tools/devserver.py` serves it
  (`src/hue_syncbox/**`), and the bridge forwards it to the devices bound
  on its connection 2 as it does the light and scene trees
  (`src/common/devloop.lua`, `docs/dev-loop.md`), so Lua changes reach the
  house's box device without a Composer install (F6).

The house run, after the agents: the coordinator builds `--dev`, serves it
with `tools/serve_install.py`, the Windows session installs it and binds the
box device, and the device pairs with the fake on the VM (its address
`192.0.2.7:8443` in every public text), the button pressed from the VM.
Then each flow of §6 again on the real controller, and the release build
is installed again afterwards (`deploy.py`).

## 8. Writers (one per file)

| Agent | Files |
|---|---|
| **F1** | new `tools/fakebox/__init__.py`, `model.py`, `server.py`, `control.py`, new `tools/fakebox.py`; new `tools/tests/test_fakebox_model.py`, `test_fakebox_server.py` |
| **F2** | new `tools/fakebox/ca.py`, `mdns.py`; new `tools/tests/test_fakebox_ca.py`, `test_fakebox_mdns.py` |
| **F3** | `tests/helpers/fake_c4.lua` (the box moves into new `tests/helpers/fake_syncbox.lua`, required by it; `fake.syncbox` keeps its API and gains `h:event(name, args)`, faults, and `fake.set_url_transport(fn)`); `tests/spec/fake_syncbox_spec.lua` |
| **F4** | new `docs/syncbox-behaviour.md`, `tests/fixtures/syncbox_scenarios.json`, `tools/fakebox/export_fixtures.lua`, `tests/fixtures/hue_syncbox.json` (generated), new `tests/spec/syncbox_scenarios_spec.lua`, `tools/tests/test_fakebox_scenarios.py` |
| **F5** | new `tests/helpers/real_url.lua`, `tests/e2e/syncbox_e2e.lua`, `tools/e2e_syncbox.sh` |
| **F6** | new `src/hue_syncbox/syncbox/devhooks.lua`; `src/hue_syncbox/driver.lua`, `syncbox/client.lua`, `syncbox/discovery.lua` (call points only); `tools/devserver.py`, `tools/devctl.py`, `src/common/devloop.lua`; `docs/dev-loop.md`; their specs and `tools/tests/test_devserver.py` |
| Coordinator | this file, `tools/build.sh`, `tools/check.sh`, `.github/workflows/*`, `CLAUDE.md`, `docs/README.md`, `docs/status.md`, `tests/fixtures/hue_syncbox.lua` changes asked for by others, integration |

F1 and F3 build from `docs/syncbox-api-research.md` §2 at once and align
with F4's rules and scenarios as they land; F4 tells the coordinator which
scenario each fake fails, and the coordinator relays it.

## 9. Done

- `tools/check.sh` passes, now also running the scenario runners (in
  `lua-test` and `python-test`) and a fixtures check (`hue_syncbox.json`
  equals the export of the Lua file).
- `tools/e2e_syncbox.sh` passes on the VM against every model.
- The house run of §7 passes, and the release build is installed again.
- Every [assumed] rule is listed for the owner's final checks on the real
  box, in `docs/syncbox-behaviour.md` and on #547.
