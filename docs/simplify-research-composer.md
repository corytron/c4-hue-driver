# What Composer Pro and DriverWorks allow: the platform under a simpler driver (#334)

Research for `docs/simplify-actions-design.md` (section 0), agent "composer",
2026-11-04. Read-only research; nothing in `src/` changes. The question: which
of the simplifications the other researchers may propose can actually be
built in Composer Pro and DriverWorks, on OS 3.x and 4.x.

Sources and how they are cited:

- **API**, **FUND**, **XML**, **PP**: the Snap One DriverWorks API reference,
  Fundamentals, driver XML reference and proxy-protocol reference under
  `~/c4-tools/reference/docs-driverworks-{api,fundamentals,xml,proxyprotocol}/source/includes/`,
  cited by section folder and file (for example `API 24_properties/_4-SetPropertyAttribs.md`).
  Read only; nothing is quoted at length.
- **LIB**: Snap One's helper libraries, `~/c4-tools/drivers-common-public/`
  (read only, never vendored).
- **Repo**: `path:line` in this repository. Hardware facts come from
  `docs/design.md`, `docs/composer-remote.md`, `docs/composer-checklist.md`
  and `docs/status.md`: the house (Composer Pro 3.4.2, OS 3.4.2/3.4.3, Hue
  Bridge Pro) and the outside tester (issue #309: Composer Pro 2025.11.26,
  OS 3.4.3, Hue Bridge v2).
- **Web**: Control4's public help and release notes, by URL.

Every row says **verified** (seen in the docs, the code, a spec or a hardware
report) or **assumed** (our reading, not seen). "Silent" means the docs say
nothing.

## 1. Findings

1. **The Actions tab is static.** It is exactly the `<actions>` of
   `driver.xml`, a flat list ordered only by `<sort_order>` (OS 3.3.0+). There
   is no grouping, separator, description, runtime hide/show/rename, built-in
   confirmation or return value for an action. The only way to change the
   list is a driver update. Fewer actions means fewer `<action>` elements;
   anything "dynamic" has to live in a parameter dialog or on the Properties
   tab.
2. **The parameter dialog is the richest UI Composer gives a driver.** A
   `CUSTOM_SELECT` parameter is a list the driver builds at the moment the
   installer opens it, with display text and a hidden value, optional
   folders, an asynchronous fill and an error message. One action with a
   "what" picker can therefore replace several actions (MERGE). Its limits:
   a picker cannot see what the other parameter holds (assumed), folders,
   search and filter are only documented as reliable from OS 4.0, and the
   dialog remembers each action's last values.
3. **The Properties tab is the only surface the driver can change at
   runtime**, after `OnDriverLateInit`: `C4:UpdateProperty` (text),
   `C4:UpdatePropertyList` (the items of a `DYNAMIC_LIST`) and
   `C4:SetPropertyAttribs` (hide or show a row). A `DYNAMIC_LIST` whose items
   are the driver's current offers works as a one-click "accept" menu: the
   installer picks an item and presses the row's **Set**, `OnPropertyChanged`
   runs, and the driver resets the row. That is the one way to get actions
   that come and go with the system's state.
4. **Results only come back through properties.** An action cannot answer
   the installer. Status, Attention and Last Action (word-wrapped onto six
   rows, because Composer shows about 75 characters of a value) are the
   feedback, plus `print` lines that only appear while that device's Lua tab
   is open.
5. **Devices: create and rename yes, delete and move no.** `C4:AddDevice`
   (3.2.0+) and `C4:Bind` create and connect a device in a chosen room under
   a chosen name. `C4:RenameDevice` renames, and each call refreshes the
   whole project. There is **no API to delete a device or move it to another
   room**. The API reference reserves `AddDevice` for actions the dealer or
   user started, so automatic creation goes against the documented contract.
   Creation stays one click (OFFERED); deletion stays with the installer.
6. **No Composer-level discovery for Hue.** Control4's discovery (SDDP)
   serves devices that announce themselves, and a Hue bridge does not
   (assumed). A driver can still search in Lua: the cloud discovery endpoint
   over `C4:url`, or multicast UDP the way Snap One's own SSDP module does.
   That makes "find the bridge again after an IP change" a buildable
   background task. There is nothing in the Composer UI to hook it to.
7. **No custom setup pages.** The Documentation tab is a static HTML page
   from the `.c4z` shown in a browser control, with no documented way to
   call into the driver. A wizard has to be built from properties (rows
   shown one after another with `SetPropertyAttribs`) and action dialogs.
8. **Background tasks are fully supported, with care.** `C4:SetTimer` (one
   shot or repeating, with a count of skipped runs) and `C4:PersistSetValue`
   are enough for a scheduler. All timers die with the driver (update,
   Director restart, delete), so the next due time must be persisted and
   recomputed at late init. `OnDriverLateInit(DIT)` says whether the driver
   was added, restarted or updated (3.2.0+); the bridge ignores that
   argument today.
