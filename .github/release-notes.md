## {version} "{codename}" (build {build})

{codename_note}

Released {date}.

Install every `.c4z` file of the release at once through Driver ▸ "Add or Update Driver or Agent…" in Composer Pro, updating every device in place; never delete and re-add the Hue Bridge driver (that loses the pairing). When the changes below say a driver's capabilities changed, reboot the controller from System Manager afterwards: on OS 3.x, Composer's "Restart Director?" does not load them.

### New in build {build}

{this_build}

### What you get

- **Hue Bridge** driver: pairs with one Hue bridge with its link button and creates the other devices; the bridge's event stream for live two-way state, room mappings, import of lights and motion sensors, lifecycle handling (renames, deletions, re-links, restores), the Hue automations check, readable Composer properties, and a Documentation tab with the full owner's manual.
- **Hue Light** driver (light_v2): on/off, dimming, colour temperature and colour where the bulb supports them; a Hue zone or room as one light (a zone light); keypad Button Links (Top, Bottom, Toggle) that tap, ramp and hold as on a Control4 dimmer, with LEDs; Control4 load groups.
- **Hue Scene** driver (light_v2 dimmer): ordinary and time-of-day scenes; the tile follows its own scene, the slider dims the room or zone while keeping the scene's look, and keypad Button Links with LEDs.
- **Hue Motion Sensor** driver (a stock Control4 motion sensor): Hue motion sensors and MotionAware areas (Hue Bridge Pro), with an occupancy hold time and the temperature, light level and battery where the sensor has them.

Each driver's Documentation tab ends with the full list of releases.

### Requirements

- Control4 OS 3.3.0 or newer; tested on OS 3.4.2 with Composer Pro 3.4.2. Not yet tried on OS 4.
- A Hue Bridge Pro or a Hue Bridge v2 (the square bridge) on the same network as the controller, preferably with a fixed IPv4 address; HTTPS (port 443) to the bridge. No internet access and no Hue account are needed.

### Verify a download

```sh
sha256sum -c SHA256SUMS.txt
for f in *.c4z; do gh attestation verify "$f" --repo corytron/c4-hue-driver --signer-workflow corytron/c4-hue-driver/.github/workflows/release.yml; done
```

`gh` 2.102.0 or newer, in the folder that holds every file of the release. `manifest.json` names the build, the commit and each package's sha256.

### Earlier builds of {version}

{history}

Every release so far: [CHANGELOG.md](https://github.com/corytron/c4-hue-driver/blob/main/CHANGELOG.md).

### License

Apache License 2.0 (LICENSE and NOTICE travel inside each `.c4z`). Philips Hue and Hue are trademarks of Signify Holding B.V.; Control4 and Composer are trademarks of Snap One, LLC. This project is not affiliated with, endorsed by or supported by Signify or Snap One.
