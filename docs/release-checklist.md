# Release checklist: what a build must pass before it is called good

Written 2026-10-24 for the first release build, after the slimming pass;
updated 2026-10-25 for the CI/CD and GitOps setup (`docs/cicd-gitops-design.md`:
one check script, releases cut by the Release workflow, the house deployed
through `tools/deploy.py`) and checked against build 316 and today's tools
(issue #231). The owner's rule: after any code change that is more than a
text, test for functional regressions on the dev loop **and** on the real
system before the code is called good. Three passes, in this order (and
section 4 once after each controller OS upgrade); every line is a check
with its expected result. Results go into the build's issue (hardware
findings as comments), and `docs/status.md` sums them up.

## 0. On this VM

- `tools/check.sh --strict --only lua-lint lua-test shell python-lint
  python-test xml workflows secrets house` passes (every check but
  `powershell`, which needs `pwsh`; CI runs that one): `luacheck src tests
  tools` clean, `busted tests` green, the shell and Python tooling clean,
  every `driver.xml` well-formed, the
  workflows clean under actionlint and zizmor, gitleaks clean over the tree
  and the history of every local ref (branches, tags, stashes,
  remote-tracking refs: on the VM the check reads `git log --all`, so a
  stale ref holding old history fails it until it is removed),
  `deploy/house.yaml` valid. `tools/setup-checks.sh` first if a tool is
  missing.
- `tools/build.sh` (release) and `tools/build.sh --dev`: the release
  `hue_bridge.c4z` has 22 actions (`unzip -p build/hue_bridge.c4z
  driver.xml | grep -c '<action>'`) and no `Dev Server`, `Diagnostic
  Server`, `Connection Test`, `Reload Credentials`, `Check CA Pinning`; no
  package holds `common/devloop.lua` or `common/devkey.lua`, and the bridge
  no `bridge/devtools.lua`, `bridge/conntest.lua`, `bridge/pinning.lua`
  (`tools/build.sh` refuses to package a release stage that still has one).
  The dev build has all of them (25 actions; each package carries the dev
  key as `common/devkey.lua` and is written 0600). `build/manifest.json`
  names the build, the commit, `"dev": false` or `true`, and the three
  packages' checksums and sizes.
- `unzip -l build/<driver>.c4z` lists `LICENSE` and `NOTICE` in each of the
  three packages (Apache 2.0 §4).
- No LAN address, Hue application key or private certificate in `src/`,
  `docs/`, `tools/`, `tests/`: the `secrets` check (gitleaks with
  `.gitleaks.toml`) covers the tree and the history; the placeholders
  10.0.2.143, 192.0.2.7 and 001788fffe123abc (001788fffe25b8f8 in the test
  fixtures) are the only ones allowed.

## 1. Dev loop on the house (dev build of the bridge)