9. **Updating in place may remove or rename actions safely.** Programming
   never refers to an action; only commands, events, variables and
   conditionals are part of programming. Properties may be added or removed
   (not retyped). Proxies and connections must not change, and a change to
   `<capabilities>` needs a controller reboot.
10. **Composer generations behave the same for us.** Composer Pro 3.1+ talks
    to Director through a versioned API, and from X4 (OS 4.1) Composer Pro
    is released on its own with date-based version numbers. The tester ran
    our actions, properties and Lua output on Composer Pro 2025.11.26 with OS
    3.4.3. OS 4.x adds nothing this redesign needs (dynamic programming
    commands from 4.1, runtime `hide_proxy_properties` from 4.2.1).

## 2. Evidence

### A. The Actions tab

| Capability | Possible? | Evidence | OS 3.x | OS 4.x | Verified or assumed |
| --- | --- | --- | --- | --- | --- |
| Actions come only from `driver.xml` `<actions>` | yes, static | XML `30_actions/_5-actions.md`; FUND `15_composerpro_interface_into_the_sdk/_6-ACTIONS.md`; `src/hue_bridge/driver.xml:234` | yes | yes | verified (docs, house) |
| A click reaches `ExecuteCommand("LUA_ACTION", {ACTION = <command>, …params})` | yes | `src/common/dispatch.lua:35`; API `5_director_command/_1-ExecuteCommand.md`; Room Audit click from Composer (`docs/design.md:1126`) | yes | yes | verified |
| The shown name differs from the command string | yes | `src/hue_motion/driver.xml:139` ("Test: Motion" sends `Test Motion`); XML `30_actions/_20-command.md` | yes | yes | verified |
| Order the list | `<sort_order>`, every action or none; a repeated number hides the later action | FUND `15_…/_6-ACTIONS.md`; XML `30_actions/_45-sortorder.md`; without it Composer 3.4.2 listed actions in reverse XML order (`docs/design.md:1120`) | 3.3.0+ | yes | verified |
| Groups, separators, headers in the list | no element exists; only naming conventions ("Test: …") | XML `30_actions/` defines only name, command, params, sort_order | no | no | verified (absence in docs) |
| Description or tooltip per action | no | same | no | no | verified (absence) |
| Show, hide or rename an action at runtime | no API (`SetPropertyAttribs` is for properties) | searched API, FUND and XML; no action counterpart | no | no | verified absence; assumed impossible |
| Parameters per action | STRING (password option), LIST, RANGED_INTEGER/FLOAT, COLOR_SELECTOR, DEVICE_SELECTOR, VARIABLE_SELECTOR, DYNAMIC_LIST, CUSTOM_SELECT; default, min, max | XML `30_actions/_40-paramtype.md`, `_50-paramdefault.md`, `_70-variabletype.md`; FUND `15_…/_6-ACTIONS.md` | yes | yes | verified (docs); CUSTOM_SELECT verified on the house |
| The dialog | modal "Action Parameter List", one row per parameter, OK disabled until a pick; remembers each action's last values | `docs/design.md:1110`, `docs/design.md:1187`; `docs/composer-remote.md:133` | yes (3.4.2) | assumed same | verified |
| CUSTOM_SELECT text/value pairs | yes | FUND `15_…/_4-CUSTOMSELECTPROPERTY.md`; `src/hue_bridge/driver.lua:1525` | yes | yes | verified (house) |
| CUSTOM_SELECT folders with a Back entry, async fill (`done` callback), an error string shown by Composer | yes | FUND `15_…/_4-CUSTOMSELECTPROPERTY.md`; FUND `12.3_custom_select_implementation/_5-CUSTOMSELECTFOLDER.md`, `_6-CUSTOMSELECTASYNCHAll.md` | documented, not tried | yes | assumed on 3.x |
| CUSTOM_SELECT search box and filter | yes | FUND `12.3_…/_1-Overview.md` (consistent only from OS 4.0), `_3-CUSTOMSELECTSEARCH.md` | inconsistent | 4.0+ | verified (docs) |
| Several items picked at once in a CUSTOM_SELECT | the XML example says so | XML `30_actions/_40-paramtype.md` | not seen | not seen | assumed |
| A picker sees the other parameter's current value | not documented: the list function gets its own folder path or search text only | FUND `15_…/_4`, `12.3_…/_3` | no | no | assumed impossible |
| Confirmation before a destructive action | no element; any action with parameters already opens an OK/Cancel modal, and a LIST parameter ("No" / "Yes, forget") makes the driver refuse unless confirmed | XML `30_actions/_40-paramtype.md`; dialog as above | yes | yes | mechanism verified; UX assumed |
| An action returns a result to the installer | no; Snap One's own sample writes the result into a property | FUND `12.3_…/_3-CUSTOMSELECTSEARCH.md`; our Last Action, `src/hue_bridge/driver.lua:1462` | n/a | n/a | verified |
| Limit on the number of actions | none documented (events: 1000 per driver) | FUND `15_…/_7-PROGRAMMING.md` | silent | silent | assumed none |
| Actions vs commands vs properties | actions: Composer-time configuration only; `<commands>`: device-specific commands in Programming, kept forever once dealers use them; properties: persisted values, `OnPropertyChanged` on a user's Set | FUND `15_…/_6-ACTIONS.md`, `15_…/_7-PROGRAMMING.md`, `9_commands/_1-COMMANDS.md`, `14_updating_released_drivers/_2-DRIVERUPDATECONSIDERATIONS.md`; API `24_properties/_3-OnPropertyChanged.md` | yes | yes | verified |

