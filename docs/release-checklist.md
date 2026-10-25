# Release checklist: what a build must pass before it is called good

Written 2026-10-24 for the first release build, after the slimming pass;
updated 2026-10-25 for the CI/CD and GitOps setup (`docs/cicd-gitops-design.md`:
one check script, releases cut by the Release workflow, the house deployed
through `tools/deploy.py`). The owner's rule: after any code change that is
more than a text, test for functional regressions on the dev loop **and** on
the real system before the code is called good. Three passes, in this order;
every line is a check with its expected result, and the result goes into
`docs/status.md`.

## 0. On this VM

- `tools/check.sh --strict --only lua-lint lua-test shell python-lint
  python-test xml workflows secrets house` passes (every check but
  `powershell`, which needs `pwsh`; CI runs that one): `luacheck src tests
  tools` clean, `busted tests` green (the count is in `docs/status.md`), the
  shell and Python tooling clean, every `driver.xml` well-formed, the
  workflows clean under actionlint and zizmor, gitleaks clean over the tree
  and the history, `deploy/house.yaml` valid. `tools/setup-checks.sh` first
  if a tool is missing.
- `tools/build.sh` (release) and `tools/build.sh --dev`: the release
  `hue_bridge.c4z` has 22 actions and no `Dev Server`, `Diagnostic Server`,
  `Connection Test`, `Reload Credentials`, `Check CA Pinning`; no
  `common/devloop.lua`, `bridge/conntest.lua`, `bridge/pinning.lua`. The dev
  build has all of them. `build/manifest.json` names the build and the
  three packages' checksums.
- `unzip -l build/<driver>.c4z` lists `LICENSE` and `NOTICE` in each of the
  three packages (Apache 2.0 §4).
- No LAN address, Hue application key or private certificate in `src/`,
  `docs/`, `tools/`, `tests/`: the `secrets` check (gitleaks with
  `.gitleaks.toml`) covers the tree and the history; the placeholders
  10.0.2.143, 192.0.2.7 and 001788fffe123abc (001788fffe25b8f8 in the test
  fixtures) are the only ones allowed.

## 1. Dev loop on the house (dev build of the bridge)

Install the three `--dev` files through the Windows session (Deploy in
`CLAUDE.md`); set `Dev Server` to this VM's `host:8080`; `tools/devserver.py`
running, `tools/devctl.py status` shows the bridge polling. Then, through
`tools/devctl.py run`, with the shipped log (`build/dev/driver.log`) as the
evidence (`docs/dev-loop.md`):

1. Startup: the log shows the resync (lights, scenes, smart scenes,
   grouped_light GETs), the stream connecting on its padded spelling, and
   `Lights`, `Scenes`, `Zone Lights`, `Room Mappings` summaries matching the
   house (47 lights; 126 + 15 scenes; 7 zones, 16 rooms; 23 mappings).
2. `Test Connection` → `Status` "Test OK: HTTP 200 via … bridge …".
3. `Refresh Scenes` → `Last Action` "Scenes refreshed: 126 + 15 time-based on
   bridge, 2 imported, 2 deleted" (counts as on the house).
4. `Room Audit`, `Link Devices`, `Adopt Hue Names`, `Accept Names As They
   Are` → their texts, nothing changed (no new devices, no renames unless a
   name differs).
