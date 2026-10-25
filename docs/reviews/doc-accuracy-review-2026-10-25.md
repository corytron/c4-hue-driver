# Documentation accuracy review (#231, PR #240), 2026-10-25

Scope: branch `docs/accuracy-231` at f2f58cc, checked against build 316. The
branch's `src/` differs from the release commit e3ec53d only in four code
comments (`git diff e3ec53d HEAD -- src/`: `bridge/devtools.lua`,
`bridge/http.lua`, `hue_bridge/driver.lua`, `hue_light/driver.lua`).
Contract: `docs/doc-accuracy-design.md`. Method: each claim was traced to
the code that decides it (file and function), to the release parts of the
three `driver.xml` (the DEV-ONLY blocks stripped the way `tools/build.sh`
strips them), to `.github/workflows/`, to each tool's `--help`, or to a
dated hardware record. GitHub state was read with `gh` (open issues, the
`v1.0` release, branch protection, rulesets); nothing was written there, and
no controller, bridge or LAN host was contacted.

## Verdict

The pass did what its contract asks. About 475 concrete claims were checked,
about 310 of them in the three Composer manuals, and most are right:

- Every property, action and parameter name, default and range in the
  manuals matches the release `driver.xml` files. That is 22 bridge actions
  in `sort_order`, Stream Timeout 30 to 86400 (default 3600), Stream Watchdog
  60 to 3600 (default 600), Debug Mode and Recall As.
- Every Status, Event Stream, Attention and Last Action text in the bridge
  manual's troubleshooting table is a string the code formats.
- The keypad timings and setting ranges match `common/device.lua`: 400 ms
  hold, 600 ms dim after on, 1 s click guard, rechecks at 5, 15, 30 and
  60 s, preset 1 to 100, rates 0 to 86400000 ms, and the blue LED defaults.
- The seven release assets and the verification commands match
  `release.yml` and the live `v1.0` release.
- Every tool flag quoted matches `--help`.

Ten claims are wrong: four in the bridge manual, two in `README.md`, two in
`docs/status.md`, and one each in `docs/release-checklist.md` and
`docs/dev-loop.md`. The two device pages, `SECURITY.md`, `CONTRIBUTING.md`,
`docs/design.md` and the dated contract notes I sampled have none.

The ones readers will notice most:

- The bridge manual says twice that Hue stops calling a scene active after a
  dim from the slider or a keypad. The recorded hardware test V11 refutes
  this, and the Hue Scene page states it correctly.
- The README still says "nothing OS-version-specific is used". The bridge
  manual's writer removed that sentence and replaced it with what the code
  does.
