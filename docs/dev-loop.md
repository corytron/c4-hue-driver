# Dev loop: pushing code to the live drivers without Composer

The dev build of the bridge driver fetches its own Lua from a server on the
development VM, reloads itself when the code changes, runs queued actions,
and ships its log and properties back. It also fetches the light and scene
drivers' Lua and hands each tree to the bound devices running that driver,
which reload themselves the same way. After one Composer install of a dev
build, only `driver.xml` changes need Composer again (a capability change
also needs the owner's controller reboot, `docs/composer-remote.md` rule 10).

Dev builds only: `tools/build.sh --dev` includes `src/common/devloop.lua` in
all three drivers, with the dev key baked in as `common/devkey.lua`, ships
the bridge's development modules (`bridge/devtools.lua`,
`bridge/conntest.lua`, `bridge/pinning.lua`), keeps the DEV-ONLY blocks of
the bridge's `driver.xml` and allows Composer's Lua command window (dp3
`--allowexecute`); release builds contain none of it. The controller acts
only on what that key signed ("Security" below). The loop is inert until
the bridge's `Dev Server` property holds a `host:port`. Light and scene
devices have no such property: they only react to what the bridge forwards.

**Current state (2026-10-25): in use for a hardware test.** The house ran
release builds from 2026-10-22 (build 116) to 2026-10-24 (build 259); since
2026-10-25 03:24 it runs dev build 309 for the checks of issue #40, and the
release install of issue #228 ends the loop again. `docs/status.md`, "What
runs on the house", is the authority on this. A release build carries no
`common/devloop.lua`, so nothing on the controller polls this VM and no
property can turn the loop on.

To return to the loop: start `tools/devserver.py` (it listens on this VM's
LAN address and creates the dev key on its first run), then build with
`tools/build.sh --dev` (the packages carry that key) from a commit after
the installed one (the version is the commit count, so Composer sees an
update). Install the three dev `.c4z` the way `CLAUDE.md` (Deploy)
describes an install that bypasses `tools/deploy.py`: served from
`build/release/` with `python3 -I -m http.server 8090 --bind 0.0.0.0
--directory build/release` for the duration of the download only, briefed
to the Windows session with their sha256, and recorded afterwards with
`python3 tools/deploy.py record --tag <release tag> --build <N> --at <ISO
time with offset> --note "..." --no-manifest` (`--commit <sha>` names the
commit; deployment 7310056842 recorded dev build 309 this way). A dev
package is as secret as the key it carries ("Security"). `--dev` changes
the Lua that is packed and keeps the DEV-ONLY properties and actions of
`driver.xml`, which a release strips; neither touches `<capabilities>`, so
no reboot is needed unless the commit itself changes them (the dev →
release switch of 2026-10-22 and the dev install of 2026-10-25 03:24
needed none). A release build's `driver.xml` has no `Dev Server` row;
whether Director gives the re-declared row its old value back is not
recorded, so after the install check that the bridge's `Dev Server` holds
the `host:port` the server prints, and have it set with the row's Set
button if not (`docs/composer-remote.md`, rule 7). The loop starts at the
dev build's late init. Leaving again is the release install described
under "Leaving the loop" below.

## Pieces

- `tools/devserver.py`: the server on the VM. Plain HTTP (`--port`, default
  8080) for the dev loop, plus a TLS listener (`--tls-port`, default 8443,
  self-signed) that answers the same endpoints and keeps the
  connection-experiment endpoints `/stream` and `/ping` alive. Both listen
  on one address, by default this VM's LAN address. It signs every bundle
  and command list with the dev key, and wants the admin token on `/status`
  and `/admin/*`. Serves three trees, each a driver's `.lua` and `.xml`
  files and its `certs/` under the paths its `.c4z` uses (a module the
  bundle lacks, such as `common/build_version.lua`, still loads from the
  installed package):
  - `tree=bridge` (the default): `src/hue_bridge` with `src/common` mounted
    as `common/`.
  - `tree=light`: `src/hue_light` with `src/common` mounted as `common/`.
  - `tree=scene`: `src/hue_scene` with `src/common` mounted as `common/`
    (added with the scenes feature, `docs/scenes-design.md` §6).
  A file named `devkey.lua` is never served.
- `tools/devctl.py`: CLI for the developer: queue actions, set properties,
  force a reload, wait for a queued command, pin or unpin the trees, show
  status (every tree), tail the log. It derives the admin token from the
  dev key file and finds the server through `build/dev/server.json`; `log`
  reads `build/dev/driver.log` directly and needs neither.
- `src/common/devloop.lua`: the driver side, in all three drivers. The
  bridge runs the polling loop; a light or scene device only registers the
  `DEV_RELOAD` handler `devloop.reload_handler` builds (it calls
  `devloop.apply_forwarded`, which applies only a bundle signed for its own
  tree) and the `HUE_LOG` log sink of `devloop.forward_logs`
  (`common/device.lua`).
