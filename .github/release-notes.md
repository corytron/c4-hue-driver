## {version} "{codename}" (build {build})

Codename: **{codename}**. Each major version of this project is named after something from Star Wars: Andor; every {version} build keeps the name. Released {date}.

Install all three `.c4z` files at once through Driver ▸ "Add or Update Driver or Agent…" in Composer Pro, updating every device in place; never delete and re-add the Hue Bridge driver (that loses the pairing). When the changes below say a driver's capabilities changed, reboot the controller from System Manager afterwards: on OS 3.x, Composer's "Restart Director?" does not load them.

### New in build {build}

{this_build}

### What you get

- **Hue Bridge** driver: pairing with the link button, the bridge's event stream for live two-way state, room mappings, import of lights, lifecycle handling (renames, deletions, re-links, restores), scenes and time-of-day scenes, zone and room lights, readable Composer properties, and a Documentation tab with the full owner's manual.
- **Hue Light** driver (light_v2): on/off, dimming, colour temperature and colour where the bulb supports them; a Hue zone or room as one light; keypad Button Links (Top, Bottom, Toggle) with hold-to-dim and LEDs.
- **Hue Scene** driver (light_v2 dimmer): ordinary and time-of-day scenes with a slider in sync with the Hue app and keypad LEDs.

Each driver's Documentation tab ends with the full list of releases.

### Requirements

- Control4 OS 3.3.0 or newer; tested on OS 3.4.2 with Composer Pro 3.4.2. Not yet tried on OS 4.
- A Hue Bridge Pro (tested) or Hue Bridge v2 (not yet tried) on the LAN, with a fixed IPv4 address; HTTPS (port 443) to the bridge.

### Verify a download

```sh
sha256sum -c SHA256SUMS.txt
gh attestation verify hue_bridge.c4z --repo corytron/c4-hue-driver --signer-workflow corytron/c4-hue-driver/.github/workflows/release.yml
```

`gh` 2.102.0 or newer; repeat the second line for `hue_light.c4z` and `hue_scene.c4z`. `manifest.json` names the build, the commit and each package's sha256.

### Earlier builds of {version}

{history}

Every release so far: [CHANGELOG.md](https://github.com/corytron/c4-hue-driver/blob/main/CHANGELOG.md).

### License

Apache License 2.0 (LICENSE and NOTICE travel inside each `.c4z`). Philips Hue and Hue are trademarks of Signify Holding B.V.; Control4 and Composer are trademarks of Snap One, LLC. This project is not affiliated with, endorsed by or supported by Signify or Snap One.