- The open-item lists in `docs/status.md` and the README leave out the
  issues filed during this pass (#232 to #239). Five of them existed before
  those two files were committed.

In addition, seven claims state Hue or Composer behaviour as fact that no
record supports, where a sibling page marks the same behaviour as
unverified. Three more claims describe the intended behaviour where build
316 has an open code bug (#232, #234, #236). All corrections are text only.

## Wrong claims

| Where | Claim | What the code or the record does | Source | Replacement text |
| --- | --- | --- | --- | --- |
| `src/hue_bridge/www/documentation.html:520` (9.4) | "Dimming or changing its lights afterwards (the slider, a keypad, a light's own tile, the Hue app, a Hue dimmer switch) does not turn it off, although Hue itself no longer calls the scene active" | A dim of the whole group leaves the scene's `status.active` unchanged. That covers a relative `dimming_delta` and an absolute `dimming.brightness` on the grouped_light, which is what the scene slider and keypad holds send. Only a change to one light ends it. | `docs/smart-scenes-research.md` §7, V11 (hardware, 2026-10-24): "whole-room dims from Control4 keep a scene playing, by status"; `bridge/scenes.lua:dim`, `level`; the Hue Scene page, line 33, already says it correctly | "Dimming or changing its lights afterwards (the slider, a keypad, a light's own tile, the Hue app, a Hue dimmer switch) does not turn it off, even when Hue itself no longer calls the scene active (Hue stops when a single light of the scene is changed; a dim of the whole room or zone leaves the scene active); the tile shows the new percentage instead." |
| `src/hue_bridge/www/documentation.html:654` (ch. 11) | "a dim from its buttons, its slider or the Hue app keeps them on, although Hue itself no longer calls the scene active once its lights have been dimmed." | As in the row above. | As in the row above | "a dim from its buttons, its slider or the Hue app keeps them on, and so does a change to one of its lights, after which Hue itself no longer calls the scene active (a dim of the whole room or zone leaves it active)." |
| `src/hue_bridge/www/documentation.html:245` (ch. 5) | "A row left empty reaches the driver empty: an empty **Room** means `(mapped room)`, and any other empty row is refused with a `… pick … first` text in **Last Action**." | `(mapped room)` applies only to the Room rows of Add Light, Add Zone Light and Add Scene, where `tonumber(nil)` selects the mapped room. An empty Room in Set Room Mapping is refused with "Not mapped: pick a Control4 room or (no mapping)". The three re-link refusals read "Not re-linked: pick a device and a light", "… and a scene" and "… and a zone or room", with no "first". | `hue_bridge/driver.lua`: `Add_Light`, `Add_Zone_Light`, `Add_Scene`, `Set_Room_Mapping`; `bridge/owner.lua:relink` | "A row left empty reaches the driver empty: an empty **Room** in Add Light, Add Zone Light or Add Scene means `(mapped room)`; any other empty row, Set Room Mapping's **Room** included, is refused with a `Not …: pick …` text in **Last Action** (for example `Not added: pick a light first` or `Not re-linked: pick a device and a light`; chapter 12 lists them all)." |
| `src/hue_bridge/www/documentation.html:808` (ch. 13, Limits) | "so the driver sends the requests of zone, room and scene devices at most one a second after a first three, keeping only the latest value" | Only grouped_light requests use the paced group queue (one a second, burst of 3). These are the requests of zone and room lights, and a scene's OFF, slider and keypad dims. A scene's ON is a recall PUT on `/scene` or `/smart_scene`, sent directly and not paced. The first ON goes out at once; further ONs of the same scene within 300 ms leave as one more. | `hue_bridge/driver.lua:new_group_queue`, `group_hooks`; `bridge/scenes.lua:send_recall`, `activate`, `RECALL_WINDOW_MS` | Replace the quoted part with "so the driver sends the requests of zone and room lights, and a scene device's OFF, slider moves and keypad dims, at most one a second after a first three, keeping only the latest value", and add before the final clause: "a scene's ON is a request of its own and goes out at once (further ONs of the same scene within 0.3 s leave as one);". |
| `README.md:73-75` | "Written and tested on **OS 3.4.2 with Composer Pro 3.4.2**; nothing OS-version-specific is used, but OS 4 has not been tried." | The drivers rely on two behaviours of Director measured on OS 3.4.2 and check both at every start. The first is the per-host `C4:url` queue keyed on the host text, which gives the event stream its own queue (`bridge/altaddr.lua`; `driver.lua:choose_stream_address` self-checks it and falls back to a shared queue). The second is that the controller uses the driver's CA bundle (`bridge/tlscheck.lua`: "Another OS release might treat the option otherwise"). In this pass the bridge manual (line 118) dropped the same sentence for that reason. | code; `docs/design.md`, "`C4:url` transfer scheduling on OS 3.4.2" and "TLS self-check in release builds" | "Written and tested on **OS 3.4.2 with Composer Pro 3.4.2**; OS 4 has not been tried. Where the drivers rely on behaviour measured on OS 3.4.2 (the event stream's own connection queue, the controller applying the driver's CA bundle), they check it at every start and fall back or stop safely (the manual's chapters 3 and 12)." |
| `README.md:403-408` | "On 2026-10-25 they are: … (#228), … (#40) … (#38), … (#65), … (#61), … (#62), and … (#224)." | Also open on 2026-10-25: #231 (this pass), #232, #233, #234, #236, #237, #238 and #239. Issues #232 to #237 were filed (08:05 to 08:07 UTC) before the README commit 3861daa (08:12 UTC). | `gh issue list --state open`, read during this review | Replace the two sentences from "Every open item" to "(#224)." with: "Every open item is an [issue](https://github.com/corytron/c4-hue-driver/issues); [`docs/status.md`](../status.md), "Open", says where each stands." Keep the List View sentence that follows. |
| `docs/status.md:374-398` ("Open") | "Every open item but the last is an issue …", followed by eight items, the last of them "After the next reboot from System Manager (… no issue yet)" | Not listed although open: #232, #233, #234, #236, #237 and #239. #232 to #237 existed before the status commit e50df70 (08:11 UTC). The reboot check is now issue #238. | `gh issue list --state open` | Change the lead to "Every open item is an issue (`gh issue list --state open`); this list says where each stands on 2026-10-25." Replace the last bullet with "**#238** After the next reboot from System Manager: the bridge's log right after it shows no "is not bound to this bridge" lines and Attention no unbound devices (diff review 2026-10-25 row 2)." Add: "**#232, #234, #236** Code bugs found by this pass: a light or zone light hold from mid-range ramps faster than its tile; device-driver persistence and setting edge cases; pairing and Status edge cases." Add: "**#237, #239** Tooling: `deploy.py`'s watchdog range and the tag ruleset; `devctl`, `Composer.psm1` and release-note leftovers." Add: "**#233** Decision: ON and TOGGLE at 100 % or at Default On Brightness." |
| `docs/status.md:88-91` | "No Hue Light devices: all 47 lights were deleted … 126 scenes on the bridge, 1 imported." | The two zone lights listed just before are Hue Light devices (the light driver, kind "group"). The bridge's Scenes row counts devices of both kinds together, so it reads "2 imported", as line 159 of the same page and the release checklist (line 69) say. | `bridge/zone_lights.lua` (`LIGHT_DRIVER`); `bridge/scenes.lua:summary` | "No single-light Hue Light devices: all 47 lights were deleted in Composer on 2026-10-22 and are remembered as deleted (Add Light brings any of them back). 126 + 15 time-based scenes on the bridge, 2 imported (the two Hue Scene devices above)." |
| `docs/release-checklist.md:189-193` (Naming) | "it is named in the release's `manifest.json` and in the release notes (step 4 below), and nowhere else: since 2026-10-25 the README and `docs/status.md` link to the Releases and Environments pages instead of stamping a build number." | `deploy/house.yaml` carries `build: 316`, and this checklist's own "Deploy to the house" step 1 edits it. `docs/status.md` names build 316 on lines 3, 49, 99 and 377. Only the README names no build. | `deploy/house.yaml:7`; `docs/status.md` | "it is named in the release's `manifest.json`, in the release notes (step 4 below) and in `deploy/house.yaml` (`build:`); the README names no build and links to the Releases and Environments pages, and `docs/status.md` names the build it describes." |
| `docs/dev-loop.md:398-399` | "Since build 259 (2026-10-24) the house gets a GitHub release, never a VM build." | The same page (lines 21-24) and `docs/status.md` (line 43) say the house has run dev build 309, a VM build, since 2026-10-25 03:24. It was installed around `tools/deploy.py` and recorded with `deploy.py record --no-manifest`. | `docs/status.md`, "What runs on the house" | "Since build 259 (2026-10-24) a production install is a GitHub release, never a VM build; a dev build (such as 309, on the house since 2026-10-25) goes around `tools/deploy.py` and is recorded with `deploy.py record --no-manifest`." |

