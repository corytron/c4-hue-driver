# Security fixes of 2026-10-25 (issue #217)

The contract for the fixes to `docs/reviews/security-2026-10-25.md`
(14 findings: Medium 1, 9, 11; Low 2, 3, 4, 5, 10, 12, 14; Info 6, 7, 8, 13).
Branch `fix/security-review-217`, cut from `refactor/lifecycle-keypad-56-57`
at f96c595 (PRs #214 and #216, which merge first). Every agent builds against
this text; the finding numbers are the review's.

## 1. Who owns which file

One writer per file. Nobody runs `git`; the coordinator integrates, lints,
tests, builds and commits.

| Owner | Files (create or edit) | Findings |
|---|---|---|
| coordinator | `src/hue_bridge/driver.lua`, `src/*/driver.xml`, `tests/spec/drivers_spec.lua`, `tools/build.sh`, `CLAUDE.md`, this file, `docs/status.md` | 1, 2, 4, driver side of 3, 5, 6, 8, 14 (VM clean-up) |
| stream-http | `src/hue_bridge/bridge/stream.lua`, `bridge/http.lua`, `bridge/sse.lua`, `tests/spec/stream_spec.lua`, `tests/spec/http_spec.lua`, `tests/spec/sse_spec.lua`, `tests/helpers/fake_c4.lua` | 5, 6, 7, `http.url` part of 10 |
| dev-surface | `src/hue_bridge/bridge/devtools.lua`, `bridge/conntest.lua`, `bridge/pinning.lua`, `src/common/devloop.lua`, `tests/spec/devloop_spec.lua`, `tests/spec/conntest_spec.lua`, `tests/spec/pinning_spec.lua`, `docs/dev-loop.md` | 9, 10 |
| names | `src/hue_bridge/bridge/util.lua`, `bridge/owner.lua`, `bridge/lights.lua`, `bridge/scenes.lua`, `bridge/zone_lights.lua`, `tests/spec/util_spec.lua`, `tests/spec/owner_spec.lua`, `tests/spec/lights_spec.lua`, `tests/spec/scenes_spec.lua`, `tests/spec/zone_lights_spec.lua` | 8 |
| tls-docs | `src/hue_bridge/bridge/tlscheck.lua`, `tests/spec/tlscheck_spec.lua`, `docs/design.md`, `src/hue_bridge/www/documentation.html` | 3 |
| workflows | `.github/workflows/release.yml`, `ci.yml`, `dependabot-auto-merge.yml`, `.github/dependabot.yml`, `tools/deploy.py`, `tools/tests/test_deploy.py`, `tools/check.sh`, `SECURITY.md`, `docs/cicd-gitops-design.md`, `docs/release-checklist.md` | 11, 12, 13, 14 (local scan), checklist part of 3 |

A change another owner's file needs goes into the hand-back as exact text
for the coordinator, not into the file.

## 2. Interfaces between the pieces

### bridge/http.lua (stream-http)

- `http.url(ip, path)` raises (`error`) unless `path` is a string that starts
  with `/`. Release code always passes a literal `/clip/...` or `/api...`.
- `http.request` and `http.stream` turn that raise into an ordinary failure:
  `callback({ ok = false, err = "invalid request path" })`, or
  `on_done(-2, "invalid request path", nil)`, logged like any other failure.
  No transfer is created.
- `http.decode(body)` never raises: `C4:JsonDecode` runs under `pcall`, and a
  raise becomes `nil, "invalid JSON: <message>"`.
- A request with `req.key` set refuses redirects: an `OnHeaders` handler
  returns true (abort) for a code from 300 to 399, and the result is
  `{ ok = false, code = <the 3xx>, err = "redirect refused (HTTP <code>)" }`
  whatever `OnDone` then reports. Requests without a key (identity check,
  TLS decoy, pairing) keep today's behaviour.

### bridge/stream.lua (stream-http)

- Open stream transfers, live plus abandoned, never exceed
  `stream.MAX_ABANDONED + 1` (two today). The watchdog keeps its check
  (`open_abandoned() >= MAX_ABANDONED`: it abandons a live transfer before
  opening one). Every other new transfer waits while
  `self:open_abandoned() >= stream.MAX_ABANDONED + 1`: `connect()` sets the
  status to `Waiting for an earlier stream transfer to close` and tries again
  after the current backoff, without opening a transfer. A single
  Disconnect/Connect therefore reconnects at once next to one abandoned
  transfer; a second restart within that window waits (diff review
  2026-10-25 row 1). This covers start
  after stop (Disconnect, then Connect Event Stream), `restart_stream` in the
  driver (a new stream object shares `opts.abandoned`), an address change and
  the oversized-line reconnect.
- Every path that gives up an open transfer records it with `drop_transfer`
  (so it counts as abandoned): stop, the oversized line, the watchdog. On the
  oversized line the chunk callback also returns true, so Director aborts
  that transfer.
- After a transfer that ended in an overflow, the next 200 does not reset the
  backoff to 1 s; the doubled backoff stays until a transfer delivers an
  event normally.
- `handle_chunk` and `deliver_abandoned` call each `deliver` under `pcall`; a
  raise is logged (warn, once per chunk) and the next event is delivered.
  `handle_event` skips a container that is not a table.
- `stream:open_abandoned()` and `stream.MAX_ABANDONED` keep their names; the
  driver reads them.

### bridge/tlscheck.lua (tls-docs)

Unchanged: `tlscheck.run(ip, callback(verdict, detail))`. New:

- `tlscheck.director_version()`: `C4:GetVersionInfo().version` as a string,
  under `pcall`; nil when unavailable.
- `tlscheck.remember_pinned()`: persists the current Director version as the
  one on which `pinned` was seen (`C4:PersistSetValue`, store name
  `tlscheck.STORE_NAME = "tls_pinned_on"`, not encrypted: it is no secret).
  Does nothing when the version is unknown.
- `tlscheck.pinned_before()`: true only when the persisted version equals
  `tlscheck.director_version()` and both are non-empty.

Rationale (finding 3): pinning is a property of the OS, not of the network.
An `inconclusive` answer is accepted only on a Director version that has
already answered `pinned`; on a new or upgraded OS it blocks until a
conclusive answer.

### bridge/util.lua (names)

- `util.display_name(text)`: a name fit for a Composer device name or a plain
  property row. `nil` or a non-string becomes `""` (numbers via `tostring`);
  control characters (`%c`) are removed; leading and trailing white space
  trimmed; at most `util.NAME_MAX = 100` UTF-8 characters (counted by their
  lead bytes: every byte outside 0x80-0xBF), cut before a character, never
  inside one. Text that is not UTF-8 is also bounded by `util.NAME_MAX_BYTES
  = 400` bytes (100 UTF-8 characters never exceed it), cut by backing over
  at most three continuation bytes. Why characters: no genuine Hue name comes
  near 100 (Hue allows 32; the longest name the bridge builds, a zone scene's
  "<Zone> <Scene>", has 65), so no real name is cut, and a hostile one is
  still bounded. Idempotent, and linear in the length (the trailing trim
  counts blanks from the end: the pattern `%s+$` is quadratic in an inner run
  of blanks). Commas are kept (they matter only in picker lists, which keep
  `util.sanitise`). `util.name_key(text)` is `util.norm` of it, for the name
  matches. The same function covers the light's Model row.

### Dev builds (dev-surface)

- Development handlers (`Hue_Request`, `Probe_Project`, `Probe_Errors`,
  `Probe_Scenes`, `Probe_Call`, `Proxy_Command`, `Lights_Report`, `HUE_LOG`,
  and whatever else is not a Composer action of the DEV-ONLY XML block) leave
  `dispatch.commands`. They live in a table the dev loop consults for signed
  `execute` commands before it falls back to the global `ExecuteCommand`
  (`devloop.set_signed_commands(table)` or an equivalent the agent defines and
  documents in `docs/dev-loop.md`). `dispatch.commands` keeps only the actions
  Composer can send: those named in the DEV-ONLY block of
  `src/hue_bridge/driver.xml`, which the coordinator owns and does not change
  unless the agent asks.
- `Probe Call` refuses `PersistGetValue`, `PersistSetValue` and
  `PersistDeleteValue` (any `Persist*`) whose first argument names one of the
  credential store's names (read them from `bridge/credentials.lua`, do not
  copy the strings into a log or a doc).
