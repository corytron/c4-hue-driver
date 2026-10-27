# Changelog

Every published release of the Hue Bridge, Hue Light, Hue Scene and (from
1.1) Hue Motion drivers,
newest first, with what changed since the release before it. A version X.Y
is the GitHub release of the tag `vX.Y` and carries its own codename from
Star Wars: Andor (`.github/codenames.json`: a major character for an X.0, a
lesser one for a point release; 1.0 is "Cassian", 1.1 "Brasso"). A version
can be released as several builds: the build number is the commit count of
the released commit and the Driver Version that Composer shows for every
driver, and each newer build of a version replaces the files of its
release. Development builds and builds installed only for tests are not
listed.

## Unreleased

### Added
- Hue motion sensors and MotionAware areas (Hue Bridge Pro) as Control4
  motion sensors: a fourth driver, Hue Motion, with the stock motion
  programming, light level, temperature, battery and an occupancy hold time,
  added from the bridge's Add Motion Sensor and Add Motion Area actions, and
  a Log Motion Diagnostics action for testers (#268).
- Add All New Motion Sensors: one click adds every Hue motion sensor not
  added yet to the Control4 room its Hue room maps to, and lists the ones it
  skips (#319).
- Two programming commands on every Hue Light device: Raise Level By
  (points over the current level, remembering it) and Restore Saved Level
  (back to it, unless someone changed the light since), for motion
  programming that raises lamps and puts them back (#297).
- Prereleases for testers: versions such as 1.1-beta.1 appear on the
  Releases page marked Pre-release, with their own notes and a Beta feedback
  form; the stable release stays the one marked Latest (#269).
- A setting on every Hue Scene device, On State Follows: by default its
  tile and keypad LEDs now show on while any light of the scene's room or
  zone is on, whatever turned it on (another scene, the Hue app, a Hue
  switch, a Hue Light in Control4), and off once they are all off. Choose
  This scene for the earlier behaviour, on only while that scene is the one
  played. This changes existing scene keypads after the update (#310).

### Changed
- The manual says what to do when a device's Documentation tab still shows
  the page of the build before right after an update: select the device
  again (#260).
- The top of the project's GitHub page links the changelog, the current
  state, the design notes, the contributing guide, the security policy, the
  code of conduct and the license, and every link in the project's
  documents is checked on each change (#263).
- The top of the project's GitHub page has a download link for each of
  the three drivers of the latest release (#266).

### Fixed
- A Hue Light or Hue Scene device newly added no longer fails its start
  with a Lua error and shows no state: a keypad setting never saved was
  read as an error (#298).
- A MotionAware area's device no longer flips to "no motion" in the middle
  of a walk: it shows motion while either of the area's two Hue motion
  reports does, and the manual says how to make the area's Hue automation
  do nothing so that Control4 alone decides what the lights do (#288).


## 1.0 "Cassian", build 359 (2026-10-25)

### Added
- A changelog: every release's notes on GitHub are written from
  `CHANGELOG.md`, and each driver's Documentation tab ends with the full
  list of releases (#255).

## 1.0 "Cassian", build 349 (2026-10-25)

### Changed
- Every Documentation tab carries new pictures taken on the current
  drivers: 24 in the bridge's manual, two of them new for zone lights, and
  the Hue Light and Hue Scene pages now show their own (#61).
### Fixed
- Pairing with a different bridge is refused until Forget Pairing, before
  any key is asked and without changing anything; the same bridge can
  still be paired again with a new key, at a new address or after a
  restore from its own backup (#236).
- Status reads "Paired" only once the bridge has passed its identity
  check, and Event Stream says why it is not connected yet. A new address
  brings the event stream back after a rejected key, and Forget Pairing
  during the identity check no longer raises a Lua error (#236).
- A hold on a single Hue Light moves at the hold rate from anywhere in the
  range, so the lamp and its tile move together (#232).
- A zone or room light keeps its type across a restart, so its texts and
  Adopt Hue Name stay right (#234).
- A hold rate longer than 100 minutes is used as 100 minutes on single
  lights too, as on zone lights and scenes, and a keypad setting that is
  not a number is answered with the value kept (#234).
### Known limits
- A hold on a scene, zone light or room light runs to full or off in about
  a second, because Hue ignores the dim duration on a group; taps and the
  slider work (#249, planned for 1.1).

## 1.0 "Cassian", build 329 (2026-10-25)

### Changed
- The Documentation tabs of all three drivers were checked line by line
  against the drivers and corrected: hold timing, the keypad settings
  under Composer's own names with their ranges, tile taps and Default On
  Brightness, how Hue names become device names, scene levels and ramps,
  and the bridge's manual throughout (#231).
- NOTICE, which travels in each package, also names the project's own
  decoy certificate that the TLS self-check uses (#231).
### Known limits
- A hold that starts mid-range on a single Hue Light moves faster than its
  tile; the bridge's manual says so (#232, fixed in build 349).

## 1.0 "Cassian", build 316 (2026-10-25)

### Added
- Keypad settings: Hue Light devices show Default On Brightness, the
  click and hold rates and the button LED colours on their Properties
  tab, Hue Scene devices the hold rates and LED colours. Each is kept per
  device; a value out of range is refused and the value kept is shown
  again (#59, #57).
- Event Stream counts the reconnects since the driver started (#65).
### Changed
- **Reboot after installing over build 259 or older:** the controller
  must be rebooted from System Manager, because the Hue Light and Hue
  Scene drivers changed a capability (`hide_proxy_properties`, so the
  keypad settings show) and on OS 3.x Composer's "Restart Director?" does
  not load it (#59).
- One shared base serves the bridge's lights, scenes and zone lights, and
  one keypad machine both device drivers; Adopt Hue Names now reads every
  Composer name before the first rename for scenes and zone lights too
  (#56, #57).
### Fixed
- A command that cannot reach the bridge is retried for at most 30 s after
  its last change, then dropped, instead of arriving minutes later (#43).
- A rejected application key stops the event stream, and Status reads
  "Key rejected by the bridge (HTTP 403): re-pair with Pair Bridge"
  instead of the driver retrying as if the bridge were offline. A refused
  request is confirmed once before everything is held; Pair Bridge, a new
  address or a Test Connection that succeeds ends it (#44, #217).
- At most two event-stream transfers are open at once on every path, so
  commands never wait behind abandoned ones (Director runs at most four
  transfers at once); Event Stream reads "Waiting for an earlier stream
  transfer to close" meanwhile (#46, #217).
- Stream Watchdog (s) accepts 60 to 3600, the range the driver uses (#54).
- A zone or room light's colour temperature is kept within the range all
  its lamps share (#58).
- Hardening from the reviews of 2026-10-24: stale address results
  ignored, stuck streams restarted, pairing keys checked, scene resyncs,
  Forget Scene and recall coalescing, deletions during an add, and device
  drivers that wait for late init and report their unchanged state after
  a failed send (#46, #47, #48, #49).
### Security
- The application key goes only to the paired bridge: after every start
  and address change the bridge's identity is checked without the key,
  and a TLS self-check (a request with a decoy CA bundle must fail
  certificate verification) proves that the driver's CA bundle is in
  charge. Nothing keyed is sent before both pass, and Test Connection
  waits for the same checks (#53, #217).
- A failed TLS check holds until the next start or address change; an
  inconclusive one passes only on a Director version that has answered
  "pinned" before, and is otherwise checked again every 30 s (#217).
- Keyed requests refuse redirects, a malformed event cannot break event
  handling, resource ids from the bridge are validated, and Hue names are
  cleaned (control characters removed, trimmed, at most 100 characters)
  before they become Control4 names, without renaming existing devices
  (#45, #217).
- The release packages are built by a job without write access and
  attested by a separate one; each release also carries
  `hue-drivers.intoto.jsonl`, and `gh attestation verify --signer-workflow`
  (GitHub CLI 2.102.0 or newer) checks that the Release workflow built
  them (#217).
### Known limits
- Default On Brightness and the click rates apply to keypad taps only:
  Control4's ON, and TOGGLE while the light is off, still turn a light on
  at 100 % (#233).
- The colour-on mode that Composer lists for a Hue Light is not used by
  the driver (#234).

## 1.0 "Cassian", build 259 (2026-10-24)

### Changed
- Last Action is no longer a drop-down: its text wraps at about 72
  characters onto the read-only rows Last Action (2) to (6), which show
  only while they hold text, so a whole result reads without a click; a
  longer one ends in "… (Lua output)" (#68).
### Security
- Each release also carries `manifest.json` (tag, build, commit, and each
  package's checksum and size) and signed build provenance,
  `attestations.sigstore.json`, which `gh attestation verify` checks
  (#204).
### Known limits
- The Lights, Scenes, Zone Lights and Room Mappings drop-downs stay
  editable, since Composer greys out a read-only list: picking an item
  offers Set, which changes nothing, and the row returns to its summary
  (#68).

## 1.0 "Cassian", build 237 (2026-10-24)

### Added
- Bridge Name (the bridge's own name, as in the Hue app) and Bridge
  Firmware (its software and API version, with a note when an update is
  due) rows; Bridge Model shows the model's name with its id, such as
  "Hue Bridge Pro (BSB003)" (#35).
### Changed
- Pairing refuses the round first-generation bridge (BSB001, which has no
  CLIP v2 API), a device that is not a Hue bridge, and bridge software
  older than 1948086000, the first with the CLIP v2 API, each with its own
  Status text and before any key is asked; the identity check at every
  start refuses a first-generation bridge too (#35).
- The release's files are built by GitHub's Release workflow from the
  tagged commit, with `SHA256SUMS.txt` to check a download (#34).

## 1.0 "Cassian", build 228 (2026-10-24)

### Added
- **Hue Bridge** driver: pairing from Composer with the bridge's link
  button (Pair Bridge, Forget Pairing). HTTPS only, with the bridge's
  certificate checked against Signify's root certificates (shipped with
  the driver) and its identity checked before the application key is
  sent; the key stays on the controller and is never shown (#2, #33).
- Live two-way state from the bridge's event stream: changes made in the
  Hue app, with Hue switches or by Hue automations reach Control4 within a
  second or two, with a resync after every reconnect. Nothing is polled
  and no cloud account is needed (#2, #6).
- Import of lights into Control4 rooms (Add Light, Import All New Lights),
  guided by room mappings (Set Room Mapping, Map Rooms By Name, Room
  Audit) (#3, #5).
- **Hue Light** driver (light_v2): on/off, dimming, colour temperature and
  full colour where the bulb supports them; a white-only bulb shows no
  colour controls (#3).
- Zone lights: a Hue zone or room as one Hue Light device (Add Zone
  Light), whose tile, slider and colour controls move every lamp in it
  with one request (#30).
- **Hue Scene** driver (light_v2 dimmer): Hue scenes and the time-of-day
  scenes (Golden hours, Natural light) as devices (Add Scene, Add All
  Scenes Of Room). ON plays the scene or starts its schedule, OFF turns
  its room or zone off, and the slider dims the room while keeping the
  scene's look, in sync with the Hue app (#9, #25, #28).
- Keypad Button Links (Top, Bottom, Toggle) on lights and scenes: tap for
  on and off, hold for Hue's own smooth dimming, and LEDs that follow the
  device, also after changes made in Hue (#19, #20, #24).
- Lifecycle handling: renames on either side, lights replaced or deleted
  in Hue, devices deleted in Composer, a reset or replaced bridge and a
  restored project are reported on the Attention row and resolved with a
  click (Adopt Hue Names, Re-link Device To Light, Forget Light, Link
  Devices). The driver never creates, renames, moves or deletes a Control4
  device on its own (#5, #13).
- Readable Composer properties: Status, Event Stream, Lights, Scenes, Zone
  Lights, Room Mappings and Last Action in plain words, the long ones as
  drop-down lists; Test Connection, Connect Event Stream and Disconnect
  Event Stream actions (#29, #33).
- Commands are coalesced and paced at Hue's limits: a fast slider drag
  sends only the latest value, about ten light commands a second and one
  group command a second (#2, #30).
- A Documentation tab in each driver, with the full owner's manual on the
  Hue Bridge, and driver icons; LICENSE (Apache 2.0) and NOTICE travel
  inside each package (#13, #14, #33).
### Known limits
- Needs Control4 OS 3.3.0 or newer. Tested on OS 3.4.2 with Composer Pro
  3.4.2 and a Hue Bridge Pro; OS 4 and the square Hue Bridge v2 have not
  been tried.
- No Hue motion sensors, buttons, entertainment areas or MotionAware; one
  bridge per project; the whole-home group is not offered as a light.