- `src/hue_bridge/bridge/devtools.lua`: the bridge's development handlers
  (the `Dev Server` property, the three DEV-ONLY actions, `HUE_LOG`, and
  the signed-only commands of "Development commands" below) and the
  redactor; `driver.lua` loads it only when `common/devloop.lua` is there.
- The dev key: `~/.config/c4-hue-driver/devkey` on the VM, outside the
  repository, and `common/devkey.lua` inside each dev package ("Security").

Files written by the server live under `build/dev/` (gitignored):
`driver.log` (shipped log lines), `reports.jsonl` (one JSON object per
report), `commands.json` (the queue), `server.json` (the address `devctl.py`
uses, while the server runs).

## Wire protocol (all JSON unless noted; only the bridge ever initiates)

`GET /manifest[?tree=bridge|light|scene]` →
`{"version": "<sha1 over sorted path+contents>", "tree": "bridge", "files": ["driver.lua", "bridge/http.lua", ...], "server_time": <unix seconds>}`
`tree` defaults to `bridge`; an unknown tree is a 400. Each tree has its own
version. The `tree` field tells the driver which tree it got: a server from
before trees existed answers the bridge tree to any `?tree=`, and the loop
must never forward that to the lights. Unsigned: a new version only makes
the bridge fetch a bundle, which must verify.

`GET /bundle[?tree=...]` → a signed envelope (not JSON as a whole):
`<mac>\n<payload>`, where `<payload>` is the JSON
`{"version": "...", "tree": "...", "files": {"driver.lua": "<source>", "bridge/http.lua": "<source>", ...}}`
and `<mac>` the 64-hex-character MAC (label `bundle`) over the payload's
exact bytes ("Security").

`GET /file?path=bridge/http.lua[&tree=...]` → `text/plain` source, 404 if
unknown. Paths are confined to the served tree.

`GET /commands?after=<id>&nonce=<16-64 hex>` → a signed envelope (label
`commands`) whose payload is
`{"nonce": "<as sent>", "commands": [ {"id": 7, "type": "execute", "command": "Connection Test", "params": {"Target": "Bridge"}},
                                      {"id": 8, "type": "set_property", "name": "Stream Timeout (s)", "value": "60"},
                                      {"id": 9, "type": "reload"} ]}`
A missing or malformed `nonce` is a 400, and so is an `after` that is not
an integer.
Ids increase monotonically across server restarts (persisted in
`commands.json`). A command stays in the queue until the driver reports
`command_done` for it, then moves to a bounded done list; so a driver that
starts fresh and asks `after=0` receives only unacknowledged commands.
`execute` runs the bridge's development command of that name when it has
one (the table it hands to `devloop.set_signed_commands`, named the way
`common/dispatch.lua` names commands, so `Hue Request` finds `Hue_Request`
and `LUA_ACTION` is unwrapped to its `ACTION`), else the driver's
`ExecuteCommand(command, params)`, which serves Composer's actions;
`set_property` does `C4:UpdateProperty(name, value)`, sets
`Properties[name]` as Director does, then calls `OnPropertyChanged(name)`;
`reload` forgets refused versions and re-runs the
reload sequence on the current bridge version (it does not re-forward the
light tree; touch a file under `src/hue_light` or `src/common` for that).

`POST /log` body `{"version": "<running version>", "lines": [{"t": <ms since epoch>, "line": "..."}]}` → 204.
The server appends `HH:MM:SS.mmm <line>` to `driver.log` and echoes to stdout.

`POST /report` body
`{"version": "...", "light_version": "<or absent>", "scene_version": "<or absent>", "event": "<see below>", "command_id": <id or absent>, "properties": {...}, "error": "<text or absent>", "sandbox": {...or absent}, "elapsed_ms": <or absent>, "key_fingerprint": "<16 hex, absent without a key>"}` → 204.
`light_version` / `scene_version` are the tree versions the bridge last
fetched and forwarded (recorded even when no device of that kind was bound
to receive them); absent until the first forward. Events: `startup` (loop started; includes `sandbox`
facts: `_VERSION`, `jit.version` if any, and the `type()` of `jit`,
`loadstring`, `load`, `setfenv`, `package`, `package.loaders`, `C4` and
`bit`, the HMAC in use
(`hmac`: `C4:HMAC` or `Lua (<why>)`), plus the driver version from
`C4:GetDriverConfigInfo("version")`), `reload` (new code running; its
`error` carries the text of an `OnDriverDestroyed` that failed),
`reload_failed` (error text; old code may be half torn down), `refused`
(a bundle did not verify: `tree`, `refused_version`, `error`; once per
version), `command_done` (with `command_id`, `elapsed_ms` and, when the
command failed, its redacted `error`), `heartbeat` (at the end of a tick
when no report went out for 30 s, properties only; also right after a new
light or scene version is forwarded, so `/status` catches up at once).