- The dev loop redacts the application key from every captured log line,
  through a hook the bridge installs (`devloop.set_redactor(fn)`, where
  `fn(line)` returns the line to keep). The bridge's redactor replaces the
  current key with `<key>`.
- `Hue Request` accepts a Path only when it starts with `/` and holds none of
  `@`, `\`, `#` or white space. `Connection Test` with the bridge target, and
  the dev `Test Connection` with a Host, wait for the identity check like
  `Hue Request` does. The dev `Test Connection` hands over to the driver's
  `ctx.test_connection(host)`, which the coordinator gates (§3).

## 3. Driver decisions (coordinator)

- **One refusal for every keyed send** (findings 1, 2, 4). A local
  `keyed_refusal()` answers, in this order: `not paired`, `TLS check failed`
  while `state.tls_verdict == "not_pinned"`, `key rejected` while
  `state.key_rejected`. `bridge_request`, `choose_stream_address`,
  `restart_stream` and `Connect Event Stream` refuse on any of them.
  `test_connection` refuses on the first two only: it is the one way to show
  the key works again (below).
- **Test Connection waits for the identity check** (finding 1). While
  `state.identity_ok ~= true` it runs `verify_identity` first and sends the
  keyed GET only from its success callback, so a different bridge id comes
  from the unkeyed `/api/0/config`. `verify_identity` keeps a set of waiters
  keyed by purpose (`stream`, `test`), so a test does not drop the stream's
  pending start and two stream starts never queue twice. An address change or
  Forget Pairing drops every waiter.
