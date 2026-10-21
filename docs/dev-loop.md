# Dev loop: pushing code to the live drivers without Composer

The dev build of the bridge driver fetches its own Lua from a server on the
development VM, reloads itself when the code changes, runs queued actions,
and ships its log and properties back. It also fetches the light driver's
Lua and hands it to every bound light, which reloads itself the same way.
After one Composer install of a dev build, only `driver.xml` changes and
Director restarts need Composer.

Dev builds only: `tools/build.sh --dev` includes `src/common/devloop.lua` in
both drivers; release builds don't contain it at all. The loop is inert until
the bridge's `Dev Server` property holds a `host:port`. Lights have no such
property: they only react to what the bridge forwards.

## Pieces

- `tools/devserver.py`: the server on the VM. Plain HTTP (default port 8080)
  for the dev loop, plus a TLS listener (default 8443, self-signed) that
  keeps the connection-experiment endpoints `/stream` and `/ping` alive.
  Serves two trees, each exactly the layout its `.c4z` has:
  - `tree=bridge` (the default): `src/hue_bridge` with `src/common` mounted
    as `common/`.
  - `tree=light`: `src/hue_light` with `src/common` mounted as `common/`.
- `tools/devctl.py`: CLI for the developer: queue actions, set properties,
  force a reload, show status (both trees), tail the log.
- `src/common/devloop.lua`: the driver side, in both drivers. The bridge
  runs the polling loop; a light only exposes `devloop.apply_forwarded`,
  which the light's `driver.lua` registers as
  `dispatch.commands["DEV_RELOAD"]`.

Files written by the server live under `build/dev/` (gitignored):
`driver.log` (shipped log lines), `reports.jsonl` (one JSON object per
report), `commands.json` (the queue).

## Wire protocol (all JSON unless noted; only the bridge ever initiates)

`GET /manifest[?tree=bridge|light]` →
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
`{"version": "...", "light_version": "<or absent>", "event": "<see below>", "command_id": <id or absent>, "properties": {...}, "error": "<text or absent>", "sandbox": {...or absent}, "elapsed_ms": <or absent>}` → 204.
`light_version` is the light-tree version the bridge last forwarded; absent
until the first forward. Events: `startup` (loop started; includes `sandbox`
facts: `_VERSION`, `jit.version` if any, and the `type()` of `loadstring`,
`load`, `setfenv`, `package.loaders`, `C4`, plus the driver version from
`C4:GetDriverConfigInfo("version")`), `reload` (new code running),
`reload_failed` (error text; old code may be half torn down), `command_done`
(with `command_id`), `heartbeat` (at most once every 30 s, properties only;
also right after a light forward so `/status` catches up at once).

`GET /status` → `{"running_version": ..., "local_version": ..., "running_light_version": ..., "local_light_version": ..., "last_seen": <unix>, "server_time": <unix>, "last_event": ..., "last_error": ..., "properties": {...}, "pending_commands": [...], "done_commands": [ids], "last_done_id": N}`
`running_light_version` is what the bridge reported forwarding, not what
any light reports (lights never talk to the server). `last_seen` is bumped
by any driver-initiated request. Times are unix seconds as floats.

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
  and, if that version differs from the last forwarded one,
  `GET /bundle?tree=light` and forward it (below); then
  `GET /commands?after=<last id>` and run each command in order, reporting
  `command_done` after each with a properties snapshot; then flush the log
  buffer with `POST /log`; then a heartbeat if one is due. Never start a
  `C4:url` transfer from inside another transfer's `OnHeaders` or
  `OnBodyChunk` callback (Director fails it with curl error 2); timers and
  `OnDone` callbacks are safe.
