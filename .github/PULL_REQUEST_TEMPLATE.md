<!-- Keep it short. The checklist is the one in CONTRIBUTING.md. -->

## What

<!-- The change in a sentence or two. Link the issue if there is one. -->

## Why

<!-- The problem it solves or the behaviour it changes. If the driver would act on its
     own over the life of the system (importing, syncing names or rooms, creating or
     removing devices), name the contract under docs/ that decided it. -->

## How it was tested

- [ ] `luacheck src tests tools` is clean
- [ ] `busted tests` is green; a change of behaviour comes with a spec
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
- [ ] **Manual.** `src/hue_bridge/www/documentation.html` is updated if a property text,
      a `Last Action` result or an `Attention` line changed.
- [ ] **Status.** `docs/status.md` is updated if what runs or what is open changed.
