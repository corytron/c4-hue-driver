# Dev loop: pushing code to the live drivers without Composer

The dev build of the bridge driver fetches its own Lua from a server on the
development VM, reloads itself when the code changes, runs queued actions,
and ships its log and properties back. It also fetches the light and scene
drivers' Lua and hands each tree to the bound devices running that driver,
which reload themselves the same way. After one Composer install of a dev
build, only `driver.xml` changes need Composer again (a capability change
also needs the owner's controller reboot, `docs/composer-remote.md` rule 10).

Dev builds only: `tools/build.sh --dev` includes `src/common/devloop.lua` in
all three drivers; release builds don't contain it at all. The loop is inert
until the bridge's `Dev Server` property holds a `host:port`. Light and scene
devices have no such property: they only react to what the bridge forwards.

**Current state (2026-10-24): not in use.** The house has run production
builds since 2026-10-22 (build 116 first, build 160 now). Release builds
carry no `common/devloop.lua`, so nothing on the controller polls this VM
and no property can turn the loop on. To return to the loop: start
`tools/devserver.py`, build with `tools/build.sh --dev` and install the
three dev `.c4z` through the same route as a release (`docs/status.md`, "How
builds reach the house"; `CLAUDE.md`, Deploy). The `--dev` flag changes only
the Lua that is packed, not `driver.xml`. Build from a commit after the
installed one (the version is the commit count, so Composer sees an update);
unless that commit changes `<capabilities>`, no reboot should be needed (the
dev → release switch of 2026-10-22 needed none). The bridge's `Dev Server`
property kept its last value through the release builds (they ignore it), so
the loop starts at the dev build's late init; check that it holds this VM's
`host:port` (set it with the row's Set button if not). Leaving again is the
release install described under "Leaving the loop" below.

## Pieces

- `tools/devserver.py`: the server on the VM. Plain HTTP (default port 8080)
  for the dev loop, plus a TLS listener (default 8443, self-signed) that
  keeps the connection-experiment endpoints `/stream` and `/ping` alive.
  Serves three trees, each exactly the layout its `.c4z` has:
  - `tree=bridge` (the default): `src/hue_bridge` with `src/common` mounted
    as `common/`.
  - `tree=light`: `src/hue_light` with `src/common` mounted as `common/`.
  - `tree=scene`: `src/hue_scene` with `src/common` mounted as `common/`
    (added with the scenes feature, `docs/scenes-design.md` §6).
- `tools/devctl.py`: CLI for the developer: queue actions, set properties,
  force a reload, pin or unpin the trees, show status (every tree), tail
  the log.
- `src/common/devloop.lua`: the driver side, in all three drivers. The
  bridge runs the polling loop; a light or scene device only uses
  `devloop.apply_forwarded` from its `DEV_RELOAD` handler, which applies
  only the bundle of its own tree.

Files written by the server live under `build/dev/` (gitignored):
`driver.log` (shipped log lines), `reports.jsonl` (one JSON object per
report), `commands.json` (the queue).

## Wire protocol (all JSON unless noted; only the bridge ever initiates)

`GET /manifest[?tree=bridge|light|scene]` →
`{"version": "<sha1 over sorted path+contents>", "tree": "bridge", "files": ["driver.lua", "bridge/http.lua", ...], "server_time": <unix seconds>}`
`tree` defaults to `bridge`; an unknown tree is a 400. Each tree has its own
version. The `tree` field tells the driver which tree it got: a server from
before trees existed answers the bridge tree to any `?tree=`, and the loop
must never forward that to the lights.

`GET /bundle[?tree=...]` →
`{"version": "...", "tree": "...", "files": {"driver.lua": "<source>", "bridge/http.lua": "<source>", ...}}`

`GET /file?path=bridge/http.lua[&tree=...]` → `text/plain` source, 404 if
unknown. Paths are confined to the served tree.

`GET /commands?after=<id>` →
`{"commands": [ {"id": 7, "type": "execute", "command": "Connection Test", "params": {"Target": "Bridge"}},
                {"id": 8, "type": "set_property", "name": "Stream Timeout (s)", "value": "60"},
                {"id": 9, "type": "reload"} ]}`
Ids increase monotonically across server restarts (persisted in
`commands.json`). A command stays in the queue until the driver reports
`command_done` for it, then moves to a bounded done list; so a driver that
starts fresh and asks `after=0` receives only unacknowledged commands.
`execute` goes through the driver's `ExecuteCommand(command, params)`;
`set_property` does `C4:UpdateProperty(name, value)` followed by
`OnPropertyChanged(name)`; `reload` re-runs the reload sequence on the
current bridge version (it does not re-forward the light tree; touch a file
under `src/hue_light` or `src/common` for that).

`POST /log` body `{"version": "<running version>", "lines": [{"t": <ms since epoch>, "line": "..."}]}` → 204.
The server appends `HH:MM:SS.mmm <line>` to `driver.log` and echoes to stdout.

`POST /report` body
`{"version": "...", "light_version": "<or absent>", "scene_version": "<or absent>", "event": "<see below>", "command_id": <id or absent>, "properties": {...}, "error": "<text or absent>", "sandbox": {...or absent}, "elapsed_ms": <or absent>}` → 204.
`light_version` / `scene_version` are the tree versions the bridge last
fetched and forwarded (recorded even when no device of that kind was bound
to receive them); absent until the first forward. Events: `startup` (loop started; includes `sandbox`
facts: `_VERSION`, `jit.version` if any, and the `type()` of `loadstring`,
`load`, `setfenv`, `package.loaders`, `C4`, plus the driver version from
`C4:GetDriverConfigInfo("version")`), `reload` (new code running),
`reload_failed` (error text; old code may be half torn down), `command_done`
(with `command_id`), `heartbeat` (at most once every 30 s, properties only;
also right after a new light or scene version is forwarded, so `/status`
catches up at once).

`GET /status` → `{"running_version": ..., "local_version": ..., "running_light_version": ..., "local_light_version": ..., "running_scene_version": ..., "local_scene_version": ..., "pinned": {...}, "last_seen": <unix>, "server_time": <unix>, "last_event": ..., "last_error": ..., "properties": {...}, "pending_commands": [...], "done_commands": [ids], "last_done_id": N}`
(plus `live_version`, `live_light_version` and `live_scene_version`, what
the working trees are now; they differ from `local_*` only while pinned).
`running_light_version` / `running_scene_version` are what the bridge
reported forwarding, not what any device reports (light and scene devices
never talk to the server). `last_seen` is bumped by any driver-initiated
request. Times are unix seconds as floats.

`POST /admin/enqueue` body `{"type": "execute"|"set_property"|"reload", ...fields as above}` → `{"id": N}`.
Used by `devctl`; the driver never calls it.

## Driver-side behaviour (`common/devloop.lua`)

### Bridge

- `devloop.start(host_port)` is called from `OnDriverLateInit` of a dev build
  when the `Dev Server` property is set. Calling it again with the same host
  is a no-op; with a different host it restarts; `devloop.stop()` stops.
- State lives in a global (`_G.__DEVLOOP`) so a reload cannot lose the loop,
  and `package.loaded["common.devloop"]` is never cleared by a reload.
- A repeating `C4:SetTimer` (3000 ms) drives everything. Each tick: at most
  one chain in flight; `GET /manifest` and, if the version differs from the
  running one, `GET /bundle` and reload; then `GET /manifest?tree=light`
  and, if that version differs from the one the bridge holds,
  `GET /bundle?tree=light` once; then forward the held bundle to every
  bound light that has not received that version (below); then the same for
  `tree=scene` and the bound scene devices; then
  `GET /commands?after=<last id>` and run each command in order, reporting
  `command_done` after each with a properties snapshot; then flush the log
  buffer with `POST /log`; then a heartbeat if one is due. Never start a
  `C4:url` transfer from inside another transfer's `OnHeaders` or
  `OnBodyChunk` callback (Director fails it with curl error 2); timers and
  `OnDone` callbacks are safe.
- Forwarding a tree (light or scene): the bridge keeps the bundle it last
  fetched per tree (`light_version` / `scene_version` plus its files) and,
  per bound device id, the version that device last received
  (`__DEVLOOP.light_forwarded`, `__DEVLOOP.scene_forwarded`). Light and
  scene devices share binding 1, so every tick it reads
  `C4:GetBoundConsumerDevices(C4:GetDeviceID(), 1)`, learns each new id's
  `driverFileName` once with `C4:GetDevices` (`hue_light.c4z` → light tree,
  `hue_scene.c4z` → scene tree; an unreadable one counts as a light), drops
  ids no longer bound, and sends the tree's bundle to each bound device of
  that kind whose recorded version is not the held one, as
  `C4:SendToDevice(id, "DEV_RELOAD", { tree = ..., version = ..., files = <JSON text> }, false, false)`.
  The `files` object is encoded once per forward with
  `C4:JsonEncode(files, false, true)` (an object of strings, so Director's
  array quirk cannot bite). The two trailing `false`s are `allowEmptyValues`
  and `logCommand`: with the default `logCommand = true` Director would
  write the ~40 KB bundle to its log on every forward. So a new version
  reaches every bound device of its kind once (`light version X forwarded
  to N light device(s)`), and a device bound afterwards, for example one
  Add Light just created, gets the current version on the next tick from
  the held bundle, without a refetch and without the version changing
  (`light version X forwarded to N newly bound light device(s)`). A version
  first seen with nothing of its kind bound is said once (`scene version X:
  no bound scene devices`) and still held for the devices to come. The
  version is recorded per device before the send, so a device whose
  `SendToDevice` fails is not retried until the server has a different
  version; a device that is unbound and bound again is treated as new. A
  new version makes a heartbeat due at once so `/status` shows the new
  running version of that tree; a catch-up does not. A manifest without the
  requested `"tree"` (a server without trees) is said once and ignored.
- Reload sequence: `pcall(OnDriverDestroyed)`; clear every
  `package.loaded` entry matching `^bridge%.`, `^light%.`, `^scene%.` or
  `^common%.` except `common.devloop`; install (or replace) a loader at
  `package.loaders[1]` that serves modules from the bundle (`a.b` →
  `a/b.lua`); run `loadstring(bundle["driver.lua"], "=driver.lua")`; then
  `OnDriverInit("DIT_UPDATING")` and `OnDriverLateInit("DIT_UPDATING")`.
  Every step is `pcall`ed; a failure posts `reload_failed` and the loop keeps
  polling, so the next pushed version retries.
- Log capture: wrap `_G.print` once (keeping the original for Composer) so
  everything the driver prints is buffered and shipped; keep at most 500
  lines, dropping the oldest. The loop's own messages use the original print
  and are also buffered.
- Properties snapshot: a copy of the `Properties` table. If `C4` is a Lua
  table, also wrap `C4.UpdateProperty` once to shadow values the driver sets
  itself; report `type(C4)` in the sandbox facts either way.
- Nothing in the loop ever prints or reports the Hue application key.

### Light and scene devices

- `devloop.apply_forwarded(params)` does the reload; each device's
  `DEV_RELOAD` handler calls it after checking `params.tree` (a bundle for
  the other tree is ignored, and `apply_forwarded` itself skips a tree that
  is not its driver's own). `params.files` is decoded with `C4:JsonDecode`,
  then the same reload sequence as above runs, with the same `pcall`
  discipline. It needs no `devloop.start()`: the shared state is created
  when the module loads.
- The outcome goes through the device's original `print`, which lands in
  its Lua output in Composer, not on the server:
  `devloop: light reload complete: version <v>` or
  `devloop: scene reload failed: <error>`. The device's own follow-up line
  ("light reloaded to version <v>", "scene reload failed; …") also reaches
  the bridge's shipped log as `HUE_LOG`, as every non-debug line of a dev
  build's device does. A failed reload leaves the handler usable; the next
  forward retries. `devloop.version()` on a device is the forwarded version
  it last tried.
- A device's reload re-runs its `driver.lua`, which re-registers the handler
  on the fresh `common.dispatch`; `common.devloop` itself stays the copy the
  `.c4z` shipped.

## Developer workflow

```
tools/devserver.py                 # once, in the background on the VM
tools/build.sh --dev               # dev .c4z files for the one-time Composer install
tools/devctl.py status             # are the drivers talking to us, which versions
# edit src/hue_bridge or src/common, then wait ~3 s: the bridge reloads itself
# edit src/hue_light or src/common, then wait ~3 s: the bridge forwards, every bound light reloads
# edit src/hue_scene or src/common, then wait ~3 s: the same for every bound scene device
# Add Light / Add Scene at any time: each new device gets its tree's current version on the next tick
tools/devctl.py run "Connection Test" Target=Bridge   # prints the command id
tools/devctl.py wait 7 --timeout 120                  # until command_done, then properties
tools/devctl.py set "Stream Timeout (s)" 60
tools/devctl.py log -f
tools/devctl.py pin                  # serve src/ as it is now; later edits wait for the next pin or unpin
tools/devctl.py unpin                # back to live reloads
```

Pin while several agents edit `src/` at once: the controller then only
reloads to states the coordinator has checked (`luacheck src tests` and
`busted tests` green), each pushed by a fresh `pin`. `status` shows a
`pinned` line with the pinned versions and what the live trees have become.

`devctl.py status` shows every tree, running against local:

```
running_version        1f3a9c0b2d4e  (matches local)
local_version          1f3a9c0b2d4e
running_light_version  8b7e6d5c4a39  (DIFFERS from local; a forward is due)
local_light_version    0c1d2e3f4a5b
running_scene_version  5e6f7a8b9c0d  (matches local)
local_scene_version    5e6f7a8b9c0d
last_seen              2s ago
...
```

`running_light_version` and `running_scene_version` read `bridge has not
forwarded yet` until the bridge's first forward after its loop starts.
Each pair is omitted when the server predates that tree.

`run`, `set` and `reload` print the bare id so `devctl.py wait $(devctl.py run …)`
works. The server takes `--quiet` to drop per-request connection lines on
the plain listener, and `--state-dir`/`--cert-dir`/`--root` to relocate its
files.

### Leaving the loop (production)

A release build (`tools/build.sh` without `--dev`) ships no
`common/devloop.lua`; every driver requires it with `pcall`, so the same
`driver.lua` starts without it and the bridge simply never contacts this
VM again. Before installing one: `devctl.py set "Debug Mode" Off` (the
property survives the update), then follow the Deploy line in `CLAUDE.md`
(HTTP server on 8090, Windows session downloads and runs "Add or Update
Driver or Agent…" for all three files). `devctl.py status` then shows
`last_seen` growing; stop `devserver.py` and the HTTP server. The dev
build's `Dev Server` and `Diagnostic Server` properties stay declared in
`driver.xml` and keep their last values; the release code ignores them.
Done for the first time on 2026-10-22 (version 116 over dev build 84); the
house has stayed on release builds since (160 on 2026-10-24). Returning to
the loop: "Current state" at the top.

## Security

Dev builds only; LAN only; plain HTTP. Anyone on the LAN who can impersonate
the VM's address can push code into a dev driver, and through the bridge into
every bound light and scene device. Never install a dev build as the
production driver.

## Gotchas learned on hardware

- **Keep files complete when saving.** The running controller reloads on
  every change to any tree, so a file saved half-written (or a sequence of
  edits that leaves the tree inconsistent between saves) is a real reload:
  the driver is torn down, the broken code fails to come up, and the bridge
  (or every light) is dead until the next consistent save. Write whole files
  at once; when a change spans several files, make it in one save per file
  without pausing between them, or stop the loop first
  (`devctl.py set "Dev Server" ""`) and start it again when done.
- `common/devloop.lua` is the one module a reload never replaces, so an edit
  to it reaches the controller only through a Director restart or a fresh
  `.c4z` install; the bundle carries the new file, but the running copy is
  the one that was `require`d first. This bit on hardware: an earlier loop
  recorded the light version while nothing was bound (`light version X: no
  bound lights`), and the 47 lights Import Lights then created never got a
  `DEV_RELOAD`, because the version had not changed. The per-light tracking
  described above fixes that, but a bridge still running the older
  `devloop.lua` keeps the old behaviour until the next Director restart or
  dev `.c4z` install; until then, touch a file under `src/hue_light` or
  `src/common` after importing lights so the version changes and the
  forward happens.
- Director's `C4:JsonEncode` writes Lua arrays as objects with string keys
  even with `encodeArrays = true`; the server accepts both shapes.
- Every reload restarts the event stream, and the abandoned transfer lives
  on until the next bridge event or its timeout (`Cancel()` does nothing).
  After several reloads several zombies are open; they drain one per
  bridge event. (Since the stream address rotation of 2026-10-21 a new
  stream no longer waits behind them, `docs/design.md`, "Stream address
  rotation".) `devctl.py run "Hue Request" Method=PUT
  Path=/clip/v2/resource/light/<id> Body='{"metadata":{"name":"X"}}'
  Host=<a padded spelling of the bridge address that nothing else uses>`
  generates one event per call without touching the light itself; rename
  back afterwards. (`Hue Request`, the `Probe` actions, `Proxy Command` and
  `Lights Report` exist only in dev builds.)
- Edits to `tools/devserver.py` need a server restart. Kill it with a pattern
  that does not appear in your own command line (`pkill -f "devserver[.]p[y]"`)
  and start it in a separate command, or the shell kills itself.
- `build/dev/reports.jsonl` gets a heartbeat every 30 s; prune it when it
  grows.