## Unverified behaviour stated as fact (not marked in the text)

1. **Bridge manual, lines 362 and 804:** "a white-only lamp in a colour zone
   ignores the colour and keeps its level" and "a lamp that cannot do colour
   ignores the colour it is sent".
   - This is Hue's behaviour and was never seen on the house system:
     `docs/design.md` (2026-10-25) records that every bulb there has colour
     and colour temperature.
   - The Hue Light page (line 35) marks it as not seen.
   - Suggested wording: "should ignore the colour (not seen on the house
     system as this is written, where every lamp has colour)".
2. **Bridge manual, lines 577, 655, 775 and 806:** when the next time slot
   starts, Hue sets that slot's look "brightness included, so a dim lasts
   until then". Line 775 is the "Things that look wrong" item; line 806 says
   "whose look Hue sets in full".
   - The dim before a slot boundary is an open check of #40.
     `docs/smart-scenes-research.md` §7 says "Whether the room had been
     dimmed before 16:00 is not known".
   - The Hue Scene page (line 54) marks it as not watched.
   - Use the scene page's wording, and hedge or drop the line 775 item until
     #40 records a result.
3. **Bridge manual, lines 626, 645 and 878:** "Turn On" in programming means
   100 % "in any case" or "always".
   - The driver maps the proxy's `ON` and `TOGGLE` to 100 %
     (`hue_light/driver.lua`). Which command programming's Turn On sends is
     not recorded.
   - The Hue Light page (line 46) says this had not been checked, and #233
     is open.
   - Suggested wording: "The driver takes the proxy's ON and TOGGLE as
     100 %; whether "Turn On" in programming arrives as ON, and so ignores
     a changed On preset, has not been checked."