- Forwarding the light tree: the bundle's `files` object is encoded once
  with `C4:JsonEncode(files, false, true)` (an object of strings, so
  Director's array quirk cannot bite) and sent to every device in
  `C4:GetBoundConsumerDevices(C4:GetDeviceID(), 1)` as
  `C4:SendToDevice(id, "DEV_RELOAD", { version = ..., files = <JSON text> }, false, false)`.
  The two trailing `false`s are `allowEmptyValues` and `logCommand`: with
  the default `logCommand = true` Director would write the ~40 KB bundle to
  its log on every forward. The forwarded version is recorded before
  sending, so a forward that fails is not retried until the server has a
  different version. The loop says how many lights got it (or, once per
  version, that no lights are bound) and makes a heartbeat due at once so
  `/status` shows the new `running_light_version`. A manifest without
  `"tree": "light"` (a server without trees) is said once and ignored.
- Reload sequence: `pcall(OnDriverDestroyed)`; clear every
  `package.loaded` entry matching `^bridge%.`, `^light%.` or `^common%.`
  except `common.devloop`; install (or replace) a loader at
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

### Light

- `devloop.apply_forwarded(params)` is the `DEV_RELOAD` handler
  (`dispatch.commands["DEV_RELOAD"] = devloop.apply_forwarded` in the
  light's `driver.lua`). `params.files` is decoded with `C4:JsonDecode`,
  then the same reload sequence as above runs, with the same `pcall`
  discipline. It needs no `devloop.start()`: the shared state is created
  when the module loads.
- The outcome goes through the light's original `print`, which lands in the
  light's Lua output in Composer, not on the server:
  `devloop: light reload complete: version <v>` or
  `devloop: light reload failed: <error>`. A failed reload leaves the handler
  usable; the next forward retries. `devloop.version()` on a light is the
  forwarded version it last tried.
- A light's reload re-runs its `driver.lua`, which re-registers the handler
  on the fresh `common.dispatch`; `common.devloop` itself stays the copy the
  `.c4z` shipped.

## Developer workflow

```
tools/devserver.py                 # once, in the background on the VM
tools/build.sh --dev               # dev .c4z files for the one-time Composer install
tools/devctl.py status             # are the drivers talking to us, which versions
# edit src/hue_bridge or src/common, then wait ~3 s: the bridge reloads itself
# edit src/hue_light or src/common, then wait ~3 s: the bridge forwards, every bound light reloads
tools/devctl.py run "Connection Test" Target=Bridge   # prints the command id
tools/devctl.py wait 7 --timeout 120                  # until command_done, then properties
tools/devctl.py set "Stream Timeout (s)" 60
tools/devctl.py log -f
```

`devctl.py status` shows both trees, running against local:

```
running_version        1f3a9c0b2d4e  (matches local)
local_version          1f3a9c0b2d4e
running_light_version  8b7e6d5c4a39  (DIFFERS from local; a forward is due)
local_light_version    0c1d2e3f4a5b
last_seen              2s ago
...
```

`running_light_version` reads `bridge has not forwarded yet` until the
bridge's first forward after its loop starts. Both lines are omitted when
the server predates the light tree.

`run`, `set` and `reload` print the bare id so `devctl.py wait $(devctl.py run …)`
works. The server takes `--quiet` to drop per-request connection lines on
the plain listener, and `--state-dir`/`--cert-dir`/`--root` to relocate its
files.

## Security

Dev builds only; LAN only; plain HTTP. Anyone on the LAN who can impersonate
the VM's address can push code into a dev driver, and through the bridge into
every bound light. Never install a dev build as the production driver.

## Gotchas learned on hardware

- **Keep files complete when saving.** The running controller reloads on
  every change to either tree, so a file saved half-written (or a sequence of
  edits that leaves the tree inconsistent between saves) is a real reload:
  the driver is torn down, the broken code fails to come up, and the bridge
  (or every light) is dead until the next consistent save. Write whole files
  at once; when a change spans several files, make it in one save per file
  without pausing between them, or stop the loop first
  (`devctl.py set "Dev Server" ""`) and start it again when done.
- `common/devloop.lua` is the one module a reload never replaces, so an edit
  to it reaches the controller only through a Director restart or a fresh
  `.c4z` install; the bundle carries the new file, but the running copy is
  the one that was `require`d first.
- Director's `C4:JsonEncode` writes Lua arrays as objects with string keys
  even with `encodeArrays = true`; the server accepts both shapes.
- Every reload restarts the event stream, and the abandoned transfer lives
  on until the next bridge event or its timeout (`Cancel()` does nothing).
  After several reloads the stream's queue holds several zombies; they
  drain one per bridge event. `devctl.py run "Hue Request" Method=PUT
  Path=/clip/v2/resource/light/<id> Body='{"metadata":{"name":"X"}}'
  Host=10.00.001.143` (a spelling nothing else uses) generates one event per
  call without touching the light itself; rename back afterwards.
- Edits to `tools/devserver.py` need a server restart. Kill it with a pattern
  that does not appear in your own command line (`pkill -f "devserver[.]p[y]"`)
  and start it in a separate command, or the shell kills itself.
- `build/dev/reports.jsonl` gets a heartbeat every 30 s; prune it when it
  grows.