`GET /status` (admin token) → `{"running_version": ..., "local_version": ..., "running_light_version": ..., "local_light_version": ..., "running_scene_version": ..., "local_scene_version": ..., "pinned": {...}, "last_seen": <unix>, "server_time": <unix>, "last_event": ..., "last_error": ..., "properties": {...}, "pending_commands": [...], "done_commands": [ids], "last_done_id": N, "key_fingerprint": "<the server's>", "driver_key_fingerprint": "<last reported, or null>", "driver_reported_key": <whether any report said yet>}`
(plus `live_version`, `live_light_version` and `live_scene_version`, what
the working trees are now; they differ from `local_*` only while pinned).
`running_light_version` / `running_scene_version` are what the bridge
reported forwarding, not what any device reports (light and scene devices
never talk to the server). `last_seen` is bumped by any driver-initiated
request. Times are unix seconds as floats.

`POST /admin/enqueue` (admin token) body `{"type": "execute"|"set_property"|"reload", ...fields as above}` → `{"id": N}`.
`POST /admin/pin[?tree=...]` and `POST /admin/unpin[?tree=...]` (admin
token) → `{"pinned": {...}}`. Used by `devctl`; the driver never calls them.
Without the token, or with a wrong one: 401.

## Driver-side behaviour (`common/devloop.lua`)

### Bridge

- `devloop.start(host_port)` is called at the end of the bridge's
  `OnDriverLateInit` in a dev build when the `Dev Server` property is set
  (`devtools.late_init`), and again whenever the row changes after late
  init; an emptied row stops the loop. Calling it again with the same host
  is a no-op; with a different host it restarts; `devloop.stop()` stops. A
  package without a dev key still starts (and says once that it will refuse
  every bundle and command), so the log and the reports still reach the
  server.
- State lives in a global (`_G.__DEVLOOP`) so a reload cannot lose the loop,
  and `package.loaded["common.devloop"]` is never cleared by a reload. The
  dev key is not in that global: it lives in a local of the module.
- A repeating `C4:SetTimer` (3000 ms) drives everything. Each tick: at most
  one chain in flight; `GET /manifest` and, if the version differs from the
  running one, `GET /bundle`, verify, and reload; then
  `GET /manifest?tree=light` and, if that version differs from the one the
  bridge holds, `GET /bundle?tree=light` once and verify; then forward the
  held bundle to every bound light that has not received that version
  (below); then the same for `tree=scene` and the bound scene devices; then
  `GET /commands?after=<last id>&nonce=<fresh>`, verify, and run each
  command in order, reporting `command_done` after each with a properties
  snapshot; then flush the log buffer with `POST /log`; then a heartbeat if
  one is due. A tick that finds the previous chain still in flight is
  skipped, and after ten such ticks that chain is abandoned (its callbacks
  are dropped). An unreachable server is said once per change. Never start
  a `C4:url` transfer from inside another transfer's `OnHeaders` or
  `OnBodyChunk` callback (Director fails it with curl error 2); timers and
  `OnDone` callbacks are safe.
- A bundle that does not verify, or is signed for another tree, is refused:
  `devloop: bridge bundle <version> refused: signature mismatch` (once per
  version) and a `refused` report; nothing is torn down. That version is
  fetched again at most every `REFUSED_RETRY_MS` (60 s), silently; a `reload`
  command forgets the refusals at once.
- A command list that does not verify, or answers another nonce, runs
  nothing (`devloop: commands refused: ...`, once per streak). A command
  whose id is not above the last one run is skipped.
- Forwarding a tree (light or scene): the bridge keeps the signed bundle it
  last fetched per tree (`light_version` / `scene_version` plus the payload
  and its MAC) and, per bound device id, the version that device last
  received (`__DEVLOOP.light_forwarded`, `__DEVLOOP.scene_forwarded`). Light
  and scene devices share binding 1, so every tick it reads
  `C4:GetBoundConsumerDevices(C4:GetDeviceID(), 1)`, learns each new id's
  `driverFileName` once with `C4:GetDevices` (`hue_light.c4z` → light tree,
  `hue_scene.c4z` → scene tree; an unreadable one counts as a light), drops
  ids no longer bound, and sends the tree's bundle to each bound device of
  that kind whose recorded version is not the held one, as
  `C4:SendToDevice(id, "DEV_RELOAD", { tree = ..., version = ..., bundle = <signed payload>, mac = <its MAC> }, false, false)`.
  The payload is the server's text, unchanged, so the device checks the
  very bytes the server signed; `tree` and `version` ride along unsigned,
  for filtering and log lines. The two trailing `false`s are
  `allowEmptyValues` and `logCommand`: with the default `logCommand = true`
  Director would write the ~100 KB bundle to its log on every forward. So a
  new version reaches every bound device of its kind once (`light version X
  forwarded to N light device(s)`), and a device bound afterwards, for
  example one Add Light just created, gets the current version on the next
  tick from the held bundle, without a refetch and without the version
  changing (`light version X forwarded to N newly bound light device(s)`). A
  version first seen with nothing of its kind bound is said once (`scene
  version X: no bound scene devices`) and still held for the devices to
  come. The version is recorded per device before the send, so a device
  whose `SendToDevice` fails is not retried until the server has a different
  version; a device that is unbound and bound again is treated as new. A new
  version makes a heartbeat due at once so `/status` shows the new running
  version of that tree; a catch-up does not. A manifest without the
  requested `"tree"` (a server without trees) is said once and ignored.
