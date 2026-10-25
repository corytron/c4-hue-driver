# Composer icons of light and scene devices: research for #60

Research note, 2026-10-25, issue #60. Read-only: this file is the only
change. Snap One documents are paraphrased (quotes are a few words at most);
this is not legal advice. Markers on every claim:

- **[verified: FUND 19/_1]** = `~/c4-tools/reference/docs-driverworks-fundamentals/source/includes/19_driver_icon_management/_1-DRIVERICONMANAGEMENT.md`
  (its screenshots are `source/images/19_1-01.png` to `19_1-05.png`);
  **FUND 6/_1** = `…/6_Understanding .c4z Drivers/_1-OVERVIEW.md`;
  **API x/_y** and **LV2** = `docs-driverworks-api/source/includes/<x>/<_y>.md`
  and `docs-driverworks-proxyprotocol-lightv2/source/includes/` beside it.
- **[verified: XML]** = DriverWorks XML Reference (beta),
  https://snap-one.github.io/docs-driverworks-xml/ (`#common-xml-proxy`,
  `#common-xml-small`, `#common-xml-large`).
- **[verified: SDK path]** = Snap One's public SDK repository,
  https://github.com/snap-one/docs-driverworks (sample drivers, icon
  templates), read from a clone.
- **[verified: HE p.N]** = Composer HE User Guide rev. AB (screenshots of
  Composer HE 3.1.1),
  https://docs.control4.com/docs/product/composer-he/user-guide/latest/composer-he-user-guide-rev-ab.pdf.
- **[verified: GS p.N]** = Composer Pro 3.0 Getting Started (200-00168-T, 2019),
  https://docs.control4.com/docs/product/composer-pro/dealer-getting-started/latest/composer-pro-getting-started-rev-t.pdf.
- **[verified: DUMP]** = a public capture of Director's `/api/v1/items` answer,
  https://github.com/The1TrueJoe/control4-fake-navigator/blob/main/backend/demo/items.json
  (third-party; that it is genuine Director output is **[assumed]**).
- **[verified: house]** = the install observations in `docs/design.md`
  ("Build 125", "Build 135") and `docs/status.md`, Composer Pro 3.4.2.
- **[assumed]** = not documented; an inference from the verified facts or a
  guess, to be probed by §4.

## Answer in brief

Composer's List View does not show a light as an icon tile. It draws every
light_v2 device as a live status tile (name line, level bar) with Composer's
own light picture, which changes with the light's state. The driver's
`large_image` is therefore never used there, for any build, and no
`driver.xml` change can put the dimmer-switch picture on that tile
**[verified 2026-10-25, Composer round 37 on the house: Shine, Golden hours,
Bedside Lights and Master Bedroom Lights are status tiles ("Name:", "Level:"
and a progress bar) whose picture is pixel-identical to the Control4
dimmers' in the same room and matches no file in Composer's
`Images\devices_lg`; the Hue Bridge is a plain icon tile with its own
`hue_bridge_pro_32.png`]**. Recommended change: none; record the
limitation. The likeness icons: keep (§5).

## 1. What each icon declaration does

| Declaration (where we use it) | Composer tree, 16 px | Composer List View, 32 px | Items pane | Navigator |
|---|---|---|---|---|
| `<small image_source="c4z">` in the header (all three drivers) | The bridge's tree icon (the bridge's proxy is the driver itself, `<proxy name="Hue Bridge">hue_bridge</proxy>`) [verified: house]. A proxy device's tree row shows its `<proxy small_image>` instead (third row) [verified: house] | — | FUND 19 names it as the "My Drivers" icon [verified: FUND 19/_1]; on 3.4.2 the search results show a generic placeholder for all three drivers and for Control4's own Hue drivers [verified: house] | not used |
| `<large image_source="c4z">` in the header (all three) | — | The bridge's tile: shown at once, follows updates [verified: house]. For a proxy device it is ignored when `<proxy large_image>` is set [verified: FUND 19/_1] | — | not used |
| `<proxy … image_source="c4z" small_image=…>` (light, scene) | Shown for devices created under a build that declared it (125 or later), and it follows later changes of the file; devices created before keep the light_v2 bulb [verified: house] | — | — | not used |
| `<proxy … large_image=…>` (light, scene) | — | Documented as the List View icon [verified: FUND 19/_1], but never shown for a light or scene: the tile is a status tile (§2) [verified: house for the symptom; assumed for the cause] | — | not used |
| `<proxy name=…>` (all) | the default device name | the default device name | — | the name Navigators show [verified: FUND 19/_1] |
| `<navigator_display_option><display_icons>` (not used) | — | — | — | Navigator pictures (70 to 1024 px, with per-state sets) for Experience Buttons and media drivers [verified: SDK `sample_drivers/uibutton_remote_icons/driver.xml`, `icon_templates/OS3/README.md`; https://github.com/Pulse-Eight/drivers/blob/master/Control4/sky_hd_ip_pulse-eight/driver.xml]; it sits inside `<capabilities>`; nothing documents it for light_v2 [verified: grep of LV2 and the SDK] |
| `<capabilities><UI><Icons><IconGroup>` (not used) | — | — | — | Media Service Proxy pictures [verified: SDK `media_service_proxy/MSP By Numbers/*/driver.xml`] |

Notes:

- Format rules: 16×16 and 32×32 at 96 DPI; with `image_source="c4z"` the
  path is relative to the package's `www/` folder; the `proxybindingid` is
  needed for the right icon; with no custom image the proxy's default icon
  shows [verified: FUND 19/_1]. Director serves `www/` at
  `/driver/<driver file name>/…` [verified: FUND 6/_1]. The XML reference
  documents only `proxybindingid`, `name` and `primary` on `<proxy>`; of
  the references read, only FUND 19 documents the image attributes
  [verified: XML; grep of the API and LV2 docs].
- Our `<proxy>` lines match FUND 19's c4z example and Snap One's 2025
  samples, four of the five of which also set `primary="True"` [verified: SDK
  `sample_drivers/uibutton_remote_icons/driver.xml`,
  `sample_drivers/nonbinding_connections/*.c4z`]. Snap One's training light
  driver declares no images at all [verified: SDK
  `driver_development_training/sample_light_driver/*.c4z`].
- Why the tree icon is "stamped at creation": Director's item data keeps, for
  a proxy device, the proxy's own default pictures plus a copy of the
  driver's `<proxy>` image attributes (`proxyMeta` with `smallSource` /
  `largeSource` `c4z`), and for a combo-style driver its own
  `<small>`/`<large>` [verified: DUMP]. That the copy is taken when the
  device is created and not rewritten by Update Driver fits every house
  observation **[assumed]**; no `driver.xml` change re-stamps the devices
  created before build 125 **[assumed]**, and re-creating them for a 16 px
  icon would cost their bindings and programming.