4. **Bridge manual, lines 517 and 629:** a ramp time "becomes the transition
   Hue uses to fade into the scene".
   - The bridge sends `recall.duration`, and Hue accepted it (HTTP 200,
     2026-10-21). The fade itself was never measured:
     `bridge/scenes.lua:send_recall` marks it [assumed], and so does
     `docs/scenes-design.md` §1.
   - The Hue Scene page (line 37) says so.
   - Suggested wording: "is passed to Hue as the time to fade into the scene
     (Hue accepts it; how long the fade takes has not been measured)".
5. **Bridge manual, line 152:** a reboot takes "between two and eight
   minutes on the house system".
   - `docs/design.md` records one reboot of about seven and a half minutes.
     No record gives two.
   - Suggested wording: "(about seven and a half minutes once on the house
     system)".
6. **Bridge manual, line 693:** error 28 is quoted as "Operation timed out".
   - The controller's message text is recorded nowhere, and line 203
     paraphrases it differently ("no answer in time").
   - Suggested wording: "(the controller reports it as transfer error 28, a
     timeout)".
7. **`README.md`, line 202:** "within 30 seconds".
   - This is Hue's link-button window, which the driver does not time. The
     manual (line 179) hedges it: "about 30 seconds, by Hue's own account".
   - Suggested wording: "right away (Hue accepts a pairing for about
     30 seconds after the press)".

## Intended behaviour described where build 316 has an open code bug

These match the design, but not what build 316 does in an edge case. The
contract keeps code bugs out of the documents, so they are listed here for
the coordinator to decide on.

1. **Bridge manual, lines 641-642 (keypad table), and Hue Light page,
   line 34:** a hold covers "the full range in 5 seconds".
   - On a Hue Light, and on a zone or room light, build 316 sends Hue a
     full-range `dimming_delta` (`brightness_delta` 100) over a duration
     shortened by the distance left (`hue_light/driver.lua:start_ramp`,
     `bridge/commands.lua:body`, `bridge/zone_lights.lua:dim`). A hold that
     starts mid-range therefore ramps faster than the setting and the tile
     (#232).
   - Holds from off or from an end of the range take the stated time, and so
     does every hold on a Hue Scene: `hue_scene/driver.lua:on_hold` sends
     the full hold rate.
2. **Bridge manual, line 646:** the driver "refuses anything else, and
   Composer then shows the value in use again".
   - This is true for a number out of range. A value that is not a number is
     refused with a log line and not reported back
     (`common/device.lua:save_setting`, #234).
   - The device pages claim it only for out-of-range values, which is right.
3. **Bridge manual, line 85:** a name difference is "compared with the name
   the bridge would give the device today".
   - For a Hue device with a single light, a new Hue Light is named after
     the Hue device (`bridge/lights.lua:creation_name`).
   - Attention, Adopt Hue Names and the device's Adopt Hue Name compare with
     the light's own name instead (`lights.expected_name`, the entry's
     `name`).
   - When the two names differ in Hue, a freshly imported light is listed as
     a name difference at once (#236).

## Checked and found correct (selection)

- **Bridge `driver.xml` (release):**
  - 25 properties in Composer's order (the manual's 20 rows, with `Last
    Action (2)` to `(6)` described under Last Action), with defaults:
    Attention `None`, Events Received `0`, Stream Timeout and Stream
    Watchdog as above.
  - 22 actions, as the manual's caption and the release checklist say (25
    with the DEV-ONLY block), with every parameter name: Light, Room, Group,
    Device, Hue Room, Scene.
  - Dev builds add exactly two properties and three actions.
- **Bridge Status texts** (`driver.lua`: `refresh_status`, `verify_identity`,
  `tls_gate`, `test_connection`, `Pair_Bridge`; `bridge/pairing.lua`): all
  quoted texts, including the nine pairing failures and refusals, the four
  identity and TLS texts, and all of Test Connection's texts.
- **Event Stream texts** (`bridge/stream.lua`; `driver.lua:new_stream`,
  `key_rejected`, `Connect_Event_Stream`):
  - the watchdog, server-closed, transfer-error, aborted, oversized-line and
    HTTP texts;
  - the waiting text and the cap of two transfers;
  - the two reconnect-count formats;
  - the backoff of 1 to 60 s.