- Reload sequence: `pcall(OnDriverDestroyed)`; clear every
  `package.loaded` entry matching `^bridge%.`, `^light%.`, `^scene%.` or
  `^common%.` except `common.devloop`; install (or replace) a loader at
  `package.loaders[1]` that serves modules from the bundle (`a.b` →
  `a/b.lua`); run `loadstring(bundle["driver.lua"], "=driver.lua")`; then
  `OnDriverInit("DIT_UPDATING")` and `OnDriverLateInit("DIT_UPDATING")`.
  Every step is `pcall`ed. An `OnDriverDestroyed` that fails is said and the
  reload goes on (the `reload` report carries its text); any later failure
  posts `reload_failed` and the loop keeps polling. The version is recorded
  before anything can fail, so a failed version is not loaded again: the
  next pushed version, or a `reload` command, retries. Only a verified
  bundle ever reaches this sequence.
- Signed commands: the bridge's development commands (`Hue Request`, `Probe
  Call`, `Probe Project`, `Probe Errors`, `Probe Scenes`, `Proxy Command`,
  `Lights Report`, and `Test Connection` with a `Host`) are not in its
  dispatch table. `bridge/devtools.lua` hands them to
  `devloop.set_signed_commands(handlers)`, keyed by dispatch name, at every
  load of `driver.lua`, a reload's included; `devloop.execute(command,
  params)` runs a verified `execute` command through that table first and
  through the global `ExecuteCommand` otherwise, looking both up as the
  command runs (so a signed `Test Connection` always takes the development
  handler, with a `Host` or without). A reload that fails before
  `devtools.install` keeps the previous table, as it keeps the previous
  `ExecuteCommand`. A handler that raises is said (`devloop: signed command
  <name> failed: <error>`, `<name>` the dispatch name) and reported in
  `command_done`; the next command runs. Why: "Security", "Development
  commands" below.
- Log capture: wrap `_G.print` once (keeping the original for Composer) so
  everything the driver prints is buffered and shipped; keep at most 500
  lines, dropping the oldest. The loop's own messages use the original print
  and are also buffered.
- Redaction: every line passes the redactor the bridge installs with
  `devloop.set_redactor(fn)` (`fn(line)` returns what of the line may leave
  the controller; nil keeps nothing) when it is buffered, and again when it
  is shipped, so a line buffered before the redactor knew the key (a
  reload's new code learns it only at its late init) leaves without it too.
  A redactor that raises, or answers anything but a string or nil, withholds
  the line: `devloop: a log line was withheld (the redactor failed on it)`
  stands in its place. A line the redactor prints itself is withheld the
  same way instead of being handed back to it. The `error` text of a report
  passes the redactor as well. The bridge's redactor (`redact_key` in
  `bridge/devtools.lua`, installed with the signed commands) replaces the
  application key the driver holds at that moment with `<key>`, by plain
  search; until the bridge installs one, lines pass unchanged. The redactor
  is kept across a reload until the new code installs its own. Composer's
  own output (the original print) is not redacted. `devloop.redacted(line)`
  gives the verdict, for the specs.
- Properties snapshot: a copy of the `Properties` table. If `C4` is a Lua
  table, also wrap `C4.UpdateProperty` once to shadow values the driver sets
  itself; report `type(C4)` in the sandbox facts either way.
- Nothing in the loop ever prints or reports the Hue application key, the
  dev key or a MAC it computed to check one it received; the redactor
  (above) keeps the application key out of every shipped line, whatever
  printed it.

### Light and scene devices

- `devloop.apply_forwarded(params)` does the reload; each device's
  `DEV_RELOAD` handler calls it after checking `params.tree` (a bundle for
  the other tree is ignored, and `apply_forwarded` itself skips a tree that
  is not its driver's own). It verifies `params.bundle` against
  `params.mac` with the device's own baked key and refuses anything else
  (no bundle, no or a wrong MAC, the old `files` form), then decodes the
  payload with `C4:JsonDecode` and loads it only when the signed `tree` is
  the device's own (`light` or `scene`, never `bridge`); then the same
  reload sequence as above runs, with the same `pcall` discipline, at the
  signed version. It needs no `devloop.start()`: the shared state is created
  when the module loads.
- The outcome goes through the device's original `print`, which lands in
  its Lua output in Composer, not on the server:
  `devloop: light reload complete: version <v>`,
  `devloop: scene reload failed: <error>` or
  `devloop: light reload refused: signature mismatch`. The device's own
  follow-up line ("light reloaded to version <v>", "scene reload failed; …",
  "light reload refused (…)") also reaches the bridge's shipped log as
  `HUE_LOG`, as every non-debug line of a dev build's device does. A failed
  or refused reload leaves the handler usable and the running code in place
  (a refusal tears nothing down); the next forward retries.
  `devloop.version()` on a device is the forwarded version it last tried.
- A device's reload re-runs its `driver.lua`, which re-registers the handler
  on the fresh `common.dispatch`; `common.devloop` itself stays the copy the
  `.c4z` shipped.

## Developer workflow

```
tools/devserver.py --quiet         # once, in the background on the VM; prints its URL and the key fingerprint
tools/build.sh --dev               # dev .c4z files for the one-time Composer install (they carry the dev key)
tools/devctl.py status             # are the drivers talking to us, which versions, does the key match
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

