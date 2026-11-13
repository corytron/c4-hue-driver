# Security review of the driver source, 2026-11-13 (issue #480)

The contract for a full security review of the four drivers' source code.
It puts the emphasis where the owner asked: **the driver running on a
Control4 controller, and the driver being installed on one.** It is the
third review, after
[`reviews/security-2026-10-24.md`](reviews/security-2026-10-24.md) and
[`reviews/security-2026-10-25.md`](reviews/security-2026-10-25.md), whose
findings were fixed under [`security-fixes-design.md`](security-fixes-design.md)
(#217). Each reviewer checks that those fixes still hold, as well as
looking for new flaws.

Four reviewers read the code, which is read-only for them. Each writes one
report. The coordinator merges them, rates the findings, opens the fixes
and decides what is published, and when (section 5).

## 1. The owner's words (2026-11-13)

"kick off a full security flaw review of all the driver source code. with
the emphasis being security of the driver running on control4 and
installing on control4"

## 2. What is protected

- **The controller.** Director, the Lua sandbox, the other drivers, and
  everything else the controller runs and controls. The drivers must not
  become a way to run code, crash Director, starve it of memory, CPU or
  timers, or act on devices they were not asked to.
- **The Hue application key** and the pairing. Anyone holding the key
  controls every Hue light in the house.
- **The house's privacy.** Room, light and scene names, presence (motion),
  addresses and the bridge id. Logs, properties and Composer pages are
  read by dealers and appear in screenshots.
- **The packages.** A `.c4z` that reaches the controller is exactly the one
  CI built from `main`, and a release package carries nothing
  development-only.
- **The dev key** (`~/.config/c4-hue-driver/devkey`, which signs dev-loop
  bundles). It never ships, and a release build never accepts dev-loop
  code.

## 3. Who might attack, and from where

| Origin | Examples |
|---|---|
| The LAN | A device that answers mDNS as a Hue bridge. A host taking the bridge's address after a DHCP change. A man in the middle on HTTPS or on the event stream. A flood of connections or packets toward the controller. |
| The Hue side | Whatever can write into the bridge: the Hue app, other Hue integrations, Hue cloud services. Names, scene and automation fields, very large or malformed resources, and event-stream frames all reach the drivers. |
| The controller | Another driver in the same project sending commands, bindings or messages to these drivers. Composer actions and properties with unexpected values. `LUA_ACTION` and hidden aliases. Programming. |
| The install | A tampered or swapped `.c4z` on the way to Composer. A dev build left installed. A package that carries test or dev code. What runs on the first load: `OnDriverInit`, `OnDriverLateInit`, persisted data from an older version. |
| The supply chain | The release workflow, the action pins, the provenance, `tools/build.sh`, `tools/deploy.py` and the Windows brief's download and hash check. |

## 4. Reviewers (one report each; the source is read-only)

| Reviewer | Area | Report |
|---|---|---|
| **N** (network trust) | `src/hue_bridge/bridge/`: `http.lua`, `stream.lua`, `netstream.lua`, `sse.lua`, `tlscheck.lua`, `pinning.lua`, `altaddr.lua`, `conntest.lua`, `netcheck.lua`, `netgate.lua`, `probe12.lua`, `mdns.lua`, `discovery.lua`, `bridges_found.lua`, `pairing.lua`, `pair_window.lua`, `credentials.lua`, `identity.lua`, plus `hue_model.lua` and the JSON decoding as parsers of untrusted input | `docs/reviews/security-2026-11-13-network.md` |
| **C** (the controller surface of the Hue Bridge driver) | `src/hue_bridge/driver.lua`, `driver.xml`, `bridge/actions.lua`, `commands.lua`, `devtools.lua`, `project.lua`, `registry.lua`, `owner.lua`, `names.lua`, `automations.lua`, `housekeeping.lua`, `tasks.lua`, `sweep.lua`, the module set the driver loads, `src/common/dispatch.lua`, `log.lua`, `devloop.lua` | `docs/reviews/security-2026-11-13-controller.md` |
| **D** (device drivers) | `src/hue_light/`, `src/hue_scene/`, `src/hue_motion/` (Lua and XML), `src/common/device.lua`, `link.lua`, and the bridge-to-device messages from both sides (`docs/lights-design.md` and later contracts) | `docs/reviews/security-2026-11-13-devices.md` |
| **I** (install and supply chain) | `tools/build.sh` and what each `.c4z` contains (build them into a scratch directory and list them); `driver.xml` encryption and other flags; `src/*/www/` (the Documentation tabs as HTML in Composer); `.github/workflows/release.yml`, `ci.yml`; `tools/deploy.py`, the brief it writes, `tools/devserver.py`, `tools/devctl.py`, `tools/build.sh --dev`; `docs/cicd-gitops-design.md`, `docs/dev-loop.md` | `docs/reviews/security-2026-11-13-install.md` |

Every reviewer also reads the two earlier reviews and `docs/security-fixes-design.md`.

## 5. Findings and disclosure

- **Rating:** Critical, High, Medium, Low or Info. Each finding gives:
  - the attacker's position (section 3) and what they need;
  - the impact on what is protected (section 2);
  - the file and function, with a line number;
  - how sure the reviewer is: [verified: read, or tried in a spec or a scratch Lua run] or [assumed];
  - a suggested fix.

  Claims about the DriverWorks API cite the SDK file under
  `~/c4-tools/reference/`. Do not invent API behaviour.
- **Reports stay off GitHub until triaged.** The reports are written in this
  worktree and are not committed or pushed. The coordinator:
  - files each **Critical or High** finding as a private GitHub security
    advisory and fixes it through a PR; the report is published only
    after the fix ships;
  - opens a public issue labelled `security` per **Medium or Low** finding,
    and fixes it through a PR that closes it;
  - publishes the merged review with every finding's outcome, as
    `docs/reviews/security-2026-11-13.md`, in Discussions.
- **Out of scope:** the Hue bridge's own firmware, Control4's own software,
  and the owner's LAN set-up. Mention a weakness there only where the
  drivers could reasonably defend against it.