5. Zone light round trip on the Bedside Lights zone light (device 1166):
   `Proxy_Command` / the owner's tile: ON → one PUT `{"on":{"on":true},
   "dimming":{"brightness":100}}` on grouped_light 75952a96…; a level → one
   absolute PUT; OFF → `{"on":{"on":false}}`; the Hue app's change → one
   `HUE_STATE` to device 1166 within 2 s; at most one grouped_light PUT a
   second during a drag.
6. Scene round trip on Shine (1162): ON → one scene recall PUT; OFF → one
   grouped_light off; the keypad hold (owner) → `dimming_delta` up/down and
   `stop`.
7. Time-of-day scene: Golden hours (1164) ON → `smart_scene` activate; OFF →
   deactivate and the room off.
8. Light lifecycle: `Add Light` of one light (Left Bedside Light) into the
   Master Bedroom → a device with Status "Hue light …" and Driver Version
   at once; `Forget Light` + delete in Composer → tombstone, `Add Light`
   lists it "(deleted from Composer …)".
9. Events: a Hue-app change of a lamp → one `HUE_STATE` only to the devices
   that show it; `Events Received` rises; no error line in the log.
10. Thirty minutes idle: no reconnect storms, no timer errors, memory steady
    (the dev loop's `status` shows the driver's Lua memory if available).

## 2. Release build on the house (Windows session, Composer)

Install the three release files from the GitHub release through
`tools/deploy.py start` and the brief it writes ("Deploy to the house"
below); no "Restart Director?" unless a capability changed (then the owner
reboots the controller). Read:

1. `Driver Version` on the bridge, Shine, Golden hours, Bedside Lights and
   Master Bedroom Lights = the build; `Debug Mode` reads Off on every device
   (a development build leaves it On, and Director keeps the value through
   the release install).
2. The bridge's Properties page: no `Dev Server` / `Diagnostic Server` rows;
   `Lights`, `Scenes`, `Zone Lights`, `Room Mappings`, `Last Action` are
   drop-downs whose lists hold every item (47 lights; 141 scenes; 23 groups;
   23 mappings); a pick snaps back and leaves the Last Action note.
3. The Actions tab: 22 actions, none of the three diagnostics.
4. `Add Zone Light` for a throwaway zone, Driver Version at once, `Forget
   Light`, delete: as in round 25 (`docs/composer-remote.md`).
5. The Documentation tab opens and shows the manual's title and the
   chapter list (and the three device pages).
6. The Lua tab of a device during the install: no `[ERROR]` line.

## 3. The owner, on the phone and keypads

1. Bedside Lights tile: ON, slider, colour, colour temperature, OFF reach
   both lamps; the Hue app's change reaches the tile.
2. Shine's tile: ON plays, slider dims the room, OFF turns the room off;
   LEDs on the Bedside Lights Switch follow.
3. Golden hours tile: ON starts the schedule (Status "now <slot>"), OFF
   stops it and turns the room off.
4. Keypad taps and holds on whichever device the switch is bound to.

A build passes when every line reads as expected; anything else goes to
`docs/status.md` "Open" with the build number, and the release waits.

## Naming

The release of this spike is **1.0 "Cassian"** (owner, 2026-10-24): git tag
`v1.0`, a GitHub release titled `1.0 "Cassian"` with the three release `.c4z`
files attached. Major versions are codenamed after Star Wars: Andor and every
1.x release keeps "Cassian"; before a new major version the coordinator
proposes a widely recognised character, place or object from the show and
the owner approves it (used so far: Cassian). The driver files carry the
build number, the commit count, as `Driver Version` (Control4 needs an
integer there); it is named in the release notes and in the release's
`manifest.json`, and nowhere else: since 2026-10-25 the README and
`docs/status.md` link to the Releases and Environments pages instead of
stamping a build number. Later releases of the same spike move the tag and
replace the attached files; a new version number comes when development
here is finished.

**How a release is cut** (`.github/workflows/release.yml`; contract
`docs/cicd-gitops-design.md` §5):

1. Merge the code into `main`. Nothing is edited for the release itself.
2. Start the Release workflow: on the repository's Actions page, **Release ▸
   Run workflow**, enter the version (`1.0`, `1.1`, ...). The workflow tags
   `main`'s head as `v<version>` itself, force-moving an existing tag, and
   builds in the same run. Pushing the tag by hand (`git tag -f -a vX.Y -m
   "X.Y" <commit on main>`, `git push --force origin vX.Y`) starts the same
   build; a tag that is not on `main` is refused.
3. The workflow lints, tests and builds, then attaches to the release of the
   tag, creating it when missing with the title `<version>` and generated
   notes whose first paragraph names the build number and the install rule:
   `hue_bridge.c4z`, `hue_light.c4z`, `hue_scene.c4z`, `SHA256SUMS.txt`,
   `manifest.json` (contract §5.2: tag, version, build, commit, build time,
   each package's sha256 and size) and `attestations.sigstore.json`, the
   signed build provenance. A run for a moved tag replaces every file.
4. Once per major version the coordinator edits the codename into the
   release title (`1.0 "Cassian"`); the workflow never changes an existing
   title. Check the release page: six assets, the build number in the notes.
5. Nothing is built on the VM for an install: the house gets these same
   files, downloaded from the release by `tools/deploy.py start` (next
   section).

## Deploy to the house

The house installation is run from the repository (contract
`docs/cicd-gitops-design.md` §6 and §7): `deploy/house.yaml` is the desired
state, a GitHub Deployment on the environment `house` is the observed state,
and the Composer click stays with the Windows session and is never
automatic, since the controller has no install API. After the release exists:

1. **Say what the house should run.** A pull request edits
   `deploy/house.yaml`: `build:` to the release's build number (from its
   notes or `manifest.json`) and `release:` when the version changed. CI's
   `house` check validates the file; merge the pull request.
2. **The drift issue appears.** On the merge the drift workflow
   (`.github/workflows/drift.yml`) compares the file with the newest
   successful deployment and opens one issue labelled `deploy`, `Deploy
   vX.Y (build N) to the house`, or updates the one already open; it never
   opens a second. Add it to the project board by hand (`gh project
   item-add 1 --owner corytron --url <issue url>`); the workflow's token
   cannot.
3. **Prepare and record the intent.** On the VM, `python3 tools/deploy.py
   start`, with `--note "changes <capabilities>: the owner reboots the
   controller from System Manager after the install"` when the build changes
   a `driver.xml` `<capabilities>` block, and `--supersede` when an earlier
   deployment is still in progress. It downloads `manifest.json`,
   `SHA256SUMS.txt` and the three packages from the release into
   `build/release/<tag>/`, verifies every sha256 against both files, that
   the manifest's build is the file's and its commit the tag's, and that
   GitHub holds a provenance attestation for each package (presence and
   subject only; the VM's `gh` is too old to verify the signature, and the
   brief says so), creates the Deployment with status `in_progress`, and
   writes `build/release/<tag>/BRIEF.md` and `deployment.json`. A build the
   release does not carry is refused.