- **Stream Address:** `10.000.002.143 (own queue, spelling 1 of 7)` and
  `198.51.100.005 (own queue, the only spelling)`. These follow from
  `altaddr.stream_family`: two paddable octets give 9 combinations minus 2
  reserved ones, and one paddable octet gives a single spelling.
- **Lifecycle texts:** every Attention item, its order and its "+N more"
  (`driver.lua:attention_text`, `bridge/owner.lua:attention_items`,
  `lights:attention`), and the Lights, Scenes and Zone Lights summaries and
  list lines. Every Last Action text of the chapter 12 table was traced to
  `lights.lua`, `scenes.lua`, `zone_lights.lua` and `owner.lua`, including
  the busy texts and their 90 s expiry.
- **Device texts:** every Status and Hue Light ID or Hue Scene ID format on
  the light and scene devices (`hue_light/driver.lua`,
  `hue_scene/driver.lua`), the forgotten and deleted texts, and the
  whole-home scene reading "(no room)" with Hue Room blank.
- **Command pacing and retries** (`bridge/commands.lua`): 10 a second with a
  burst of 10 for lights; 1 a second with a burst of 3 for groups; retries
  0.5 to 8 s for at most 30 s; `not paired`, `key rejected` and `TLS check
  failed` final.
- **Fallback times** match the drivers' constants: on a light, the ramp
  plus 1 s; on a scene, 2 s, 1 s and 1.5 s.
- **Recorded hardware facts** (`docs/design.md`): the proxy id is the
  protocol id + 1; keypad settings commit on Enter; Composer's install and
  delete dialog texts.
- **Releases** (`release.yml`): seven assets; title `<version>`; first notes
  paragraph naming the build. The live `v1.0` carries the seven assets and
  is titled `1.0 "Cassian"`.
- **Verification and checks:** `gh attestation verify` flags exist in gh
  2.103.2 (`--signer-workflow`, `--source-digest`, `--bundle`, `--format`).
  The CI job names, the packager commit, the pinned rocks, the checks and
  tools of `check.sh` and `setup-checks.sh`, the Dependabot cooldown, the
  auto-merge scope, and the Scorecard and triage triggers all match.
- **Branch protection:** four required checks, branch current, admins
  included, conversations resolved, no force pushes.
- **Tool flags:** the `deploy.py`, `devserver.py` and `devctl.py`
  subcommands and flags match their `--help`, including the `wait` timeout's
  exit code 2.
- **Contract notes:** the function and key names in the 23 sampled notes
  exist, for example `start_smart_hold`, `follow_with_level`,
  `path_refusal`, `stop_fallback`, `EARLY_HELLOS_MAX` = 200,
  `NIL_CONFIRM_S` = 5, `hue_zone_light_tombstones` and `tls_pinned_on`.

## Claims checked per file

| File | Checked | Wrong | Unverified as fact | Intent where build 316 has a bug |
| --- | --- | --- | --- | --- |
| `src/hue_bridge/www/documentation.html` | about 230 | 4 | 6 | 3 |
| `src/hue_light/www/documentation.html` | about 40 | 0 | 0 | 1 (same as bridge item 1) |
| `src/hue_scene/www/documentation.html` | about 40 | 0 | 0 | 0 |
| `README.md` | about 35 | 2 | 1 | 0 |
| `SECURITY.md` | about 15 | 0 | 0 | 0 |
| `CONTRIBUTING.md` | about 22 | 0 | 0 | 0 |
| `docs/release-checklist.md` | about 25 | 1 | 0 | 0 |
| `docs/dev-loop.md` | about 18 | 1 | 0 | 0 |
| `docs/design.md` | about 10 | 0 | 0 | 0 |
| `docs/status.md` | about 15 | 2 | 0 | 0 |
| Dated "Current (2026-10-25, build 316)" notes: 23 of the 84 in 9 contracts (the notes in `docs/design.md` count under that file) | about 25 | 0 | 0 | 0 |
| **Total** | **about 475** | **10** | **7** | **3** |

The bridge manual's count covers:

- every `<code>` text of the chapter 12 table (152 spans);
- the 22 actions and their parameters;
- the 20 properties with their defaults and ranges;
- the chapter 4 to 11 texts and behaviours listed above.