- **`not_pinned` sticks** (finding 2) until the next start or address change:
  `tls_gate` answers `false` at once while the verdict is `not_pinned`.
- **`inconclusive` blocks on an unproven OS** (finding 3). In `tls_gate`, a
  `pinned` verdict calls `tlscheck.remember_pinned()`. An `inconclusive` one
  passes only when `tlscheck.pinned_before()`; otherwise nothing is sent,
  Status reads `TLS check inconclusive (<detail>): nothing is sent; checking
  again in 30 s`, and the identity check runs again in 30 s.
- **A REST 401/403 is confirmed before the lock** (finding 4). On a 401/403
  answer to a keyed module request, `bridge_request` answers that request
  with `HTTP <code>` and sends one keyed `GET /clip/v2/resource/bridge` (one
  at a time, however many 403s arrive). Only a 401/403 to that GET locks.
  The stream's 401/403, the stream address self-check and Test Connection
  lock at once (they ask the bridge resource or the key-only endpoint).
- **Test Connection clears the lock** (finding 4). A 200 with the paired
  bridge id while `state.key_rejected` is set clears it, logs it, refreshes
  Status and starts the stream again.
- **Fan-out** (finding 6): `on_container` returns at once for a non-table.
- **Names** (finding 8): `Bridge Name` shows `util.display_name(name)`.
- **Release stage assertion**: `tools/build.sh` also refuses `conntest.lua`
  and `pinning.lua` in a release stage.

## 4. Workflows (workflows)

- The packager is pinned to a reviewed commit in `ci.yml` and `release.yml`
  (`git init`, `git fetch --depth 1 origin <sha>`, `git checkout FETCH_HEAD`);
  the commit is the head the agent reads today, written once, with a comment
  saying how to move it.
- luarocks installs name exact versions in both workflows.
- The release job splits in two: a build job (`contents: read`, no
  `id-token`, no `GH_TOKEN`) that lints, tests, builds and uploads the
  packages as a workflow artifact; a publish job (`contents: write`,
  `id-token: write`, `attestations: write`) that downloads them, attests and
  publishes, and runs only first-party actions and `gh`. `GH_TOKEN` is set
  only on the steps that call `gh` or push the tag.
- `deploy.py start` verifies each package with `gh attestation verify <file>
  --repo corytron/c4-hue-driver --signer-workflow
  corytron/c4-hue-driver/.github/workflows/release.yml` and refuses on
  failure; `--no-attestation` stays for releases cut before attestations.
  `SECURITY.md` prints the same command.
- Dependabot: `cooldown` of 7 days for the GitHub Actions ecosystem where
  Dependabot supports it (verify against GitHub's documentation and say
  which), else the actions `release.yml` uses stay out of auto-merge.
- `tools/check.sh secrets` scans every local ref (`--log-opts=--all`) when run
  locally; CI keeps scanning HEAD.
- `docs/release-checklist.md`: the TLS line says what the check proves
  (the configured bundle is consulted, and the bridge's chain is not trusted
  without it), and after an OS upgrade one dev-build `Check CA Pinning` run
  stays on the list (finding 3).

## 5. Out of scope

- Hostname verification, per-connection identity, inter-driver trust
  (accepted residual risks, review §"Residual risks").
- Anything on the house: no controller or bridge contact by any agent.
- Code scanning alerts: another agent works on them from `main` and owns
  `tools/collect.py`, `tools/setup-checks.sh` and the triage workflow.

## 6. Done means

`luacheck src tests tools` clean, `busted tests` all passing, `ruff check
tools` and `ruff format --check tools` clean, `python3 -m unittest discover -s
tools/tests` passing, `tools/build.sh` builds the three packages, and every
finding above has a spec or test that fails without its fix.