The server's first lines name the dev key's fingerprint (which `build.sh
--dev` prints too) and where it listens: `listening on http://<LAN
address>:8080 and https://<LAN address>:8443 (Dev Server = <LAN
address>:8080)`, the last part being the bridge's `Dev Server` value.
`devctl.py` finds the server through `build/dev/server.json`; `--server
URL` overrides it.

`tools/regress.sh [--server URL]` runs the scripted part of
`docs/release-checklist.md` §1 through `devctl.py`: `Test Connection`,
`Refresh Scenes`, `Room Audit`, `Link Devices`, `Adopt Hue Names`, `Accept
Names As They Are` and `Lights Report`, then a scan of the shipped log for
errors, and exits with the number of failed checks. It creates and deletes
nothing, but `Adopt Hue Names` renames a device whose Composer name differs
and `Link Devices` registers a bound device the bridge lacks, as those
actions always do.

Pin while several agents edit `src/` at once: the controller then only
reloads to states the coordinator has checked (`tools/check.sh --only
lua-lint lua-test` green), each pushed by a fresh `pin`. `status` shows a
`pinned` line with the pinned versions and what the live trees have become.

`devctl.py status` shows every tree, running against local:

```
running_version        1f3a9c0b2d4e  (matches local)
local_version          1f3a9c0b2d4e
running_light_version  8b7e6d5c4a39  (DIFFERS from local; a forward is due)
local_light_version    0c1d2e3f4a5b
running_scene_version  5e6f7a8b9c0d  (matches local)
local_scene_version    5e6f7a8b9c0d
dev_key                matches the server's (fingerprint 3f9a0c1d2e4b5a6c)
last_seen              2s ago
...
```

`running_light_version` and `running_scene_version` read `bridge has not
forwarded yet` until the bridge's first forward after its loop starts.
Each pair is omitted when the server predates that tree. `dev_key` reads
`DIFFERS` when the installed dev build was made with another key, and
`DRIVER HAS NONE` when it carries no key: the controller then refuses
everything the server signs.

`run`, `set` and `reload` print the bare id so `devctl.py wait $(devctl.py run …)`
works; `wait` gives up after `--timeout` seconds (default 60) with exit
code 2. `pin` and `unpin` take `--tree bridge|light|scene` (default: all
three); `log` takes `-n`/`--lines` (default 50), `-f`/`--follow` and
`--file`. The server takes `--quiet` to drop the plain listener's
connection and request lines and the heartbeat summaries, `--port` and
`--tls-port`, `--bind` to listen elsewhere, `--key-file` for another key,
`--state-dir`/`--cert-dir`/`--root` to relocate its files, `--alpn` for the
protocols its TLS listener offers, and `--ensure-key` ("The dev key"
below); `devctl.py` takes `--server`, `--key-file` and `--state-dir`.
`C4_HUE_DEVKEY_FILE` names another key file for all three tools.

### Leaving the loop (production)

A release build (`tools/build.sh` without `--dev`) ships no
`common/devloop.lua` and no key; every driver requires the loop with
`pcall`, so the same `driver.lua` starts without it and the bridge simply
never contacts this VM again. Since build 259 (2026-10-24) the house gets
a GitHub release, never a VM build. Before installing one:
`devctl.py set "Debug Mode" Off` (the property survives the update, and
`deploy/house.yaml` wants it Off), then the GitOps install of
`docs/release-checklist.md`, "Deploy to the house" (`tools/deploy.py
start`, its brief to the Windows session, `tools/deploy.py done`).
`devctl.py status` then shows `last_seen` growing; stop `devserver.py`.
A release's `driver.xml` has no DEV-ONLY block, so the `Dev Server` and
`Diagnostic Server` rows and the `Connection Test`, `Reload Credentials`
and `Check CA Pinning` actions leave Composer (release checklist §2, lines
2 and 3). Done for the first time on 2026-10-22 (version 116 over dev
build 84); the house then stayed on release builds until the dev builds of
2026-10-25 (276, 284 and 309). Returning to the loop: "Current state" at
the top.

## Security

Dev builds only. A release build carries no `common/devloop.lua`, no
`bridge/devtools.lua` and no dev key, and `tools/build.sh` refuses to package
one that does. This section is the design that closes issue #52 (findings 13
to 16 of `docs/reviews/security-2026-10-24.md`), with the development
command rules of issue #217 (findings 9 and 10 of
`docs/reviews/security-2026-10-25.md`).

