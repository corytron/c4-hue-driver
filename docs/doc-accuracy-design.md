# Documentation accuracy pass (issue #231)

The contract for checking every document a reader of this project sees
against the drivers as they are at build 316 (`main` at c1dd673; its `src/`
is identical to the release commit e3ec53d). Branch `docs/accuracy-231`.
Seven agents edit disjoint files at the same time; the coordinator
integrates, runs `tools/check.sh` and commits.

## 1. What "accurate" means

- **The code is the source of truth.** A document says what `driver.xml`
  and the Lua code at build 316 do, nothing more. Where a document and the
  code disagree, the document changes, never the code. A suspected code bug
  goes into the hand-back, not into the document as fact.
- **Exact texts.** Every property, action, parameter, list item, Status,
  Attention, Event Stream and Last Action text a document quotes is copied
  from the code (`driver.xml` `<name>`, `<default>`, `<minimum>`,
  `<maximum>`, `<items>`; the strings passed to `prop(...)`,
  `C4:UpdateProperty`, `last_action(...)` and friends). Placeholders in a
  quoted text (`<ip>`, `<name>`) stand for what the code formats there.
- **Every behaviour claim has a source:** a code path (file and function),
  or a hardware fact recorded in `docs/design.md` or `docs/status.md` with
  its date. A claim with neither is removed or marked as not verified, in
  the document's own style.
- **Nothing beyond the drivers.** No feature, limit or guarantee the code
  does not have; no speculation about Hue or Control4 behaviour that the
  SDK docs or a recorded hardware fact do not support.
- **Release builds versus dev builds.** The Composer manuals describe
  release builds. Development-only properties and actions (the DEV-ONLY
  block of `src/hue_bridge/driver.xml`, `bridge/devtools.lua`,
  `common/devloop.lua`) are never presented as part of the product there.

## 2. What changed on 2026-10-25 (read these first)