Build the three `--dev` files with `tools/build.sh --dev` from the commit
under test and install them through the Windows session the way `CLAUDE.md`
(Deploy) describes for a dev build: served from `build/release/` on port
8090, briefed with their sha256, recorded afterwards with `python3
tools/deploy.py record ... --no-manifest` (`docs/dev-loop.md`, "Current
state"). `tools/devserver.py` running, the bridge's `Dev Server` set to the
`host:port` it prints, `tools/devctl.py status` shows the bridge polling.
Then, through `tools/devctl.py run`, with the shipped log
(`build/dev/driver.log`) as the evidence (`docs/dev-loop.md`); steps 2 to
4 and the log scan of step 9 are scripted as `tools/regress.sh`:

1. Startup: the log shows the resync (`event stream connected; resyncing
   <n> lights`, then `resync done`, `scene resync done` and `zone light
   resync done`; with the bridge's `Debug Mode` On also each GET: light,
   device, zigbee_connectivity, room, zone and bridge_home, then scene,
   smart_scene and one grouped_light), the stream on its padded spelling
   (`stream will use <spelling>, rotating over <k> spelling(s); self-check
   via <spelling> OK`), and `Lights`, `Scenes`, `Zone Lights`, `Room
   Mappings` summaries matching the house (47 lights; 126 + 15 scenes; 7
   zones, 16 rooms; 23 mappings).
2. `Test Connection` → `Status` "Test OK: HTTP 200 via … bridge …".
3. `Refresh Scenes` → `Last Action` "Scenes refreshed: 126 + 15 time-based on
   bridge, 2 imported, 2 deleted" (counts as on the house).
4. `Room Audit`, `Link Devices`, `Adopt Hue Names`, `Accept Names As They
   Are` → their texts, nothing changed (no new devices, no renames unless a
   name differs).
5. Zone light round trip on the Bedside Lights zone light (device 1166):
   `tools/devctl.py run "Proxy Command" Light=1166 Command=ON` (and the
   other light_v2 commands the same way) or the owner's tile: ON → one PUT
   `{"on":{"on":true}, "dimming":{"brightness":100}}` on the zone's
   grouped_light; a level → one absolute PUT; OFF → `{"on":{"on":false}}`;
   the Hue app's change → one `HUE_STATE` to device 1166 within 2 s; during
   a drag a burst of three grouped_light PUTs, then at most one a second.
6. Scene round trip on Shine (1162): ON → one scene recall PUT; OFF → one
   grouped_light off; the keypad hold (owner) → `dimming_delta` up/down and
   `stop`.
7. Time-of-day scene: Golden hours (1164) ON → `smart_scene` activate; OFF →
   deactivate and the room off.
8. Light lifecycle: `Add Light` of one light (Left Bedside Light) into the
   Master Bedroom → `Last Action` "Added Left Bedside Light #<n> to Master
   Bedroom (device <id>)", a device with `Status` "Left Bedside Light
   (<model>)" and `Driver Version` at once; a Composer delete of that
   device → `Lights` "…, <d> deleted" with `<d>` one higher, and `Add
   Light` lists it "Left Bedside Light [<Hue room>] #<n> (deleted from
   Composer <date>)".
   (`Forget Light` before a delete leaves no tombstone: the device is
   unbound, so its delete reaches no bridge, and the light is listed under
   Add Light again without the mark.)
9. Events: a Hue-app change of a lamp → one `HUE_STATE` only to the devices
   that show it; `Events Received` rises; no error line in the log.
10. Thirty minutes idle: no reconnect storms (the `Event Stream` row counts
    the reconnects since start), no timer errors. Memory is not measured:
    nothing in the drivers or the dev loop reports the Lua memory.

## 2. Release build on the house (Windows session, Composer)

Install the three release files from the GitHub release through
`tools/deploy.py start` and the brief it writes ("Deploy to the house"
below); no "Restart Director?" unless a capability changed (then the owner
reboots the controller). Read:

1. `Driver Version` on the bridge, Shine, Golden hours, Bedside Lights and
   Master Bedroom Lights = the build; `Debug Mode` reads Off on every device
   (a dev-loop session often leaves it On, and Director keeps the value
   through the release install).
2. The bridge's Properties page: no `Dev Server` / `Diagnostic Server` rows;
   `Lights`, `Scenes`, `Zone Lights` and `Room Mappings` are drop-downs: the
   row shows the summary and the list one line per item (47 lights; 141
   scenes; 23 zones and rooms; 23 mappings), and a pick snaps back to the
   summary and changes nothing. `Last Action` is a read-only text that
   continues on `Last Action (2)` to `(6)`, rows shown only while they hold
   text.
3. The Actions tab: 22 actions, none of the three diagnostics.
4. `Add Zone Light` for a throwaway zone, Driver Version at once, `Forget
   Light`, delete: as in round 25 (`docs/composer-remote.md`).
5. The Documentation tab opens and shows the manual's title and the
   chapter list (and the three device pages).