The loop runs over plain HTTP on the LAN: anything on the LAN can read it,
and anything that can answer as the VM's address can alter it. Nothing on
the wire is secret (finding 16, below). What keeps the loop from being
remote code execution is that the controller acts only on what the dev key
signed, and the key never crosses the wire.

### The dev key

- 32 random bytes, written as 64 lowercase hex characters to
  `~/.config/c4-hue-driver/devkey` (under `$XDG_CONFIG_HOME` when that is
  set; `C4_HUE_DEVKEY_FILE` or `--key-file` name another file), outside the
  repository. The first `tools/devserver.py` or `tools/build.sh --dev`
  creates it, mode 0600 in a 0700 directory; `tools/devserver.py
  --ensure-key` does only that and prints the path. A key file that group
  or others can read, or that is not 64 lowercase hex characters, is
  refused.
- `tools/build.sh --dev` bakes it into each of the three dev packages as
  `common/devkey.lua` (`return "<hex>"`), written into the stage only (umask
  077) and deleted from it once packed; the dev `.c4z` files are written
  0600. Every build refuses to run while a `src/common/devkey.lua` exists,
  and a release build refuses to package one, so the key is never served
  from, committed with or released in the source tree. `devserver.py` never
  serves a file of that name.
- On the controller, `common/devloop.lua` reads it once, at load, into a
  local of the module: never into `_G.__DEVLOOP`, a property, a report or a
  log line.
- Every MAC is HMAC-SHA256 keyed with those 64 characters (as ASCII), over
  `c4-hue-devloop/1\n<label>\n<data>`, as lowercase hex. The labels are
  `bundle`, `commands`, `admin-token`, `fingerprint` and `nonce`, so a MAC
  made for one purpose is never valid for another.
- The fingerprint, the first 16 hex characters of the `fingerprint` MAC of
  nothing, names a key without revealing it: `build.sh --dev` and the server
  print it, the bridge reports it (`key_fingerprint`), and the server warns
  at once when the driver's differs from its own (`devctl.py status`, row
  `dev_key`).
- The tools print the key file's path and the fingerprint, never the key.
  `build.sh` handles the key with shell builtins only, so it is never on a
  command line.

### What the controller checks

- **Bundles (finding 13).** `GET /bundle` answers `<mac>\n<payload>`, the
  MAC (label `bundle`) over the exact bytes of the JSON payload `{"version",
  "tree", "files"}`. The bridge checks it before decoding anything, and the
  payload's `tree` must be the tree it asked for. A bundle that is unsigned,
  does not match or was signed for another tree is refused with one line
  (`devloop: bridge bundle <version> refused: signature mismatch`) and a
  `refused` report; nothing is torn down and the running code stays. Only a
  verified bundle ever reaches `loadstring`.
- **Commands (finding 13).** Each `GET /commands` carries a fresh nonce,
  32 hex characters derived with the key from a per-load value and a
  counter, so it never repeats, not even after a reboot. The answer is
  `<mac>\n<payload>` with the MAC (label `commands`) over `{"nonce",
  "commands"}`. The bridge runs nothing from an answer that does not verify
  or carries another nonce, so a recorded answer cannot be replayed; within
  a load, a command id must also be above the last one run. Signed commands
  cover `set_property` (`Dev Server`, `Bridge IP Address`, ...) and
  Composer's actions alike, and they are the only way to the development
  commands (`Probe Call`, `Hue Request`, ...; "Development commands" below).
- **`DEV_RELOAD` (finding 14).** The bridge forwards a light or scene bundle
  unchanged: the signed payload and its MAC. The device verifies them with
  its own baked key and loads only a payload signed for its own tree
  (`light` or `scene`; never `bridge`). A `DEV_RELOAD` from any other
  driver in the project, the bridge's own bundle replayed, or a bundle in
  the old unsigned form is refused the same way, with the running code
  untouched: `devloop: light reload refused: signature mismatch` in the
  device's Lua output and `light reload refused (...)` forwarded to the
  bridge. The check is inside `devloop.apply_forwarded`, which the
  `DEV_RELOAD` handler `common/device.lua` registers
  (`devloop.reload_handler`) calls, so the registration is unchanged.
- **Which HMAC.** `C4:HMAC("SHA256", key, data, { return_encoding = "HEX",
  key_encoding = "NONE", data_encoding = "NONE" })` [verified: DriverWorks
  API docs, Encryption interface, `HMAC` and `GetSupportedDigests`, both
  available from 1.6.0; the Safe Usage table allows them before late init].
  At first use the loop checks it against RFC 4231 test case 2 and falls
  back to the pure-Lua HMAC-SHA256 in `devloop.lua` when `C4:HMAC` is
  missing, raises or answers wrong (measured under PUC Lua 5.1 on the VM:
  about 0.4 MB/s, 1.7 s for the 0.6 MB bridge bundle, 0.35 s for a light
  bundle; on the controller it is slower [assumed]; the specs pin it to the
  RFC 4231 and FIPS 180 vectors). On OS 3.4.2 `C4:HMAC` exists and passes
  that test, so the loop uses it [verified: hardware 2026-10-25, dev build
  276; `docs/design.md`, "Hardware facts of the 2026-10-25 dev pass"]. The
  startup report's `sandbox.hmac` says which one runs.