- Navigator: these are Composer icons only [verified: FUND 19/_1 describes
  them for Composer Pro]; light tiles on Navigators use Navigator's own
  pictures **[assumed; `docs/documentation-plan.md` §6]**. No API call sets a
  device's icon at run time [verified: grep of `docs-driverworks-api` for
  "icon": one example path in API 8_file/_16 only], and the light_v2 proxy has
  no icon capability or command [verified: grep of LV2].

## 2. Why the 32 px tile stays the standard light

**Most likely: the List View draws lights as status tiles with Composer's
own pictures.** Evidence:

1. Both Snap One guides say the List View shows the devices of an area with
   their "current state" [verified: HE pp.34 and 75, GS p.30].
2. Switching a device on or off can bring a "color change on the icon" in
   the Device Control window and in the List View [verified: HE p.76].
3. The HE screenshot (p.75): five lights appear as tiles with a "Name:" line,
   a "Level:" bar and a bulb-and-switch picture with a pale bulb (their bars
   are empty, so presumably off **[assumed]**), while the tree shows the two
   of them in view with a yellow-bulb icon. A media player green-ringed in
   the tree is red-ringed in the list; TV and DVD tiles carry red or green
   state marks. An outlet module and the music services keep their tree
   icon, with no "Name:" line [verified: HE p.75, page image viewed].
4. The GS screenshot (p.30), Composer Pro 3.0: a receiver, its tuner and its
   media sources are "Name:" tiles whose pictures differ from their tree
   icons (tuner: green display in the tree, red radio mast in the list;
   sources: green dot in the tree, red dot in the list); an HDMI matrix, a
   controller and a touch screen keep their tree icon [verified: GS p.30].
5. House: every Hue Light and Hue Scene shows the standard light in the List
   View, including devices whose tree icon is ours, while the Hue Bridge
   shows its own 32 px at once [verified: house]; its proxy type has no
   status tile **[assumed]**.

So the tile picture depends on the proxy type and the device's state, not on
the driver, and a light_v2 driver cannot change it **[assumed until §4]**.
FUND 19 gives the general rule (the large image fills the List View) and
never mentions status tiles [verified: FUND 19/_1]; the rule evidently holds
for plain tiles only **[assumed]**.

The other candidates of #60:

| Candidate | Verdict | Why |
|---|---|---|
| Composer or Director cache | ruled out | Build 135 changed only the PNG files at the same paths (`6eb9b71`), and the bridge's 32 px and the build-125 light's 16 px changed with the update [verified: house, git history] |
| Missing or misspelled attribute | ruled out as far as the documents go | The `<proxy>` matches FUND 19's c4z form and Snap One's samples, `primary="True"` aside (§3) [verified: FUND 19/_1, SDK] |
| Size, DPI, format or path | ruled out | All six PNGs are 32×32 or 16×16 RGBA with a 96 DPI `pHYs` chunk (3780 px/m), packed at `www/images/devices_lg/…` in build 258; the bridge's 32 px of identical format shows, and the 16 px from the same light package shows [verified: PNG chunks read, `unzip -l build/hue_light.c4z`] |
| Proxy image versus driver image | real, not decisive | Director keeps the proxy's default pictures beside the driver's `<proxy>` attributes [verified: DUMP]; a view that read the proxy's own field would show the light_v2 default, but a status tile uses neither **[assumed]** |