Contracts, in order: `docs/review-leftovers-design.md` (#214),
`docs/lifecycle-refactor-design.md` and `docs/keypad-design.md` (#216),
`docs/security-fixes-design.md` (#221), `docs/cicd-gitops-design.md` (§3
setup-checks, §4.6 triage, §5.4-5.5 release jobs and pins, #221 and #223).
In short:

- Keyed requests: one refusal (`not paired`, `TLS check failed`, `key
  rejected`); the identity check without the key comes first; the TLS
  self-check (`bridge/tlscheck.lua`) with a sticky `not_pinned`, and an
  inconclusive answer accepted only on a Director version that answered
  pinned before; Test Connection waits for both and is refused after a
  failed TLS check; a REST 401/403 is confirmed with one GET of the bridge
  resource before the key-rejected lock; a Test Connection answered 200 by
  the paired bridge clears that lock.
- Stream: at most two stream transfers open (`stream.MAX_ABANDONED + 1`),
  status `Waiting for an earlier stream transfer to close`; `Not connected:
  <reason>` texts; reconnect counts on the Event Stream row.
- Names: `util.display_name` (control characters removed, trimmed, at most
  100 characters) for device names, name rows and the Model row; name
  comparisons through it.
- Keypads: one machine in `common/device.lua`; the keypad settings (Default
  On Brightness / preset, click and hold rates) shown on light and scene
  devices (`hide_proxy_properties` False) and answered with a bare-value
  notification; ranges preset 1-100, rates 0-86400000 ms.
- Commands: retries capped by age (30 s), `not paired`, `key rejected` and
  `TLS check failed` are final.
- Releases: seven assets (the three `.c4z`, `SHA256SUMS.txt`,
  `manifest.json`, `attestations.sigstore.json`,
  `hue-drivers.intoto.jsonl`); verification with `gh attestation verify ...
  --signer-workflow corytron/c4-hue-driver/.github/workflows/release.yml`
  (GitHub CLI 2.102.0 or newer).

## 3. Who owns which file

| Agent | Files (edit only these) | Sources to check against |
|---|---|---|
| bridge-manual | `src/hue_bridge/www/documentation.html` | `src/hue_bridge/driver.lua`, `driver.xml` (release parts), `src/hue_bridge/bridge/*.lua` |
| device-manuals | `src/hue_light/www/documentation.html`, `src/hue_scene/www/documentation.html` | `src/hue_light/`, `src/hue_scene/`, `src/common/device.lua`, both `driver.xml` |
| github-pages | `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `docs/README.md`, `.github/ISSUE_TEMPLATE/*.yml`, `.github/PULL_REQUEST_TEMPLATE.md` | the whole tree, `tools/`, `.github/workflows/` |
| guides | `docs/release-checklist.md`, `docs/composer-checklist.md`, `docs/composer-remote.md`, `docs/dev-loop.md` | `tools/`, `src/`, `.github/workflows/release.yml`, `tools/composer/` |
| design-notes | `docs/design.md`, `docs/status.md` | `src/`, the issues on GitHub (read with `gh`), `deploy/house.yaml` |
| contracts-a | `docs/import-design.md`, `docs/lights-design.md`, `docs/zone-light-design.md`, `docs/lifecycle-refactor-design.md`, `docs/review-leftovers-design.md`, `docs/bridge-compat-design.md`, `docs/raw-stream-design.md` | `src/hue_bridge/` |
| contracts-b | `docs/scenes-design.md`, `docs/smart-scenes-design.md`, `docs/scene-dimmer-design.md`, `docs/keypad-design.md`, `docs/security-fixes-design.md`, `docs/cicd-gitops-design.md`, `docs/documentation-plan.md` | `src/`, `.github/workflows/`, `tools/` |

Not edited by anyone: `docs/reviews/*`, `docs/*-research.md`,
`docs/edge-cases-*.md`, `docs/code-analysis-*.md`, `docs/spike-checklist.md`,
`docs/screenshots-plan.md`, `docs/smart-scenes-research.md` (the #40 run
records into it today), `NOTICE`, `LICENSE`, this file.

## 4. Rules per kind of document

- **Composer manuals** (`documentation.html`): plain HTML in the existing
  style, shown in Composer's Documentation tab; no new external resources;
  keep the trademark and non-affiliation lines. Leave every `<img>` and its
  caption as it is (the pictures are retaken under #61), but list in the
  hand-back each caption or `width` that no longer matches.
- **Feature contracts** (`docs/*-design.md`) are the record of a decision.
  Do not rewrite their history. Where the code now differs from what the
  contract decided, add a short dated note at that spot ("Current
  (2026-10-25, build 316): ... see `file:function`"), or correct a plain
  factual error (a wrong file or function name). Keep each note to the
  point.
- **Guides and checklists** are instructions someone follows: every step
  must work as written against build 316 and today's tools (check each
  command's flags with `--help`; never run anything that contacts the
  controller, the bridge or GitHub with a write).
- **`docs/design.md`**: current-behaviour sections must match the code;
  dated hardware records stay as they are (add a dated note when a later
  change superseded one).
- **`docs/status.md`**: the present (what runs on the house, what is built,
  what is open, pointing at the open issues: read them with `gh issue list`).

## 5. Common rules

- Public repository: placeholders only (10.0.2.143 bridge, 192.0.2.7 VM,
  001788fffe123abc bridge id, RFC 5737 addresses); no LAN address, key,
  bridge id or project name; never copy passages of the Snap One SDK docs
  or of Signify's login-walled docs; cite SDK files by path.
- No `git`, no GitHub writes, no contact with the controller or the bridge.
  Others edit the rest of the checkout at the same time.
- Prose: short sentences, the project's own words, absolute dates.

## 6. Done means

Each owned file read line by line against its sources. `tools/check.sh
--only xml secrets house` clean, and for HTML, `python3 -c "import
html.parser,sys; html.parser.HTMLParser().feed(open(sys.argv[1]).read())"
<file>` raises nothing. The hand-back lists every correction as a table
(where, was, now, source), every claim that could not be verified, every
suspected code bug, and every caption that needs #61.