- A received MAC is compared over its full length, and the MAC the
  controller expected is never logged or reported: it would let whoever
  answers as the server sign a payload of their choosing.

### Development commands (findings 9 and 10 of 2026-10-25)

`docs/reviews/security-2026-10-25.md`; contract
`docs/security-fixes-design.md` §2.

- **Out of the dispatch table.** `ExecuteCommand` has no sender parameter
  [verified: `5_director_command/_1-ExecuteCommand` in the DriverWorks API
  docs], so whatever sits in the bridge's dispatch table, any driver in the
  project can run with `C4:SendToDevice`. A dev build adds to that table
  only what Composer itself sends, the actions of the DEV-ONLY block of
  `src/hue_bridge/driver.xml` (`Connection Test`, `Reload Credentials`,
  `Check CA Pinning`) and the `Dev Server` property, plus `HUE_LOG`
  (`devtools.install`). The rest runs only for a signed `execute` command
  (above): `Hue Request`, `Probe Project`, `Probe Errors`, `Probe Scenes`,
  `Probe Call`, `Proxy Command`, `Lights Report` and `Test Connection`'s
  `Host` variant. Composer's `Test Connection` is the driver's own handler,
  which takes no parameters; another driver that sends it with a `Host`
  gets the dotted address.
- **`HUE_LOG` stays reachable.** The light and scene devices send their log
  lines with `C4:SendToDevice` (`devloop.forward_logs`), which arrives
  through `ExecuteCommand`, so the handler must stay in the table. All it
  does is print one line under the sender's name; control characters
  become spaces, so a message cannot forge further lines of the shipped
  log.
- **`Hue Request`** takes `Host` only as a spelling of the bridge's address
  (finding 15 of 2026-10-24, below) and `Path` only when it starts with
  `/` and holds no `@`, `\`, `#`, white space or control characters,
  since `bridge/http.lua` joins `https://`, the host and the path:
  `@203.0.113.9/...`, `.example.net/...` or `:8443/...` would carry the key
  to another host or port. Anything else is refused (`Hue Request: Path
  "<path>" refused: ...; nothing is sent`). An empty `Path` means the
  bridge resource.
- **The identity check first.** `Hue Request`, `Connection Test` against
  the bridge and `Test Connection` with a `Host` send nothing while the
  bridge identity check has not passed (`bridge identity not verified yet`;
  Status keeps what the check said). `Test Connection` without a `Host`
  runs the check itself before its keyed request (`driver.lua`).
- **`Probe Call`** refuses a `Persist` call that names an entry of the
  credential store, or names none (`PersistDeleteAll` would delete them
  with everything else) [the persistence calls: section `26.5_persistence`
  of the DriverWorks API docs]: `Probe Call: C4.<Fn> refused: <why>;
  nothing was called`. A `Persist` call is any method whose name starts
  with `Persist`, in any case. The names come from `bridge/credentials.lua`
  at run time, are compared loosely (case, padding, a NUL ending the
  string) and are never logged; when they cannot be read, every `Persist`
  call is refused. Any other entry can still be probed.
- **Redaction.** The bridge's redactor replaces the application key in
  every shipped line and every reported error text (above), so even a
  probe that printed it would not put it on the wire.
- **An older loop.** `common/devloop.lua` is the one module a reload never
  replaces: code pushed to a bridge whose loop predates signed commands
  leaves the development commands and the redactor out and says so once
  per load (`dev loop: the running common/devloop.lua predates signed
  commands; ...`). Install a dev `.c4z` made from the same commit as the
  server.

### What the server checks

- It listens on one address, both listeners: `--bind`, by default this
  VM's LAN address (the source address of its default route, found at
  start; no packet is sent); `0.0.0.0` only when `--bind 0.0.0.0` says so.
  The address goes to `build/dev/server.json`, where `devctl.py` finds it.
- The developer endpoints, `/status` and `/admin/*`, want the header
  `X-Devloop-Token: <the admin-token MAC of nothing>`. `devctl.py` derives
  it from the key file, so it never leaves the VM when `devctl.py` runs
  there (as it must for `log`). Without it, or with a wrong one: 401 and one
  `DENY` line on the console, without the value presented.
- Unauthenticated by design: `/manifest` (a hint, see above), `/file` (the
  repository's own source), `/ping` and `/stream` (the connection
  experiment), and the controller's `POST /log` and `POST /report`.
  `/bundle` and `/commands` want no token either: they are signed.

### What is left

- **Reading (finding 16).** Bundles (public source), reports (every
  property: bridge address and id, counts, names) and log lines cross the
  LAN in clear. None of it is secret: the Hue application key is never in a
  property, a report or a bundle, the redactor takes it out of every
  shipped line and reported error, and the dev key is in none of them. A
  `Hue Request` that creates a new key (`POST /api` with the link button
  pressed) logs that new key in its summary: the redactor knows only the
  key the driver holds.
