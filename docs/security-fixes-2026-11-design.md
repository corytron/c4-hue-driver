# Security fixes from the review of 2026-11-13 (#481 to #493)

The contract for fixing the findings of
`docs/reviews/security-2026-11-13.md` (#480; on branch
`security/review-480` until PR #495 merges: `git show
origin/security/review-480:docs/reviews/security-2026-11-13.md`, and the
same for the `-network`, `-controller` and `-devices` reports).
It is the second fix round, after [`security-fixes-design.md`](security-fixes-design.md)
(#217). The finding ids (N-, C-, D-, I-) are the review's. Each reviewer's
report gives the file, function, line and suggested fix for its findings;
read your findings there first. The install report
(`docs/reviews/security-2026-11-13-install.md`) is on branch
`security/review-480`: read it with `git show
origin/security/review-480:docs/reviews/security-2026-11-13-install.md`.

Branch `security/fixes-481-493`. Five agents edit disjoint files at the
same time. The coordinator integrates, runs `tools/check.sh` and
`tools/build.sh`, and commits.

## 1. Shared pieces (already written by the coordinator)

- `src/common/num.lua` is in every package, because `build.sh` copies all
  of `common/`. It provides:
  - `num.finite(v)`: a finite number, or nil;
  - `num.within(v, lo, hi, default)`: refuses out of range;
  - `num.clamp(v, lo, hi, default)`;
  - `num.int(v, lo, hi, default)`;
  - `num.timestamp(ts)`;
  - `num.date(fmt, ts, fallback)`: a safe `os.date`.

  Spec: `tests/spec/num_spec.lua`. Use it for every number and timestamp
  that comes from outside the driver: proxy commands, bridge messages, Hue
  reports, persisted values. Do not edit it. Ask the coordinator if you
  need more.
- `hue_model.resource_id(v)` (bridge) is the one rid check: letters, digits
  and `-`.

## 2. Decisions

| Issue | Findings | Decision |
|---|---|---|
| #481 | I-1, I-10 | **Install server.** Feature-branch and dev installs are served by `tools/serve_install.py`. It copies only the named packages into a fresh temporary folder with a random path segment, serves that folder on 8090 until it is stopped, then deletes it, and prints the URLs and hashes for the brief. `build/release/` is never served whole again. **Dev server.** `devserver.py` takes a random admin token per run (printed once to its owner, written mode 0600 for `devctl.py`) instead of one derived from the dev key, caps request bodies at 1 MB, and strips control characters from what it logs. `docs/dev-loop.md` and the CLAUDE.md deploy paragraph (coordinator) follow. |
| #482 | I-2, I-9 | **Provenance.** `deploy.py start` verifies every asset with `gh attestation verify … --signer-workflow corytron/c4-hue-driver/.github/workflows/release.yml --source-ref refs/heads/main --source-digest <the tag's commit>` (use the flags `gh` 2.103 has; check `gh attestation verify --help`). It checks that the tag's commit is an ancestor of `origin/main`, and refuses a manifest whose `tag` does not equal the release's tag, or whose `dev` is missing or true. `--no-attestation` is removed. |
| #483 | C-1, D-1, D-7 | **Trust between drivers.** Control4 gives a driver no sender identity for `ExecuteCommand` or `SendToDevice`, so the bridge's actions keep accepting any driver in the project. That is the documented trust boundary (SECURITY.md, manual). Devices narrow what a spoofer can do: (1) once a device has a rid, a bridge message naming another rid, or none, is ignored (debug log), except `HUE_CONFIGURE` (or its kind's configure) within 30 s of the device's own hello; (2) proxy commands are taken only on the proxy binding, and Button Link commands only on bindings 200 to 202. |
| #484 | C-2 | The four development handlers (Connection Test, Reload Credentials, Check CA Pinning, Probe Picker Folders) move into the signed dev table, so a dev build answers them only from a signed command list. Forwarded `HUE_LOG` lines and kept log lines are capped at 2,000 bytes each. |
| #485 | D-2 | Every rid that arrives from a device (a hello, HUE_SET, HUE_DIM and the other device-to-bridge messages) passes `hue_model.resource_id`, or is refused with a debug log. HUE_SET and HUE_DIM act only for linked entries. |
| #486 | C-3, D-4, D-5 | Every proxy and bridge number goes through `common/num.lua`. Levels 0 to 100. Rates 0 to `device.RATE_MAX`. xy 0 to 1. Mirek within the light's own limits, else 153 to 500. Button ids 0 to 2. Lux 0 to 100,000 and temperature −40 to 60 °C, else the reading is dropped, so no NaN baseline can be kept. A value that fails a check is dropped, never sent. |
| #487 | D-6, bridge `gone_since` | Every `os.date` with a timestamp from outside goes through `num.date`. A persisted timestamp that fails `num.timestamp` is cleared at load. |
| #488 | D-3, `parse_groups` | A device learns at most 32 load groups, and only ids that name a real device (`C4:GetDeviceDisplayName` or the project lookup the code already uses). `parse_groups` keeps at most 256 groups and logs the rest as dropped. |
| #489 | N-1, N-2, N-4 (trim), N-7, N-8, C-4 | **SSE.** Count every byte of every line, empty `data:` lines included, against the event's 1 MB cap; drop the event and resync when it is exceeded. **HTTP head.** A linear trim and line reader; a head over 16 KB closes the connection. **Labels.** The Bridges Found trim is linear. **Peer and caller text.** Capped at 256 bytes in rows, Status and Attention, and 2,000 in log lines. Last Action echoes a picked value sanitised and capped, never with `%q`. **Backoff.** It resets only after a resync succeeds, not on a bare 200. **Transfers.** At most 3 keyed `C4:url` transfers in flight; the rest wait in the queue. |
| #490 | N-3, N-4, N-6, N-9 | **mDNS.** An answer counts only if it matches the query id. Its address must be private IPv4 (10/8, 172.16/12, 192.168/16) or link-local (169.254/16). The paired bridge's id is taken first; the 32-per-window cap stays for others. **Identity.** `identity:verify` compares the bridge id before writing Bridge Model, Bridge Firmware or any other row. **401/403.** The bridge's identity is re-checked before the key is locked. **Pairing.** The window is checked before a new key is stored, and a key that arrives after Forget Pairing or after the window closed is discarded. |
| #491 | N-5 | **Owner decision (2026-11-13):** keep the automatic address follow-up and document the risk in SECURITY.md and the manual's troubleshooting. There is no code change. |
| #492 | I-3 to I-8 | **I-3.** `release.yml` runs the luarocks lint and test tools in a separate job; the packaging job installs none of them and builds from a clean checkout. **I-4.** A dev build's Driver Version reads `<build>-dev`. `deploy.py record --no-manifest` records the build as a dev build and never copies a release's hashes, so drift reports "off the release". **I-5.** Release builds call `C4:AllowExecute(false)` in `OnDriverInit`, belt and braces: the SDK says it defaults to false (FUND `6_Understanding .c4z Drivers/_3-C4ALLOWEXECUTE.md`). **I-6.** A release build logs a warning at init if a dev module is loaded. **I-7.** A new check, `doc-tabs` in `tools/check.sh` and CI's tooling job: no `<script>`, `<iframe>`, `<object>`, `<embed>` or `on…=` attributes, and no `src` or stylesheet that is not a relative path, in `src/*/www/*.html`. **I-8.** `build.sh` stages only the files git tracks under `src/`. |
| #493 | C-5, D-8 | **Debug Mode turns itself Off after 8 hours**, on every driver, with a Last Action that says so; a restart keeps the remaining time. Light and scene `SendToDevice` calls pass the same don't-log flag the motion driver passes. |

## 3. Writers (one per file)

| Agent | Files | Issues |
|---|---|---|
| **FN** (network) | `src/hue_bridge/bridge/sse.lua`, `netstream.lua`, `stream.lua`, `http.lua`, `discovery.lua`, `mdns.lua`, `bridges_found.lua`, `identity.lua`, `pairing.lua`, `pair_window.lua`, `credentials.lua`, and their specs | #489 (all but C-4), #490 |
| **FB** (bridge) | `src/hue_bridge/driver.lua`, `src/hue_bridge/bridge/commands.lua`, `devtools.lua`, `actions.lua`, `util.lua`, `lights.lua`, `registry.lua`, `owner.lua`, `groups.lua`, `hue_model.lua`, `away.lua`, `link.lua`, `scenes.lua`, `zone_lights.lua`, `motion.lua`, `motion_diag.lua`, `load_groups.lua`, and their specs | #484, #485, #486 (C-3), #487 (bridge), #488 (`parse_groups`), #489 (C-4), #492 (I-5 and I-6, bridge), #493 (bridge) |
| **FD** (devices) | `src/hue_light/**`, `src/hue_scene/**` (Lua and XML), `src/hue_motion/**`, `src/common/device.lua`, `link.lua`, `dispatch.lua`, `log.lua`, `devloop.lua`, and their specs | #483 (D-1, D-7), #486 (D-4, D-5), #487 (D-6), #488 (D-3), #492 (I-4 Driver Version, I-5 and I-6, devices), #493 (devices) |
| **FI** (install) | `tools/deploy.py`, `tools/devserver.py`, `tools/devctl.py`, `tools/build.sh`, `tools/check.sh`, new `tools/serve_install.py` and `tools/check_doc_tabs.py`, `.github/workflows/release.yml`, `.github/workflows/ci.yml`, `tests/*.py`, `docs/dev-loop.md`, `docs/release-checklist.md`, `docs/cicd-gitops-design.md` | #481, #482, #492 (I-3, I-4 tooling, I-7, I-8) |
| **FDoc** (docs) | `SECURITY.md`, `src/*/www/documentation.html`, `CHANGELOG.md`, `docs/composer-remote.md` | #483 (the trust boundary), #491, #493 (Debug Mode text), the changelog lines |
| Coordinator | this file, `src/common/num.lua`, `CLAUDE.md`, `docs/README.md`, `docs/status.md`, integration | — |

## 4. Done

- Each issue's fix has a spec that fails before the fix and passes after
  it, where the finding can be reproduced on the fake runtime or in Lua.
- `tools/check.sh` passes, `tools/build.sh` builds, and
  `python3 tools/lua_limits.py` passes.
- No `<capabilities>` change, so the install needs no controller reboot.
  If one turns out to be needed, the agent says so.
- The PR closes #481 to #493. The Debug Mode auto-off and the dev Driver
  Version suffix are owner-visible, so they go in `CHANGELOG.md`.