4. **Send the brief.** `BRIEF.md` goes to the Windows Composer session as it
   is (`docs/composer-remote.md`): the three GitHub download URLs, each
   file's sha256, the PowerShell that fetches them into
   `C:\c4-hue\drivers\<tag>\` and checks them with `Get-FileHash`, the
   Composer steps (Driver ▸ Add or Update Driver or Agent…, all three at
   once, in place, never delete and re-add the bridge), what to read back,
   the note, and the standing-approval sentence. It carries no LAN address
   and no bridge id.
5. **What the Windows session reads back.** Every device's `Driver Version`
   equals the build; on the bridge, `Stream Timeout (s)`, `Stream Watchdog
   (s)` and `Debug Mode` match `deploy/house.yaml`; no `[ERROR]` line in a
   device's Lua tab during the install; and whether Composer asked "Restart
   Director?". If it did, the build changed capabilities: answering Yes
   loads nothing, the owner **reboots the controller from System Manager**
   (it runs elevated; the Windows session cannot operate it), and the
   session reads `Driver Version` again afterwards.
6. **Record the result.** `python3 tools/deploy.py done --devices <count>`
   (with `--note` for anything worth keeping) sets the deployment to
   `success` and closes the deploy issue with a comment naming the
   deployment; `python3 tools/deploy.py failed --note "<what the session
   saw; which build the house still runs>"` sets it to `failure` and leaves
   the issue open.
7. **Check.** `python3 tools/deploy.py status` exits 0 when desired and
   observed agree (3 on drift), and the `house` environment on the
   [Environments page](https://github.com/corytron/c4-hue-driver/deployments/house)
   lists every install, newest first. `docs/status.md` and the README point
   there rather than naming the build.

An install made any other way is recorded after the fact with `python3
tools/deploy.py record --tag vX.Y --build N --at <time> --note "..."`, so
that the observed state stays true.