Not checked: the newer date-versioned Composer Pro releases (OS 4.x).

## 3. `driver.xml` changes to try, ranked

1. **None (recommended).** Record the limitation (§6). No build, no reboot.
2. **Only if §4 finds a plain tile** (icon and name, no "Name:"/"Level:"):
   add `primary="True"`, as most of Snap One's 2025 samples do [verified:
   SDK; XML documents `primary`]. `src/hue_light/driver.xml`:

   ```xml
   <proxy proxybindingid="5001" name="Hue Light" primary="True" image_source="c4z" small_image="images/devices_sm/hue_light_16.png" large_image="images/devices_lg/hue_light_32.png">light_v2</proxy>
   ```

   and the same attribute in `src/hue_scene/driver.xml` (`name="Hue Scene"`,
   `hue_scene_16.png`, `hue_scene_32.png`). Inside `<proxies>`, **not a
   `<capabilities>` change**: no controller reboot expected **[assumed]**; if
   Composer asks "Restart Director?" anyway, `docs/composer-remote.md` rule
   10 applies. Judge it on a device created after the install, since existing
   devices keep what they got at creation **[assumed]**.
3. **Then, still only for a plain tile:** add the undocumented attributes
   `smimagepath="images/devices_sm/hue_light_16.png"
   lgimagepath="images/devices_lg/hue_light_32.png"` (scene: its own files).
   No Snap One document or sample has them; some third-party drivers do
   [verified: the Pulse-Eight URL in §1; https://github.com/Greg-MM/C4-AndroidTV,
   https://github.com/Leighm0/Tesla-Home-Charger]. **Not a `<capabilities>`
   change**; harmless if ignored **[assumed]**; same new-device test.

Not worth trying for #60: `navigator_display_option` (Navigator, not
Composer; a `<capabilities>` change, so a reboot); MSP `<UI><Icons>`
(media_service only); a different proxy type for lights or scenes (they must
stay light_v2 for dimming, keypads and Advanced Lighting Scenes).

## 4. Composer check for the Windows session

Read-only: no Update Driver, no project change, no light switched.

1. System Design: select a room that holds at least one Hue Light (one on
   and one off, if the house offers that) and, if possible, a Hue Scene;
   then the Hue Bridge's room. Open the centre pane's **List View** header
   (top right; Composer often lands there after an update,
   `docs/composer-remote.md` rule 12; it is not in `Select-ComposerTab`'s
   offset table, so locate it on a screenshot).
2. Read the pane: `Get-ComposerTree -Root <List View pane>` (or
   `Find-ComposerElements` under it). Report each tile's texts: a status
   tile has `Name:` and `Level:` and a level bar; a plain tile only the name.
3. `Save-ElementShot` (or `Save-RegionShot`) of the tiles of a Hue Light
   that is on, one that is off, a Hue Scene and the Hue Bridge, plus the
   same devices' 16 px tree rows, under `C:\c4-hue\shots\`.
4. Optional, one line each: list `*light*` pictures in Composer's install
   folder `Images\devices_lg` (the built-in light pictures); search the
   Windows profile and ProgramData for `hue_light_32.png` and
   `hue_bridge_pro_32.png` (which large images Composer stored, if it caches
   at all).

Reading: Hue tiles with `Name:`/`Level:` (and a bulb that differs between
on and off) confirm §2: record the limitation, close the icon half of #60. A
plain tile with the standard bulb sends us to §3 items 2 and 3. If the pane
is inconclusive, a dev build could print the stored item data of one Hue
Light with `C4:GetProjectItems` (API 22_miscellaneous/_17: the project as
XML, with DEVICES and PROXIES filters); that needs a dev-only action.

## 5. Trade dress (the likeness icons)

`docs/licensing-research.md` §1 (icons row) and §3: the icons are original
renderings with no logo or text, but their shapes are a Hue dimmer switch
and the Hue Bridge Pro from above; Signify's Hue terms §8(a)(xi) forbid Hue
"branding, trademarks or trade dress" in any logo or graphics; the note
judges 16/32 px silhouettes of a white rocker and a black slab "a stretch
for trade dress", low risk **[assumed]**, and recommends keeping them at the
lowest priority. Its §6 leaves the decision to the owner (step 1) and says
to redraw rather than argue if Signify or Snap One objects (step 11).

**Recommendation: keep.** They are logo-free device pictures of the kind
Snap One's icon guidance asks for (the device's recognisable shape and
colours [verified: SDK `icon_templates/OS3/README.md`]), Composer is the
only place that shows them (the light and scene ones, after §2, only as
16 px tree icons), and the non-affiliation notices plus the
redraw-on-objection rule cover what risk is left.

## 6. Suggested wording for the coordinator

For `docs/documentation-plan.md` §6, `docs/status.md` and the README's open
items, once §4 confirms: "A light or scene device's List View tile is
Composer's status tile for light_v2 (name, level bar, Composer's own light
picture that follows the state); a driver cannot set it. The 32 px light and
scene icons stay in the packages, unused there (`docs/icons-research.md`)."