What follows for design:

- Fewer actions is purely a `driver.xml` decision. A family of actions can
  become **one action with a "what" picker** (Add, Re-link, Forget,
  Diagnostics). The picker's values encode kind and id (`light:<rid>`,
  `all:lights`), and the handler refuses a mismatch with a Last Action text,
  since the second picker cannot be filtered by the first.
- Keep `sort_order` on every action and unique: a duplicate silently hides
  an action, and one missing value unsorts the whole list. A spec should
  assert it (today only the light's commands are checked,
  `tests/spec/light_relative_level_spec.lua:176`).
- A destructive action gets a LIST "Confirm" parameter rather than relying
  on the modal alone.

### B. Properties as controls

| Capability | Possible? | Evidence | OS 3.x | OS 4.x | Verified or assumed |
| --- | --- | --- | --- | --- | --- |
| LIST property as a one-shot button: pick, Set, `OnPropertyChanged`, then the driver resets it with `UpdateProperty` (which does not fire again) | yes | API `24_properties/_3-OnPropertyChanged.md`; Set is required (`docs/composer-remote.md:97`, `docs/design.md:1163`); `Debug Mode` and `Recall As` set this way on the house | yes | yes | mechanics verified; as a "button" assumed |
| DYNAMIC_LIST items set at runtime | `C4:UpdatePropertyList(name, "a,b,c", value)`; the value parameter exists from OS 3; items are not persisted, so they are rebuilt at late init | API `24_properties/_6-UpdatePropertyList.md`; FUND `15_…/_2-DYNAMICLISTPROPERTIES.md`; `src/hue_bridge/driver.lua:139`, `src/hue_bridge/driver.lua:630` | yes | yes | verified (house: Lights, Scenes, Zone Lights, Motion Sensors, Room Mappings) |
| A pick in a DYNAMIC_LIST fires `OnPropertyChanged` with the item's text | yes | FUND `15_…/_2`; today's rows snap back (`src/hue_bridge/driver.lua:1491`) | yes | yes | verified |
| DYNAMIC_LIST as a menu of current offers (items appear and disappear with the state) | buildable from the two rows above; items are plain text, so the driver keeps a text → id map | API `24_properties/_6` (comma list, no values); `docs/edge-cases-control4.md` §6.1 | yes | yes | assumed (not built yet) |
| A read-only list | renders as a disabled combo that cannot be opened, so lists stay editable | `docs/composer-remote.md:245`; `docs/status.md:116` | yes | assumed same | verified |
| Commas in list items | the list is comma-delimited; escaping is silent, so the driver replaces "," by "‚" | API `24_properties/_6`; `src/hue_bridge/driver.lua:624` | yes | yes | verified |
| Length of a value | about 75 characters on one line, the rest clipped | `docs/design.md:1035`; `docs/list-rows-design.md` §2 | yes | assumed same | verified |
| Multi-line text in one row | no; long texts go to Last Action plus rows (2)–(6), wrapped at 72, unused rows hidden | `src/hue_bridge/driver.xml:96`; `src/hue_bridge/driver.lua:1428` | n/a | n/a | verified |
| Hide or show a row at runtime | `C4:SetPropertyAttribs(name, 1)` hides, `0` shows; not in `OnDriverInit`; Composer drops attribute changes that arrive in the same burst as text updates, so they go out 400 ms and 1.5 s later | API `24_properties/_4-SetPropertyAttribs.md`; LIB `global/handlers.lua:583`; `src/hue_bridge/driver.lua:1449`; `docs/status.md:115` | 1.6.0+ | yes | verified |
| Make a row read-only or editable at runtime | no API | API `24_properties/` | no | no | silent; assumed impossible |
| Change a tooltip or description at runtime | no API; both are static XML (`<tooltip>` in use at `src/hue_bridge/driver.xml:145`) | FUND `15_…/_1-PROPERTIES.md` | no | no | verified (static), runtime silent |
| `UpdateProperty` on an undeclared name | returns nil, nothing logged | `docs/design.md:879` | yes | assumed | verified |
| Live refresh | texts change while the device is shown (the Last Action rows); a hidden or shown row may need the device re-selected; the Documentation tab may show the previous build until re-selected; Update Driver reloads the whole view | `docs/smart-scenes-research.md:405`; `src/hue_bridge/www/documentation.html:154`; `docs/composer-remote.md:126` | yes | assumed same | verified |
| Row order | `driver.xml` order; LABEL rows give headers or blank spacers (OS 2.10+) | FUND `15_…/_3-ADVANCEDPROPERTIES.md`; the manual describes the house's rows in XML order (`src/hue_bridge/www/documentation.html:966`) | yes | yes | verified (docs and pages) |
| Size of a dynamic list | undocumented; the bridge's Scenes list carries every scene (about 145 lines on the house) | API `24_properties/_6`; `src/hue_bridge/bridge/scenes.lua:2455` | silent | silent | assumed (not read back in full) |
| Other property types | DEVICE_SELECTOR (multiselect), LINK, SCROLL, TRACK, COLOR_SELECTOR, LABEL | FUND `15_…/_1`, `15_…/_3`; XML `20_properties/_20-type.md`, `_55-multiselect.md` | yes | yes | documented; unused by us |
| Accidental change | the mouse wheel steps a drop-down; nothing reaches Director before Set | `docs/composer-remote.md:142`, `docs/composer-remote.md:97` | yes | assumed | verified |

