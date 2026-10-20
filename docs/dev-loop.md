# Dev loop: pushing code to the live driver without Composer

The dev build of the bridge driver fetches its own Lua from a server on the
development VM, reloads itself when the code changes, runs queued actions,
and ships its log and properties back. After one Composer install of a dev
build, only `driver.xml` changes and Director restarts need Composer.

Dev builds only: `tools/build.sh --dev` includes `src/common/devloop.lua`;
release builds don't contain it at all. The loop is inert until the
`Dev Server` property holds a `host:port`.

## Pieces

- `tools/devserver.py`: the server on the VM. Plain HTTP (default port 8080)
  for the dev loop, plus a TLS listener (default 8443, self-signed) that
  keeps the connection-experiment endpoints `/stream` and `/ping` alive.
  Serves the files under `src/hue_bridge` with `src/common` mounted as
  `common/`, exactly the layout the `.c4z` has.
- `tools/devctl.py`: CLI for the developer: queue actions, set properties,
  force a reload, show status, tail the log.
- `src/common/devloop.lua`: the driver side.

Files written by the server live under `build/dev/` (gitignored):
`driver.log` (shipped log lines), `reports.jsonl` (one JSON object per
report), `commands.json` (the queue).

## Wire protocol (all JSON unless noted; the driver only ever initiates)

`GET /manifest` →
`{"version": "<sha1 over sorted path+contents>", "files": ["driver.lua", "bridge/http.lua", ...], "server_time": <unix seconds>}`

`GET /bundle` →
`{"version": "...", "files": {"driver.lua": "<source>", "bridge/http.lua": "<source>", ...}}`

`GET /file?path=bridge/http.lua` → `text/plain` source, 404 if unknown.
Paths are confined to the served tree.

`GET /commands?after=<id>` →
`{"commands": [ {"id": 7, "type": "execute", "command": "Connection Test", "params": {"Target": "Bridge"}},
                {"id": 8, "type": "set_property", "name": "Stream Timeout (s)", "value": "60"},
                {"id": 9, "type": "reload"} ]}`
Ids increase monotonically across server restarts (persisted in
`commands.json`). A command stays in the queue until the driver reports
`command_done` for it, then moves to a bounded done list; so a driver that
starts fresh and asks `after=0` receives only unacknowledged commands. `execute` goes through the driver's `ExecuteCommand(command,
params)`; `set_property` does `C4:UpdateProperty(name, value)` followed by
`OnPropertyChanged(name)`; `reload` re-runs the reload sequence on the
current version.

`POST /log` body `{"version": "<running version>", "lines": [{"t": <ms since epoch>, "line": "..."}]}` → 204.
The server appends `HH:MM:SS.mmm <line>` to `driver.log` and echoes to stdout.

`POST /report` body
`{"version": "...", "event": "<see below>", "command_id": <id or absent>, "properties": {...}, "error": "<text or absent>", "sandbox": {...or absent}, "elapsed_ms": <or absent>}` → 204.
Events: `startup` (loop started; includes `sandbox` facts: `_VERSION`,
`jit.version` if any, and the `type()` of `loadstring`, `load`, `setfenv`,
`package.loaders`, `C4`, plus the driver version from
`C4:GetDriverConfigInfo("version")`), `reload` (new code running),
`reload_failed` (error text; old code may be half torn down), `command_done`
(with `command_id`), `heartbeat` (at most once every 30 s, properties only).

`GET /status` → `{"running_version": ..., "local_version": ..., "last_seen": <unix>, "server_time": <unix>, "last_event": ..., "last_error": ..., "properties": {...}, "pending_commands": [...], "done_commands": [ids], "last_done_id": N}`
`last_seen` is bumped by any driver-initiated request. Times are unix
seconds as floats.

`POST /admin/enqueue` body `{"type": "execute"|"set_property"|"reload", ...fields as above}` → `{"id": N}`.
Used by `devctl`; the driver never calls it.

## Driver-side behaviour (`common/devloop.lua`)

- `devloop.start(host_port)` is called from `OnDriverLateInit` of a dev build
  when the `Dev Server` property is set. Calling it again with the same host
  is a no-op; with a different host it restarts; `devloop.stop()` stops.
- State lives in a global (`_G.__DEVLOOP`) so a reload cannot lose the loop,
  and `package.loaded["common.devloop"]` is never cleared by a reload.
- A repeating `C4:SetTimer` (3000 ms) drives everything. Each tick: at most
  one `GET /manifest` in flight; if the version differs from the running
  one, `GET /bundle` and reload; then `GET /commands?after=<last id>` and
  run each command in order, reporting `command_done` after each with a
  properties snapshot; then flush the log buffer with `POST /log`. Never
  start a `C4:url` transfer from inside another transfer's `OnHeaders` or
  `OnBodyChunk` callback (Director fails it with curl error 2); timers and
  `OnDone` callbacks are safe.
- Reload sequence: `pcall(OnDriverDestroyed)`; clear every
  `package.loaded` entry matching `^bridge%.` or `^common%.` except
  `common.devloop`; install (or replace) a loader at `package.loaders[1]`
  that serves modules from the bundle (`a.b` → `a/b.lua`); run
  `loadstring(bundle["driver.lua"], "=driver.lua")`; then
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

## Developer workflow

```
tools/devserver.py                 # once, in the background on the VM
tools/build.sh --dev               # dev .c4z for the one-time Composer install
tools/devctl.py status             # is the driver talking to us, which version
# edit src/..., then wait ~3 s: the driver reloads itself
tools/devctl.py run "Connection Test" Target=Bridge   # prints the command id
tools/devctl.py wait 7 --timeout 120                  # until command_done, then properties
tools/devctl.py set "Stream Timeout (s)" 60
tools/devctl.py log -f
```

`run`, `set` and `reload` print the bare id so `devctl.py wait $(devctl.py run …)`
works. The server takes `--quiet` to drop per-request connection lines on
the plain listener, and `--state-dir`/`--cert-dir`/`--root` to relocate its
files.

## Security

Dev builds only; LAN only; plain HTTP. Anyone on the LAN who can impersonate
the VM's address can push code into a dev driver. Never install a dev build
as the production driver.
