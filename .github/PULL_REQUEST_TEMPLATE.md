<!-- Keep it short. The checklist is the one in CONTRIBUTING.md. -->

## What

<!-- The change in a sentence or two, and "Closes #N" for the issue it fixes. -->

## Why

<!-- The problem it solves or the behaviour it changes. If the driver would act on its
     own over the life of the system (importing, syncing names or rooms, creating or
     removing devices), name the contract under docs/ that decided it. -->

## How it was tested

- [ ] `tools/check.sh` passes: lint, specs, shell, Python, XML, workflows, secrets and the
      house's desired state (CI runs the same script with `--strict`)
- [ ] A change of behaviour comes with a spec
- [ ] `tools/build.sh` builds the three `.c4z` files
- [ ] On hardware: <!-- Control4 OS version, Composer Pro version, bridge model, what you
      clicked and what you saw; or "not run on a controller", which is fine if said -->

## Checklist

- [ ] **Capabilities.** This PR does not change a `driver.xml` `<capabilities>` block.
      If it does, say so prominently above: installing it makes Composer ask "Restart
      Director?" and every user must reboot their controller from System Manager before
      the new build loads.
- [ ] **No private data.** No real LAN address, bridge id, application key, certificate,
      Composer project name or screenshot of a real project; placeholders as in
      CONTRIBUTING.md.
- [ ] **No third-party text.** Nothing from Snap One's SDK repositories or documentation,
      nothing from Signify's login-walled developer pages.
- [ ] **Manual.** `src/hue_bridge/www/documentation.html`, and the Hue Light or Hue Scene
      page (`documentation.html` under `src/hue_light/www/` or `src/hue_scene/www/`), are
      updated if a property text, a `Last Action` result or an `Attention` line changed.
- [ ] **Changelog.** A change to what the drivers do or what their documentation says
      has a line under `## Unreleased` in `CHANGELOG.md`, written for the people who
      install and use the drivers, with the issue number (`docs/changelog-design.md`).
- [ ] **Status.** `docs/status.md` is updated if what runs or what is open changed.