What follows for design:

- **One "Suggestions" row** (a DYNAMIC_LIST, hidden while empty) can carry
  every OFFERED item ("Add 3 new lights to their mapped rooms", "Re-link
  Hallway Lamp to the new bulb #53"). Pick plus Set is the one click; the
  driver resets the row and reports in Last Action. It costs three clicks
  (open, pick, Set), no fewer than an action, but it shows only what applies
  now, next to the status that explains it.
- A setting is a LIST or RANGED_INTEGER property with a handler, as Debug
  Mode and Stream Watchdog (s) are today. Turning an on/off pair of actions
  into one setting is cheap and safe.
- Hiding works, but every hide or show has to be sent apart from the text
  updates (the Last Action pattern). Prefer few rows that are always shown.

### C. Device creation and removal

| Capability | Possible? | Evidence | OS 3.x | OS 4.x | Verified or assumed |
| --- | --- | --- | --- | --- | --- |
| Create a device | `C4:AddDevice(driver, room, name, callback)`; the callback gets the new id, or 0 on failure | API `9_helper/_0.1-AddDevice.md`; `src/hue_bridge/bridge/owner.lua:223` | 3.2.0+ | yes | verified (47 lights on the house, `docs/design.md:812`) |
| Create without a click | the API reference says creation should only follow a dealer's or user's action, against recursive adds | API `9_helper/_0.1-AddDevice.md` | against the docs | against the docs | verified (docs) |
| Connect it | `C4:Bind(provider, binding, consumer, binding, class)` | `src/hue_bridge/bridge/owner.lua:226`; `docs/edge-cases-control4.md` §0 | 2.9.0+ | yes | verified |
| Bulk creation | one AddDevice at a time, the next from the previous callback | `src/hue_bridge/bridge/owner.lua:1083` | yes | yes | verified |
| What Composer shows | the device in the chosen room with the given name; the proxy's small icon is stamped at creation | `docs/design.md:1229` | yes | assumed | verified |
| Rename | `C4:RenameDevice(proxy or device id, name)`, late init on; each call refreshes the project | API `22_miscellaneous/_32-RenameDevice.md`; `src/hue_bridge/bridge/project.lua:37` | yes | yes | verified |
| Delete a device | no API; the driver unbinds (`C4:Unbind`) and asks the installer to delete it | no such call in API, FUND or XML; `docs/design.md:1040` | no | no | verified absence |
| Move a device to another room | no API; the room is chosen only at AddDevice. Reading another device's room: `C4:GetDevices` (2.10+), `C4:GetRoomID` (4.1+) | API `9_helper/_9.5-getroomid.md`; `docs/design.md:855` | read only | read only | verified |
| Create a room | `C4:AddLocation`, documented for user-started use like AddDevice | API `9_helper/_0.2-AddLocation.md` | 3.2.0+ | yes | documented; unused |
| Learn of a Composer delete or rename | child's `OnDriverRemovedFromProject`; registered system events `OnItemRemoved`, `OnItemNameChanged`; `OnBindingChanged` | `src/hue_bridge/driver.lua:2180`, `src/hue_bridge/driver.lua:2197`; `docs/design.md:1134`, `docs/design.md:1145` | yes | yes | verified |
| Survive save, load, restore | `PersistData` is in the project file; whether the `PersistSetValue` store is in a backup is silent; ids come from the saved project | FUND `24_persisting_driver_data/_1-PERSISTINGDRIVERDATA.md`; `docs/edge-cases-control4.md:230` | assumed | assumed | assumed |
| Nest the devices under the bridge in the tree | capabilities `nesting_driver_is_parent` / `nested_driver_is_child` and two variables; static capability | PP `63_light_v2_capabilities/_39-nestingdriverisparent.md`, `_40-nesteddriverischild.md` | 3.4.2+ only | yes | documented; effect assumed |
| Auto-bind a hand-added device | `<autobind>` on the consumer class | XML `50_connections_xml/_71-autobind.md`; a change to a connection's definition is discouraged in updates (FUND `14_…/_2`) | yes | yes | documented; unused |

What follows for design:

- **Device creation stays one click.** Background tasks may find new
  resources, map rooms and pre-compute the offer; the click (an action or a
  Suggestions pick) starts the AddDevice chain. The chain may then run from
  callbacks, as Import All New Lights does today.
- Nothing can delete or move a device. A background task can only report,
  unbind (Forget) and say "delete this device in Composer"; the room
  mapping stays a creation-time default.
- Bulk renames (Adopt Hue Names) refresh the project once per device, so
  they stay a deliberate click.

### D. Discovery and auto-binding

| Capability | Possible? | Evidence | OS 3.x | OS 4.x | Verified or assumed |
| --- | --- | --- | --- | --- | --- |
| Control4 discovery (SDDP, Composer's discovered devices) for a third-party driver | only for devices that announce SDDP; `C4:GetDiscoveryInfo(binding)` and system events 78/79 | API `32_serial_network_device/_8-GetDiscoveryInfo.md`; LIB `global/handlers.lua` event list | yes | yes | verified (docs) |
| The Hue bridge announces SDDP | no sign of it | `docs/design.md:1314` | no | no | assumed |
| SSDP | Signify disabled it on bridges in 2022 | `docs/design.md:1313` | n/a | n/a | verified (Hue guidance cited there) |
| Multicast UDP search from Lua (mDNS `_hue._tcp`) | Snap One's SSDP client opens a multicast UDP network connection, so mDNS can be done the same way | LIB `module/ssdp.lua` (CreateNetworkConnection, NetConnect UDP, SendToNetwork); `docs/design.md:1306` | yes | yes | pattern verified; mDNS assumed |
| Hue cloud discovery endpoint | `C4:url` GET, one request per 15 minutes | `docs/design.md:1290` | yes | yes | verified (Hue guidance) |
| `<search_types>` | text for Composer's driver search, not network discovery | XML `15_common_xml/_21_searchtypes.md` | n/a | n/a | verified |
| New discovery API for drivers on 4.x | none in What's New 4.0 to 4.2 | API `3_whats_new/_5…`, `_6…`, `_7…` | n/a | none | verified absence |

What follows for design: discovery is a driver-internal background task
(find the stored bridge id at a new address when the old one stops
answering), shown in Status. Nothing in Composer can list or add a Hue
bridge for us; the installer still adds the Hue Bridge driver by hand.

### E. Setup UI beyond properties and actions

| Capability | Possible? | Evidence | OS 3.x | OS 4.x | Verified or assumed |
| --- | --- | --- | --- | --- | --- |
| A custom configuration page or wizard window | no; a device has Properties, Actions, Documentation and Lua tabs | `docs/design.md:1229` (tab strip) | no | no | verified (absence) |
| Documentation tab | static HTML from the `.c4z` in a browser control: images, in-page links, back/forward; one page per build | XML `15_common_xml/_70-documentation.md`; `docs/design.md:1229` | yes | yes | verified |
| JavaScript in it | Snap One's own Markdown manuals render through React, so scripts run; no documented way back into the driver | FUND `26_markdown_driver_documentation/_0-Header.md` | yes | yes | scripts verified (docs); a channel to the driver assumed absent |
| A page served by the driver (`C4:CreateServer`) and linked from a LINK property | technically plausible | API `33_server_sockets/_2-CreateServer.md`; FUND `15_…/_1` (LINK) | untested | untested | assumed; not recommended |
| A wizard on the Properties tab: the next row appears when a step is done | yes, with `SetPropertyAttribs` | API `24_properties/_4`; Last Action rows | yes | yes | mechanism verified; flow assumed |
| A wizard inside one dialog: CUSTOM_SELECT folders | yes | FUND `15_…/_4` | assumed | yes | assumed on 3.x |
| Lua command window | only in builds packaged with allow-execute; the output pane shows only lines written while the tab is open | FUND `6_Understanding .c4z Drivers/_3-C4ALLOWEXECUTE.md`; `tools/build.sh:40`; `docs/composer-remote.md:130` | yes | yes | verified |

What follows for design: the "Apple-like" surface is the Properties tab
read from top to bottom (Status, Attention, a Suggestions row, then
settings) plus a handful of actions. The Documentation tab can explain but
not act. An HTTP setup page would add an unauthenticated listener on the
controller, for a UI Composer may not even open; it is not worth it.

### F. Timers and persistence for background tasks

| Capability | Possible? | Evidence | OS 3.x | OS 4.x | Verified or assumed |
| --- | --- | --- | --- | --- | --- |
| Timers | `C4:SetTimer(ms > 0, fn, repeat)`, returns an object with `Cancel()`; a repeating callback gets the number of skipped runs; not in `OnDriverInit` | API `34_timer/_1-SetTimer.md` | 2.7.0+ | yes | verified |
| Long intervals | no maximum documented; Director may serve a timer late or skip it. In production: a 300 s repeating timer (`src/hue_bridge/driver.lua:2293`), 600 s watchdogs and the 10-minute diagnostic capture | API `34_timer/_1`; `src/hue_bridge/bridge/motion_diag.lua:125` | ≤ 600 s seen | assumed | verified to 600 s; longer assumed |
| Timers across restart, update or delete | all killed at `OnDriverDestroyed`; re-armed at late init | API `22_miscellaneous/_24-OnDriverDestroyed.md`; `src/hue_bridge/driver.lua:2331` | yes | yes | verified |
| Wall clock | `os.time()`; `C4:GetTime()` milliseconds since the epoch (3.2.3+; units argument 4.0+) | API `34_timer/_2-GetTime.md` | yes | yes | verified |
| Persistent state | `C4:PersistSetValue/GetValue` (tables allowed, optional encryption), written by its own thread; a read right after a write may miss it; spurious writes delay Director's flush | API `26.5_persistence/_3-PersistGetValue.md`, `_4-PersistSetValue.md`; FUND `24_…/_1` | 2.10.0+ | yes | verified |
| Size limits of persisted values | none documented; the registries of 47 lights and the scene, zone and motion registries persist on the house | `src/hue_bridge/bridge/registry.lua:300` | silent | silent | assumed |
| Added, restarted or updated? | `OnDriverInit/LateInit(DIT)` with `DIT_ADDING`, `DIT_STARTUP`, `DIT_UPDATING`; `OnDriverDestroyed(DIT_UPDATING or DIT_LOADED)`; the bridge's `OnDriverLateInit()` takes no argument today | API `22_miscellaneous/_25-OnDriverInit.md`, `_25.1-OnDriverLateInit.md`; FUND `28_api_specific_info/_3-DRIVERINIANDDESTRUCT.md`; `src/hue_bridge/driver.lua:2265` | 3.2.0+ | yes | verified |
| A new build or a new OS | persisted version compared with `C4:GetDriverConfigInfo("version")` (empty at a new device's first init, so the build stamp is the fallback) or `C4:GetVersionInfo()` | `src/hue_bridge/driver.lua:1165`; `src/hue_bridge/bridge/tlscheck.lua:70` | yes | yes | verified |
| A task that runs once | a persisted marker, as the one-time Map Rooms By Name | `src/hue_bridge/bridge/lights.lua:922` | yes | yes | verified |
| Errors in a background task | handlers run under `pcall` and log; a line reaches Composer only in the Lua tab while open, and Director's own log; nothing on the Properties tab unless the driver writes it | `src/common/dispatch.lua:22`; `docs/composer-remote.md:130`; FUND `16_sysman_logging/_1-INTRO.md` | yes | yes | verified; Director log for uncaught errors assumed |
| Control4's Scheduler agent (`C4Scheduler`) | creates events in the project's Scheduler for programming, visible to the installer; not a driver timer | API `27_scheduler_agent/_1-Overview.md` | OS 3+ | yes | verified (docs); unsuitable |

What follows for design: one scheduler with a short tick (the existing
five-minute timer is a natural host) and persisted next-due times, rather
than hour-long timers, survives restarts and updates and tolerates late
timers. Every task writes its outcome to a property, because errors are
otherwise invisible unless someone has the Lua tab open. `DIT_UPDATING` is
the hook for "after an update, run the catch-up tasks once".

### G. Composer and OS generations

| Capability | Possible? | Evidence | OS 3.x | OS 4.x | Verified or assumed |
| --- | --- | --- | --- | --- | --- |
| One Composer manages several OS versions | Composer Pro 3.1+ uses a versioned API to Director; DriverWorks drivers are OS-version independent | https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/composer_pro_version_independence.htm | yes | yes | verified (web) |
| Date-versioned Composer Pro | Composer Pro decoupled from the OS from X4 (OS 4.1), date-based numbering | X4 (OS 4.1) release notes, https://docs.control4.com/docs/product/control4-software/dealer-release-notes/english/latest/control4-software-release-notes-rev-aw.pdf | n/a | 4.1+ | verified (web) |
| Our drivers under a date-versioned Composer | the tester added devices from the Actions tab, read the rows and pasted Lua output on Composer Pro 2025.11.26, OS 3.4.3 | issue #309 | yes | not tested | verified |
| Differences between Composer generations for properties, actions, Documentation tab | none documented | the two pages above | silent | silent | assumed the same |
| OS 4.x additions near this topic | `GetProtocolDeviceById`, `GetBoundPartner` (4.0); dynamic commands and conditionals, `GetRoomID` (4.1); `GetDriverConfigInfoById` (4.2); runtime `hide_proxy_properties` (4.2.1); CUSTOM_SELECT search and filter reliable (4.0) | API `3_whats_new/_5-WhatsNewin420.md`, `_6-WhatsNewin410.md`, `_7-WhatsNewin400.md`; FUND `12.3_…/_1`; `docs/design.md:791` | no | yes | verified (docs) |
| OS 3.4.2 additions | device nesting capabilities | PP `63_light_v2_capabilities/_39…` | 3.4.2+ | yes | verified (docs) |

What follows for design: build only on what 3.3.0 (the declared minimum,
`src/hue_bridge/driver.xml:16`) offers; treat folders and search in
CUSTOM_SELECT as a nicety that must not be required on 3.x. Nothing in the
date-versioned Composer changes the plan.

### H. Driver updates in place

| Capability | Possible? | Evidence | OS 3.x | OS 4.x | Verified or assumed |
| --- | --- | --- | --- | --- | --- |
| The Actions tab follows the new `driver.xml` | yes: actions added in an update appear, removed ones vanish (the dev-only actions came and went between dev and release builds) | `docs/composer-checklist.md:260`; `docs/design.md:1192` | yes | assumed | verified |
| Programming refers to an action | no: programming uses commands, events, variables and conditionals; the update guidance never lists actions | FUND `15_…/_6`, `15_…/_7-PROGRAMMING.md`, `14_updating_released_drivers/_2-DRIVERUPDATECONSIDERATIONS.md`; the #325 rename (`docs/list-rows-design.md` §1) | n/a | n/a | verified (docs, precedent) |
| Other drivers refer to an action | ours exchange `HUE_*` commands, never action names; the handler is keyed by the command string, so a handler can outlive its `<action>` (dev loop, specs) | `src/common/dispatch.lua:35`; `src/common/devloop.lua:868` | n/a | n/a | verified (code); tools and briefs: the compat research |
| Property values | survive updates; properties may be added and removed, not retyped; removed rows disappear (Dev Server, Diagnostic Server) | FUND `14_…/_2`; `docs/composer-checklist.md:87` | yes | yes | verified |
| A renamed property | a removal plus an addition: the old value is lost | FUND `14_…/_2` | assumed | assumed | assumed |
| Proxies, connections, capabilities | never add or remove a proxy; connections only added; a capability change needs a controller reboot | FUND `14_…/_2`; `docs/composer-remote.md:113` | yes | yes | verified |
| Remembered parameter values | kept per action by Composer; a renamed action starts empty | `docs/design.md:1187` | assumed | assumed | assumed harmless |
| Persisted store and pairing | kept by an update in place; lost by delete and re-add | `docs/edge-cases-control4.md` §0 | yes | yes | verified |

What follows for design: the action list can be cut and renamed in one
release without touching programming. Keep the old command strings as
handlers (aliases) for a release, so the dev loop, the specs and any
Windows-session brief keep working.

## 3. Verdicts (what the platform permits, and the recommendation)

The other researchers own the final word per family; this is the platform's
view. "Add Devices", "Re-link Device", "Forget Device" and "Diagnostics" are
merged actions with a "what" picker (section A); "Suggestions" is the offer
row (section B).

| Action | Verdict | Reason (platform) |
| --- | --- | --- |
| Pair Bridge | KEEP | The link button is physical; a two-minute automatic attempt after the IP is Set is buildable with `SetTimer`, so the click becomes the fallback. |
| Test Connection | MOVE to diagnostics | Status already carries the background identity check; a Diagnostics action with a LIST "what" keeps it. |
| Connection Test | MOVE to diagnostics | Already dev-only (stripped by `tools/build.sh:115`). |
| Connect Event Stream | SETTING | One LIST property "Event Stream" On/Off (default On), with a handler like Event Stream Transport's. |
| Disconnect Event Stream | SETTING | Same property; Off is the troubleshooting step the tester used. |
| Reload Credentials | MOVE to diagnostics | Dev-only today. |
| Check CA Pinning | MOVE to diagnostics | Dev-only today. |
| Forget Pairing | MERGE into Diagnostics | Rare and destructive: a "what" entry plus a LIST "Confirm" parameter. |
| Add Light | MERGE into Add Devices | One CUSTOM_SELECT with values `light:<rid>`; Room picker unchanged. |
| Import All New Lights | MERGE into Add Devices | An entry "All new lights (n)"; also offered on the Suggestions row. |
| Add Zone Light | MERGE into Add Devices | Values `group:<rid>`. |
| Re-link Device To Light | MERGE into Re-link Device | Device picker of every gone or unbound device; the target picker cannot be filtered, so the handler refuses a kind mismatch. |
| Re-link Zone Light | MERGE into Re-link Device | As above. |
| Link Devices | AUTOMATIC | Triggers exist: `OnBindingChanged`, a hello, late init; rid matches only; name matches stay OFFERED on the Suggestions row. |
| Forget Light | MERGE into Forget Device | `ForgetDeviceList` already joins lights and zone lights (`src/hue_bridge/driver.lua:1591`). |
| Adopt Hue Names | OFFERED | A Suggestions item "Adopt n Hue names"; renames refresh the project, so never automatic. |
| Accept Names As They Are | OFFERED | The opposite item on the same row ("Keep Composer names"). |
| Set Room Mapping | KEEP | Needs two pickers; nothing else in Composer can take that input. |
| Map Rooms By Name | AUTOMATIC | Precedent: the persisted one-time run (`src/hue_bridge/bridge/lights.lua:922`); exact matches only, future adds only. |
| Room Audit | MOVE to diagnostics | A read-only report: no API can move a device, and the installer's rooms win. |
| Add Scene | MERGE into Add Devices | Values `scene:<rid>`; about 145 entries on the house, so folders would help (unverified on 3.x). |
| Add All Scenes Of Room | MERGE into Add Devices | Entries `scenes-of:<group rid>`. |
| Re-link Scene | MERGE into Re-link Device | As for lights. |
| Forget Scene | MERGE into Forget Device | Join the scene picker. |
| Refresh Scenes | MERGE into Refresh All | A subset of Refresh All. |
| Refresh All | AUTOMATIC | Timer with persisted next-due time plus stream reconnect; Last refresh in Status; a "Refresh now" entry in Diagnostics. |
| Add Motion Sensor | MERGE into Add Devices | Values `sensor:<rid>`. |
| Import All New Motion Sensors | MERGE into Add Devices | An entry "All new motion sensors (n)"; offered on the Suggestions row. |
| Add Motion Area | MERGE into Add Devices | Values `area:<rid>`. |
| Re-link Motion Device | MERGE into Re-link Device | As for lights. |
| Forget Motion Device | MERGE into Forget Device | Join the motion picker. |
| Log Motion Diagnostics | MOVE to diagnostics | A tester tool; a "what" entry in Diagnostics. |
| Light, Scene: Adopt Hue Name | KEEP | Per device, one click, where the installer is looking. |
| Light: Forget This Light; Scene: Forget This Scene | KEEP | Per device; add a LIST "Confirm" parameter. |
| Motion: Refresh From Bridge | AUTOMATIC | The bridge already sends state at hello and resync. |
| Motion: Test: Motion, Test: No Motion | MERGE into Test | One action with a LIST parameter Motion / No Motion. |

With these, the bridge shows six actions (Pair Bridge, Add Devices, Re-link
Device, Forget Device, Set Room Mapping, Diagnostics), one Suggestions row
and one new setting. No feature is lost: every former action is an entry, a
setting, an offer or a task.

## 4. Risks and open questions for the owner

1. **CUSTOM_SELECT folders on OS 3.4.2 are untested.** A merged Add Devices
   picker with about 220 entries is usable flat (text prefixes such as
   "Light: …", "Scene: Kitchen: …"), better in folders. Recommended: probe
   folders with one dev build before the design relies on them.
2. **Suggestions row costs three clicks and a Set** that installers forget.
   Recommended: use it only for offers; keep the merged actions as the
   explicit path, and say "press Set" in the row's tooltip.
3. **No automatic device creation.** The API reference reserves AddDevice
   for user-started actions. Recommended: agree; automatic tasks prepare,
   one click creates.
4. **Merged pickers cannot filter each other** (assumed). Recommended:
   accept; the handler refuses a mismatched pair with a Last Action text.
5. **Renamed and removed actions break text elsewhere** (manuals, checklist,
   devctl scripts, Windows briefs, specs). Recommended: keep the old command
   strings as Lua aliases for one release; the compat research lists them.
6. **Device nesting under the bridge** (3.4.2+, a capability change that
   needs a reboot, room behaviour unknown). Recommended: no, not in this
   redesign.
7. **A setup web page served by the driver.** Recommended: no; it adds an
   open listener for little gain.
8. **Destructive actions get a Confirm parameter.** Recommended: yes for
   Forget Pairing, Forget Device and the per-device Forget actions.
9. **`sort_order` must stay unique and complete.** Recommended: a spec that
   checks every `driver.xml` (a duplicate silently hides an action).

## 5. What this means for the design

The most useful techniques the platform offers:

1. **Merged actions with a "what" picker** (CUSTOM_SELECT, values that encode
   kind and id, a single explanatory entry when empty). Verified on OS 3.4.2.
2. **A Suggestions DYNAMIC_LIST**: offers that come and go with the state,
   accepted by pick plus Set, reset by the driver. Verified mechanics.
3. **Settings instead of action pairs**: a LIST property with a handler
   (Event Stream On/Off). Verified pattern.
4. **Background tasks** on `C4:SetTimer` with persisted due times, keyed to
   `DIT_*` and to the events the bridge already registers
   (`OnItemNameChanged`, `OnItemRemoved`, `OnBindingChanged`). Verified APIs.

What is **not** possible:

1. Hiding, showing, renaming or grouping actions at runtime, or giving an
   action a description, a result or a built-in confirmation.
2. Deleting a device or moving it to another room from a driver.
3. A custom setup page, a wizard window or a Documentation tab that talks
   to the driver.
4. Composer-level discovery of a Hue bridge (no SDDP from Hue).

Constraints every other proposal must respect:

- Device creation follows a click (AddDevice's documented contract);
  deletion and moves stay the installer's.
- Every result, and every background task's outcome or error, goes to
  Status, Attention, Last Action or Suggestions: Composer shows nothing
  else, and a row shows about 75 characters.
- Runtime UI calls only after `OnDriverLateInit`; hide/show sent apart from
  text updates; dynamic lists rebuilt at every start; no commas in items.
- Timers do not survive updates or restarts: persist what is due.
- Updates in place may change actions and add or remove properties, but
  never proxies, connection types, commands, events or variables; a
  `<capabilities>` change costs the owner a controller reboot.
- Nothing may require CUSTOM_SELECT search, filter or folders, OS 4.x APIs
  or the nesting capabilities: the minimum stays OS 3.3.0.