- **Withholding.** Anything that can answer as the VM can stop reloads and
  commands: a denial of service, nothing more.
- **Rollback.** A bundle the developer signed earlier can be replayed; the
  bridge then runs that earlier state until a genuine tick brings the
  current one back.
- **Spoofing the server's view.** Anything on the LAN can post log lines
  and reports to the server, for instance a `command_done` that drops a
  pending command unrun. The server's view is advisory; nothing on the
  controller depends on it.
- **The key is as secret as a dev package.** Whoever holds a dev `.c4z`
  holds the key: they can sign bundles and commands for every dev build
  made with it, and derive the admin token. Keep dev packages off shared
  places, serve them for the Windows download only for its duration (the
  Deploy HTTP server listens on every address), and never attach one to a
  release (the release workflow builds without `--dev`, and
  `tools/deploy.py` refuses a manifest that says `dev: true`). To rotate the
  key: delete the key file, run `tools/build.sh --dev` (it creates a new
  one), restart `devserver.py`, install the new dev build. Installing a
  release build ends the loop, and the old key's use with it.
- `Dev Server` stays empty when the loop is not in use; a release build
  has no such row.
- **Development handlers (finding 15).** `Hue Request` and
  `Test Connection` take `Host` only as a spelling of the bridge's own
  address as `bridge/altaddr.lua` writes them (an octet below 8 with up to
  two leading zeros; every other octet as it is): anything else is refused
  (`Host "<x>" refused: not a spelling of the bridge address <ip>`) and
  nothing is sent, so the application key goes only to the bridge's
  address. `Hue Request` also waits, like every request of the driver, for
  the bridge identity check (`bridge identity not verified yet`). `Probe
  Call` (any `C4` method but the credential store's `Persist` calls),
  `Proxy Command`, `Lights Report` (radio MAC addresses) and the other
  development commands answer signed commands only ("Development
  commands" above). What any driver in the project can still send through
  `ExecuteCommand` is Composer's own actions, `Connection Test` against
  the `Diagnostic Server` (unverified TLS, no key) among them, and
  `HUE_LOG`, one log line each (the DriverWorks trust model, finding 9 of
  2026-10-24).

Never install a dev build as the production driver.

## Gotchas learned on hardware

- **Keep files complete when saving.** The running controller reloads on
  every change to any tree, so a file saved half-written (or a sequence of
  edits that leaves the tree inconsistent between saves) is a real reload:
  the driver is torn down, the broken code fails to come up, and the bridge
  (or every light) is dead until the next consistent save. Write whole files
  at once; when a change spans several files, make it in one save per file
  without pausing between them, or `devctl.py pin` first and pin again once
  the tree is consistent. `devctl.py set "Dev Server" ""` stops the loop
  altogether: the bridge then polls nothing, so only Composer can start it
  again (the `Dev Server` row and its Set button), and that command never
  reports `command_done`, since the loop stops before it can.
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
  forward happens. The same holds for the signing: a dev build from before
  issue #52 neither signs nor verifies, and a server from after it refuses
  to talk to it (`nonce` 400s, bundles it cannot read); install a dev build
  made from the same commit as the server.
- Director's `C4:JsonEncode` writes Lua arrays as objects with string keys
  even with `encodeArrays = true`; the server accepts both shapes.
- Every reload restarts the event stream, and the abandoned transfer lives
  on until the next bridge event or its timeout (`Cancel()` does nothing).
  After several reloads several zombies are open; they drain one per
  bridge event. (Since the stream address rotation of 2026-10-21 a new
  stream no longer waits behind them, `docs/design.md`, "Stream address
  rotation".) Within one load the stream keeps at most two transfers open
  (`stream.MAX_ABANDONED + 1`, `Waiting for an earlier stream transfer to
  close` meanwhile), but a reload cannot see its predecessor's, and
  Director runs at most four `C4:url` transfers at once across all hosts:
  three reloads within fifteen minutes on a quiet night left three zombies
  plus the live stream, and every other request, the dev loop's own
  included, timed out until the bridge's next event (verified 2026-10-25,
  `docs/design.md`, "Concurrent transfers"). Space reloads out on a quiet
  house. While a transfer is still free, `devctl.py run "Hue Request"
  Method=PUT Path=/clip/v2/resource/light/<id>
  Body='{"metadata":{"name":"X"}}' Host=<a padded spelling of the bridge
  address that nothing else uses>` generates one event per call without
  touching the light itself; rename back afterwards. (`Hue Request`, the
  `Probe` commands, `Proxy Command` and `Lights Report` exist only in dev
  builds, and answer only signed commands: `devctl.py run`.)
- Edits to `tools/devserver.py` need a server restart. Kill it with a pattern
  that does not appear in your own command line (`pkill -f "devserver[.]p[y]"`)
  and start it in a separate command, or the shell kills itself.
- `build/dev/reports.jsonl` gets a heartbeat every 30 s; prune it when it
  grows.