6. The Lua tab of a device during the install: no `[ERROR]` line.
7. The bridge's `Attention` does not read `TLS check failed: …` and
   `Status` reads `Paired`. What the TLS self-check proves (#53; the
   manual's chapter 12, "The TLS check"; `docs/design.md`, "TLS self-check
   in release builds"): the configured bundle is consulted, and the
   bridge's chain is not trusted without it. It cannot tell a controller
   that replaces its system store with the bundle from one that adds the
   bundle to it, so after a controller OS upgrade this line is not the
   pinning check: section 4 is. Nor does it prove anything against someone
   on the LAN who drops the decoy request: such an answer is inconclusive,
   and the driver accepts an inconclusive answer only on a Director version
   that has answered `pinned` before (`bridge/tlscheck.lua`); otherwise
   `Status` reads `TLS check inconclusive (<detail>): nothing is sent;
   checking again in 30 s` and nothing keyed is sent.

## 3. The owner, on the phone and keypads

1. Bedside Lights tile: ON, slider, colour, colour temperature, OFF reach
   both lamps; the Hue app's change reaches the tile.
2. Shine's tile: ON plays, slider dims the room, OFF turns the room off;
   LEDs on the Bedside Lights Switch follow.
3. Golden hours tile: ON starts the schedule (Status "now <slot>"), OFF
   stops it and turns the room off.
4. Keypad taps and holds on whichever device the switch is bound to.

## 4. After a controller OS upgrade

Once per new controller OS version, before a build is called good on it:

1. Install the three `--dev` files as in section 1 and run the bridge's
   `Check CA Pinning` action once (`Status` reads `Checking CA pinning
   against example.com` meanwhile). `Status` must read `Pinning check
   passed: only Signify-signed certificates are trusted`: a public-CA site
   (example.com) was refused with the driver's bundle, so the bundle
   replaces the system store rather than adding to it, which the release
   build's own check (section 2, line 7) cannot tell apart. The action needs
   the controller to reach the internet; `Pinning check inconclusive:
   example.com unreachable with the system CAs (<the transfer's error>)` or
   `Pinning check inconclusive: example.com failed with the bundle for a
   reason other than its certificate (<the transfer's error>)` proves
   nothing, so run it again once it can (until issue #239 every
   inconclusive answer read `example.com unreachable`, whatever the cause;
   dev builds from that fix on name the request and its error). `Pinning
   check FAILED: public CAs are trusted too; see Lua output` stops the
   release: open an issue, since keyed requests would accept any publicly
   trusted certificate at the bridge's address. Note the OS version and the
   result in the issue and in `docs/status.md`, then install the release
   files again (section 2). After the upgrade, a
   `Status` of `TLS check inconclusive (…): nothing is sent; checking again
   in 30 s` means the new Director version is not proven yet: the driver
   accepts an inconclusive answer only on a version that has answered
   `pinned` before, and it checks again every 30 s until it gets a
   conclusive answer.

A build passes when every line reads as expected; anything else becomes an
issue naming the build number (`docs/status.md` "Open" points at it), and
the release waits.

## Naming

The release of this spike is **1.0 "Cassian"** (owner, 2026-10-24): git tag
`v1.0`, a GitHub release titled `1.0 "Cassian"` with the Release workflow's
seven assets attached (the three `.c4z` files, `SHA256SUMS.txt`,
`manifest.json` and the provenance in two forms; "How a release is cut"
below). Since 2026-10-26 (#304) every X.Y has its own codename from Star
Wars: Andor, kept by all its builds and betas: an X.0 a widely recognised
character, place or object, a point release a decidedly less important one.
Before the first build of a new X.Y the coordinator proposes one and the
owner approves it; it goes into `.github/codenames.json`, which
`tools/changelog.py` reads (used so far: 1.0 Cassian, 1.1 Brasso). The driver files carry the
build number, the commit count, as `Driver Version` (Control4 needs an
integer there); it is named in the release's `manifest.json`, in the
release notes (step 4 below) and in `deploy/house.yaml` (`build:`); the
README names no build and links to the Releases and Environments pages, and
`docs/status.md` names the build it describes. Later releases of the same spike move
the tag and replace the attached files; a new version number comes when
development here is finished.

**How a release is cut** (`.github/workflows/release.yml`; contract
`docs/cicd-gitops-design.md` §5):

1. Merge the code into `main`. Nothing is edited for the release itself.
2. Start the Release workflow: on the repository's Actions page, **Release ▸
   Run workflow**, enter the version (`1.0`, `1.1`, ...). The workflow builds
   `main`'s head and, once the packages are built and attested, tags it
   `v<version>` itself, force-moving an existing tag, in the same run (a run
   that fails earlier leaves the tag where it was). Pushing the tag by hand
   (`git tag -f -a vX.Y -m "X.Y" <commit on main>`, `git push --force origin
   vX.Y`) starts the same build; a tag that is not on `main` is refused.
3. The workflow's build job lints, tests and builds with read-only access
   and pinned tools (contract §5.4 and §5.5); its publish job, which runs no
   third-party code, checks what the build job handed over, signs the
   provenance and attaches to the release of the tag, creating it when
   missing, with the title and notes written from `CHANGELOG.md` (step 4):
   `hue_bridge.c4z`, `hue_light.c4z`, `hue_scene.c4z`, `SHA256SUMS.txt`,
   `manifest.json` (contract §5.2: tag, version, build, commit, build time,
   each package's sha256 and size), `attestations.sigstore.json`, the
   signed build provenance, and `hue-drivers.intoto.jsonl`, the same
   provenance as in-toto JSON lines. A run for a moved tag replaces every
   file.
4. The release's title and notes come from `CHANGELOG.md` on every run
   (`docs/changelog-design.md`): before dispatching, make sure its
   `## Unreleased` entry lists what this build changes (a run with an empty
   entry fails), and for the first release of a new major version that the
   codename is agreed (Andor rule). Check the release page: seven assets,
   the title `<version> "<codename>"`, the notes' first heading with this
   build. After the release, the desired-state PR also runs
   `python3 tools/changelog.py stamp --version X.Y --build N --date
   YYYY-MM-DD`, so `CHANGELOG.md` names the build that was published, and
   each driver's Documentation tab ends with the same list.
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
   `manifest.json`) and `release:` when the version changed. CI's `house`
   check validates the file offline (`python3 tools/deploy.py validate`;
   `validate --online` also compares `build:` with the release's
   `manifest.json`); merge the pull request.
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
   each package's provenance attestation verifies with `gh attestation
   verify <file> --repo corytron/c4-hue-driver --signer-workflow
   corytron/c4-hue-driver/.github/workflows/release.yml --format json`, so
   the Release workflow and nothing else signed it, creates the Deployment
   with status `in_progress`, and writes `build/release/<tag>/BRIEF.md`
   (which names the signer and the gh that checked it) and
   `deployment.json`. A build the release does not carry, a manifest that
   says `dev: true`, a package whose attestation fails, and a deployment of
   `house` still in progress (without `--supersede`) are refused. The check
   needs gh 2.102.0 or newer (2.51.0 to 2.101.0 match only the start of the
   workflow path, GHSA-wjmr-j3rp-mh2g; Ubuntu's own gh 2.46 has no `gh
   attestation`), and `start` refuses an older one; since 2026-10-25 the VM
   has GitHub's own apt package, gh 2.103.2. `--no-attestation` is only for
   a release cut before attestations existed; it never passes an
   attestation that fails. `--tag` names another release than
   `deploy/house.yaml`'s.
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
   (s)` and `Debug Mode` match `deploy/house.yaml`, and the `Status` and
   `Attention` texts; no `[ERROR]` line in a device's Lua tab during the
   install; and whether Composer asked "Restart Director?". If it did, the
   build changed capabilities: answering Yes loads nothing, the owner
   **reboots the controller from System Manager** (it runs elevated; the
   Windows session cannot operate it), and the session reads `Driver
   Version` again afterwards.
6. **Record the result.** `python3 tools/deploy.py done --devices <count>`
   (with `--note` for anything worth keeping) re-reads the release's
   manifest, refuses when its assets changed since `start`, sets the
   deployment to `success` and closes the deploy issue with a comment
   naming the deployment; `python3 tools/deploy.py failed --note "<what the
   session saw; which build the house still runs>"` sets it to `failure`
   and adds the note to the deploy issue, which stays open. Both read
   `build/release/<tag>/deployment.json`; `--deployment ID` names the
   deployment instead.
7. **Check.** `python3 tools/deploy.py status` exits 0 when desired and
   observed agree (3 on drift, 1 on an error), and the `house` environment
   on the
   [Environments page](https://github.com/corytron/c4-hue-driver/deployments/house)
   lists every install, newest first. `docs/status.md` and the README point
   there rather than naming the build.

An install made any other way is recorded after the fact with `python3
tools/deploy.py record --tag vX.Y --build N --at <ISO 8601 time with
offset, such as 2026-10-24T21:04:00-04:00> --note "..."`, so that the
observed state stays true. A build the release does not carry (a `--dev`
build for the dev loop, a feature-branch build for a hardware test) also
takes `--no-manifest`, and `--commit <sha>` names its commit; the drift
issue then shows the house off its desired state until a release is
installed again (`CLAUDE.md`, Deploy).

## Prerelease

A prerelease puts a feature in a tester's hands before the release that
carries it (contract `docs/prerelease-design.md`, issue #269; the first is
`1.1-beta.1`, with the motion sensors of #268). It is built, checked, attested
and published as a release is ("How a release is cut" above), from `main`
only. What differs:

1. **Version and tag.** `X.Y-beta.N`: `X.Y` is the version still to come,
   later than every version in `CHANGELOG.md`, and `N` counts from 1, a new
   number for every build a tester gets. Start the Release workflow with that
   version (Release ▸ Run workflow ▸ `1.1-beta.1`): it tags `main`'s head
   `v1.1-beta.1`. The tag never moves, so a version whose tag exists fails
   before anything is built; take the next `N`. A prerelease carries its X.Y's
   codename from `.github/codenames.json` (1.1-beta.1 is "Brasso"); a new
   X.Y needs its name there first.
2. **Changelog.** Nothing changes in `CHANGELOG.md`: the notes come from the
   same `## Unreleased` entry, which holds everything since the last release,
   and a prerelease is never stamped (`changelog.py stamp` refuses one); the
   release lists it all later. An empty `Unreleased` fails the run, as for a
   release.
3. **What GitHub shows.** The release is marked Pre-release and never Latest,
   so `releases/latest` and the README's download links keep serving the
   release. Check the title, `1.1 beta 1 "Brasso" (build N)`, the
   Pre-release mark, and the assets: every package, `SHA256SUMS.txt`,
   `manifest.json` and the two provenance files. The notes come from
   `.github/prerelease-notes.md`: what it is, the release it follows, the
   changes, how to install, how to go back, where to report, how to verify,
   the license.
4. **Feedback.** The tester gets the release page's link. Reports come through
   the "Beta feedback" issue form (label `beta-feedback`); feedback that
   arrives another way is filed with the same form, with "Reported another way"
   filled in. A fix is an ordinary pull request, then the next beta number.
5. **The house**, when it runs the prerelease too: a desired-state pull request
   sets `deploy/house.yaml` to it (`release: v1.1-beta.1`, its build, and
   `drivers:` exactly the packages of its `manifest.json`), then "Deploy to the
   house" above runs as for a release: the drift issue reads `Deploy
   v1.1-beta.1 (build N) to the house`, and the brief says it is a
   prerelease. Going back to the release is another desired-state pull request.
6. **The release.** When testing is done, cut `X.Y` itself ("How a release is
   cut"): its notes carry the same `Unreleased` entry, and its desired-state
   pull request stamps `CHANGELOG.md`.
