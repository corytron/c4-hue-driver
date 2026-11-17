# Probes P8 to P12 on the house: the runbook for 2.0 beta stage 3

**Status (2026-11-17): the run notes of issue #557, written before the
probes ran; no result is in yet.** Contract
[`hdmi-sync-stage3-design.md`](hdmi-sync-stage3-design.md) §7 has the
coordinator run the probes of
[`syncbox-wirings-research.md`](syncbox-wirings-research.md) §6 (P8 to P12)
on the house controller, against the VM's fake box, before stage 3 merges;
their results amend §3 to §5 of that contract. This file says, for each
probe: the commands on this VM, the exact brief for the Windows Composer
session ([`composer-remote.md`](composer-remote.md)), the log lines to
expect, and which contract text each outcome changes. The probe code is in
[`tools/probes/`](../tools/probes/), one self-contained Lua chunk each, run
only in a development build, never packaged (`tools/build.sh` packs `src/`
only).

Markers as in the research notes: **[verified: API x/_y]** =
`~/c4-tools/reference/docs-driverworks-api/source/includes/<x>/<_y>.md`;
**FUND** = `docs-driverworks-fundamentals`; **PP** =
`docs-driverworks-proxyprotocol`; **[verified: CL file]** = Snap One's
helper library `~/c4-tools/drivers-common-public/<file>` (read only, never
vendored); **[house]** = this repository or a hardware finding recorded in
it; **[assumed]** = not documented, and what the probe is there to settle.

Placeholders, as everywhere in this repository: the VM is 192.0.2.7, the
house's fake box `0A1B2C3D4E5F` on port 8450, the probes' second fake box
`0A1B2C3D4E60` on port 8451.

## 1. What runs where

| Probe | Chunk | Runs in | Composer change |
|---|---|---|---|
| P8, the room's variables | [`p8_room_variables.lua`](../tools/probes/p8_room_variables.lua) | the bridge | none |
| P9, in line | [`p9_proxy_commands.lua`](../tools/probes/p9_proxy_commands.lua) in the probe box device, P8 on the bridge | both | the scratch room (§4) |
| P10, behind a receiver | the same two | both | rewired scratch room |
| P11 and P11b, second output | the same two | both | rewired scratch room |
| P12, room lifecycle | [`p12_room_lifecycle.lua`](../tools/probes/p12_room_lifecycle.lua) in the probe box device, P8 on the bridge | both | a second scratch room, renamed, a move, a delete |
| any | [`stop_all.lua`](../tools/probes/stop_all.lua) | where the probes run | none |

P13 (a Director restart) stays parked until the owner reboots anyway, and
H1 needs the real box re-cabled; neither is here.

**How a chunk reaches the controller.** `tools/devctl.py run` queues a
signed `execute` command for the bridge, which runs one of the bridge's
development commands by name or the driver's `ExecuteCommand`
(`devloop.execute`, [`dev-loop.md`](dev-loop.md) "Signed commands"). No
command runs a Lua chunk today, and nothing reaches a device's Lua state
but the signed sync box tree the bridge forwards, which the device checks
with its own key ([`dev-loop.md`](dev-loop.md) "Security"). So there are
two ways, and the chunks work with both:

1. **Run Lua** on the bridge, a signed development command the coordinator
   adds to `src/hue_bridge/bridge/devtools.lua` (§2.1). It reaches the
   bridge through the loop, with no Composer install.
2. **A device's Lua command window** in Composer: dev builds are packaged
   with dp3 `--allowexecute`, which leaves the window open (`tools/build.sh`;
   [verified: FUND 6_Understanding .c4z Drivers/_3-C4ALLOWEXECUTE.md;
   FUND 15_composerpro_interface_into_the_sdk/_7-LUA.md]). The Windows
   session worked the devices' windows in rounds 38 and 40
   ([`design.md`](design.md), "Hardware pass of 2026-10-25 night"). It is
   the only way into a sync box device; a bridge command that carried code
   to a device would be an unsigned path any driver in the project could
   use.

**Why the room watcher runs on the bridge.** The bridge listens to no room
variable, so P8 can unregister its listeners cleanly when it stops. In a
Hue Sync Box device, stage 3's `syncbox/room.lua` calls
`UnregisterAllVariableListeners` once per run before it first follows a
room, and may hold the same listeners: a probe there could lose its
listeners at a reload, or take the driver's away when it stops. P8 run in a
device therefore leaves its listeners registered when it stops, and says so.

**The log path.** On the bridge a chunk prints: the dev loop wraps the
global `print` and ships every line. In a device it logs through the
driver's own `common.log`: a dev build forwards every non-debug line to the
bridge as `HUE_LOG`, which prints it as `[<8 hex of the box id>] Hue Sync
Box: probe P9 ...`, so it ships too and also shows in the device's Lua
Output pane. Every probe line starts `probe P8`, `probe P9`, `probe P12` or
`probe stop_all`; times are `t=<ms>` on the controller's clock
(`C4:GetTime`), so lines from the bridge and a device can be merged by
time. Values from other drivers are shown with control characters and `\`
as `\ddd` escapes, and long values in numbered pieces of 700 bytes.

**Parameters.** A chunk reads the global `PROBE_PARAMS` (strings) once and
clears it. Run Lua fills it with its own parameters; in a Lua command
window, a line such as `PROBE_PARAMS = { Minutes = "120" }` goes above the
chunk. Every probe stops by itself after `Minutes` (1 to 120, default 30),
and a second run of the same probe stops the first.

## 2. Running a probe

### 2.1 Run Lua (to add to `bridge/devtools.lua`)

A handler for the table `devtools.install` hands to
`devloop.set_signed_commands`, so only a command the dev key signed reaches
it, as for `Probe Call` or `Hue Request`. It can do no more than a signed
bundle already can. Its own lines and the chunk's `print` pass the
redactor like every shipped line.

```lua
-- Run Lua (signed dev loop commands only; #557, docs/syncbox-probes.md §2.1):
-- runs Code, a Lua chunk such as tools/probes/*.lua, in this driver's Lua
-- state, with every other param in the global PROBE_PARAMS while it runs.
-- No more than a signed bundle can do (devloop.execute runs it only for a
-- signed command); what the chunk prints passes the redactor.
local function run_lua(params)
	params = params or {}
	local code = params.Code
	if type(code) ~= "string" or code == "" then
		return log.always("Run Lua: no Code; nothing run")
	end
	local name = trimmed(params.Name)
	if name == "" then
		name = "chunk"
	end
	local compile = rawget(_G, "loadstring") or rawget(_G, "load")
	local chunk, err = compile(code, "=" .. name)
	if not chunk then
		return log.always("Run Lua: %s does not compile: %s", name, tostring(err))
	end
	local args = {}
	for k, v in pairs(params) do
		if k ~= "Code" then
			args[k] = v
		end
	end
	rawset(_G, "PROBE_PARAMS", args)
	local ok, run_err = pcall(chunk)
	rawset(_G, "PROBE_PARAMS", nil)
	log.always("Run Lua: %s %s (%d bytes)", name, ok and "ran" or ("failed: " .. tostring(run_err)), #code)
end
```

and in `devloop.set_signed_commands({ ... })`: `Run_Lua = run_lua,`. The
compiler is the one the loop's own reload uses (`common/devloop.lua`,
`compile`: `loadstring`, else `load`), which loads every bundle on the
house. Then, on this VM:

```
tools/devctl.py wait $(tools/devctl.py run "Run Lua" Name=p8 RoomName="Hue Probe Room" Minutes=120 \
  Code="$(cat tools/probes/p8_room_variables.lua)")
tools/devctl.py log -n 300 | grep "probe P8"
```

`devctl.py run` sends every `Key=Value` as a parameter, the whole chunk
included; `devctl.py status` then shows the chunk in the pending command
until it has run.

### 2.2 A device's Lua command window (the Windows session)

The chunks reach the Windows VM from GitHub at the commit the coordinator
pushed (the repository is public; the Windows VM fetches release assets
from GitHub already), checked against the sha256 that `sha256sum
tools/probes/*.lua` prints here. Brief text, with `<commit>`, `<file>`,
`<sha256>`, `<params>` and `<device>` filled in:

> **Run a probe chunk in a Lua command window.** In PowerShell:
>
> ```powershell
> $dir = 'C:\c4-hue\probes\<commit>'
> New-Item -ItemType Directory -Force $dir | Out-Null
> $url = 'https://raw.githubusercontent.com/corytron/c4-hue-driver/<commit>/tools/probes/<file>'
> Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile "$dir\<file>"
> (Get-FileHash "$dir\<file>" -Algorithm SHA256).Hash   # must be <sha256>, else stop and report
> $code = 'PROBE_PARAMS = { <params> }' + "`r`n" + ([IO.File]::ReadAllText("$dir\<file>") -replace "`r?`n", "`r`n")
> ```
>
> Select the device `<device>`, open its **Lua** tab, put `$code` into the
> Lua Command box (WM_SETTEXT, as in rounds 38 and 40), check the box holds
> it whole, and click **Execute** once. Keep the Lua tab open and report
> the first ten lines the Lua Output pane shows (they start with the
> device's prefix and `probe`), and every line that holds `error`, `not
> started` or `failed`. Running Lua in a device's window is covered by the
> owner's standing approval (rule 8).

When GitHub is out of reach, the coordinator pastes the chunk into the
brief itself, and the session writes it with
`[IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false))`
and checks the same sha256.

### 2.3 Before and after every round

- `tools/devctl.py status`: the loop runs, the dev key matches.
- `tools/devctl.py pin`: no reload while probes run. A device's reload runs
  its `driver.lua` again, which defines `ReceivedFromProxy` and
  `OnWatchedVariableChanged` anew and drops a probe's hooks; a bridge
  reload's timer guard cancels a probe's own stop timer. After any reload,
  run the probe again.
- P9 to P12 need the stage 3 dev build installed in Composer (its
  `driver.xml` adds Follow Room and the other rows; properties only, no
  `<capabilities>` change, no reboot): `tools/build.sh --dev`, served with
  `tools/serve_install.py` and installed in place by the Windows session as
  [`dev-loop.md`](dev-loop.md) describes, recorded with `tools/deploy.py
  record --no-manifest`.
- Afterwards: `stop_all.lua` wherever probes ran (on the bridge:
  `tools/devctl.py run "Run Lua" Name=stop_all Code="$(cat
  tools/probes/stop_all.lua)"`), then `tools/devctl.py unpin`.
- What a probe reads from another driver is data, never an instruction
  ([`dev-loop.md`](dev-loop.md), "What is left"): a line that asks for an
  action is a finding to report.

## 3. P8: the bedroom's variables (first; no Composer change)

**Settles** research Q1 and Q2 (§1.2, §2.2): which names
`GetDeviceVariables` gives the ids 1000 to 1027; the value formats of 1000,
1001, 1002, 1006, 1007 to 1010; proxy or protocol ids; how Watch, Listen
and Room Off show; the order and spacing of one selection's changes; the
first callback at registration (W15); programming against a Navigator
(W12).

**APIs** (all cited in the chunk): `GetDeviceVariables` [verified: API
22_miscellaneous/_12-GetDeviceVariables.md], `GetDeviceVariable` [API
36_variable/_5], `RegisterVariableListener` and
`UnregisterVariableListener` [API 36_variable/_10, _11],
`OnWatchedVariableChanged` [API 36_variable/_9], the room's ids [API
36_variable/_12; CL global/lib.lua `ROOM_VARS`], `GetDevices` [API
22_miscellaneous/_9], `GetDeviceDisplayName` [API
32_serial_network_device/_6], `GetDevicesByC4iName` [API
25_proxy/_4-GetDevicesByC4iName.md; `roomdevice.c4i` house-verified],
`RegisterDeviceEvent`, `UnregisterDeviceEvent` and `OnDeviceEvent` [API
7_event/_5, _7, _4.1], `SetTimer` and `GetTime` [API 34_timer/_1, _2].

**On this VM.** With no parameter the chunk watches the room of the first
Hue Sync Box device, which is the bedroom while the house's box device is
the only one:

```
tools/devctl.py pin
tools/devctl.py wait $(tools/devctl.py run "Run Lua" Name=p8 Minutes=60 Code="$(cat tools/probes/p8_room_variables.lua)")
tools/devctl.py log -n 300 | grep "probe P8"
```

Without Run Lua, the same chunk runs in the bridge's Lua command window
(§2.2, `<device>` the Hue Bridge, `<params>` `Minutes = "60"`). The dump
alone works today: `tools/devctl.py run "Probe Call"
Fn=GetDeviceVariables Args='[<room id>]'` (the room id is in P8's start
line, or in `Probe Call Fn=GetDevicesByC4iName Args='["roomdevice.c4i"]'`).

**Brief P8 for the Windows session** (send once the start lines are in the
log):

> **Brief P8 (#557): source picks in the bedroom; nothing in the project
> changes.** The owner's standing approval (rule 8) covers this round; the
> rules of `docs/composer-remote.md` hold (stop on surprises, every click
> through `Invoke-SafeClick`, no mouse wheel over a property page). Change
> no connection, property, device or programming; if a step would need
> one, stop and report. The bedroom's real TV and receiver will switch.
>
> In the room **Master Bedroom**, do each step, then wait 20 seconds:
>
> - **a.** Watch: pick a video source.
> - **b.** Watch: pick another video source.
> - **c.** Watch the TV's own input or app, if the room's Watch list offers
>   one; otherwise skip it and say so.
> - **d.** Listen: pick Control4's own music (Stations, My Music or the
>   like) if the room offers it; then, if the Listen list offers a video
>   source (an Apple TV, say), pick that too.
> - **e.** Room Off.
>
> Report for each step: the local time (hh:mm:ss), the source's name as
> the list shows it, how you picked it (which window or command), and any
> dialog or prompt.

**Then, on this VM** (the room's commands, step f): `ROOM_OFF` is what
Snap One's own code sends a room [verified: API
32_serial_network_device/_19-SendToDevice.md; CL global/msp.lua sends
`ROOM_OFF`]; `SELECT_VIDEO_DEVICE` with `deviceid` is not documented
anywhere here [assumed; research §6 P8 step f], and a room that ignores it
is itself the finding. `<source>` is the source's id from P8's `device ...
(variable 1000)` line of step a.

```
tools/devctl.py run "Probe Call" Fn=SendToDevice Args='[<room id>,"SELECT_VIDEO_DEVICE",{"deviceid":"<source>"}]'
# wait 20 s
tools/devctl.py run "Probe Call" Fn=SendToDevice Args='[<room id>,"ROOM_OFF",{}]'
# wait 20 s; then step g, the first callbacks again:
tools/devctl.py run "Run Lua" Name=p8 Minutes=10 Code="$(cat tools/probes/p8_room_variables.lua)"
```

**Expected lines** (the values are the unknowns):

```
probe P8 start room <id> "Master Bedroom" (the room of Hue Sync Box device <id>) in hue_bridge.c4z device <id>; ...
probe P8 dump <room>: <n> entries
probe P8 dump <room>/1000: {name="...", value="...", ...}
probe P8 name Current_Video_Path: id 1008 as expected
probe P8 read <room>/1010 <name>: "<value>"
probe P8 change <room>/1000 <name> t=<ms> +0ms first (during register): "<value>"
probe P8 listen <room>/1000 <name>: registered in <n> ms
probe P8 events <room>: registered 40 of 40 ids, 0 failed
probe P8 change <room>/1000 <name> t=<ms> +<ms>ms change: "<id>"
probe P8 device <id> (variable 1000): display "<name>"; GetDevices {<id>={deviceName=..., driverFileName=..., protocol=...}}
probe P8 change <room>/1008 <name> t=<ms> +<ms>ms change: "<...><id>...</id>..."
probe P8 stop room <id>: time is up; after <s> s; 12 listener(s) unregistered, 0 left registered
```

**How the outcome amends the contract:**

| Seen | Amends |
|---|---|
| The dump names each id as the SDK and Snap One's library do | §4 `room.lua`: keep "by name, else the numbers"; write the exact spellings seen into its table |
| A name sits on another id than 1000 + position | §4: the name wins, the numbers are only the fallback; a spec with the shifted id |
| The dump has no names, or is not keyed by id | §4: the numbers only; research §1.2 notes the shape |
| 1000 and 1002 hold proxy ids (`GetDevices` shows a `protocol` table) | §4 `sources.lua`: `describe` takes the proxy's driver file for `proxy_kind` and the protocol's for `driver_file` |
| They hold protocol ids (a `proxies` table) | §4 `sources.lua` reads `proxies` instead |
| 1010's values (for example `0`/`1`, or text) | §4 `room.lua`'s power parse: exactly those values |
| Listen: 1001 set, 1002 `0` or unchanged, 1008 empty, 1007 set; or 1006 names the media type | §4 `room.lua` `kind`: the rule as seen; if 1006 tells Watch from Listen, it is watched too |
| Room Off: 1000 to `0` and 1010 change, in some order | §4 and `follow.lua`: At Room Off fires on that change, whichever comes first, after the settle |
| One selection's changes spread over N ms | §4 `room.SETTLE_MS`: stays 1 s if N stays under 500 ms, else N + 500 ms |
| The first callback comes during the register call | §4 `on_baseline` as built (W15); if it never comes, `follow()` reads the values with `GetDeviceVariable` as the baseline |
| Step f changes the variables as step a did | W12 confirmed; if the room ignores `SELECT_VIDEO_DEVICE`, step f says only that, and §4 is unchanged |
| The room fires device events | Nothing: the variables suffice; research §1.1 lists the ids |

## 4. The scratch rooms (P9 to P12)

One Windows-session round in six briefs (R1 to R6), with steps on this VM
between them. The house's own box device and the bedroom are not touched:
a second Hue Sync Box device, **Probe Sync Box**, lives in a scratch room
of generic drivers and pairs with a second fake box, so its wiring can be
switched from this VM without changing the house's. It is bound to the
bridge's Hue Sync Boxes connection, so it runs the dev loop's sync box tree
and its lines reach the log. Everything added is deleted in R6.

**On this VM, before R1:**

```
tools/devctl.py status                      # loop up, key matches; stage 3 dev build installed (§2.3)
tools/devctl.py pin
python3 -I tools/fakebox.py --state-dir build/fakebox-probe serve --box HSB2:0A1B2C3D4E60:8451 \
  --bind lan --control-port 8445 --quiet    # in the background; the house's fake (8450, 8444) keeps running
python3 -I tools/fakebox.py --state-dir build/fakebox-probe state --path behavior   # in line: both modes 0
sha256sum tools/probes/*.lua                # for the briefs (§2.2)
```

**Brief R1 for the Windows session (the scratch room):**

> **Brief R1 (#557): a scratch room for the routing probes.** The owner's
> standing approval (rule 8) covers every step here, including the ones
> hard to undo (rule 2): adding rooms and devices, Connections (by
> synthetic drag, checked twice, rule 18), property changes (each with its
> Set button, rule 7), and running an action. The rules of
> `docs/composer-remote.md` hold: stop on surprises (rule 3), report exact
> texts (rule 4), clicks only through `Invoke-SafeClick` (rule 5), no
> mouse wheel over a property page (rule 17). Do not refresh Navigators in
> this round. Everything added here is deleted in brief R6.
>
> 1. Back up the project first, as rule 5 asks before any round that
>    changes it; report the backup's file name. Record the baseline (rule
>    6): window title and the System Design row count.
> 2. On the floor that holds Master Bedroom, add two rooms: **Hue Probe
>    Room** and **Hue Probe Room 2**.
> 3. From Composer's driver database, add to Hue Probe Room, choosing by
>    these rules: an IR-controlled model (no network or serial driver);
>    a manufacturer "Generic" where the database has one; report each
>    driver's manufacturer, model and driver file name.
>    - **Probe TV**: a TV with at least three HDMI inputs;
>    - **Probe Player A**, **Probe Player B** and **Probe Player D**: three
>      video sources (Blu-ray, DVD or media player), each with an HDMI
>      output;
>    No receiver yet (it comes in R3). No IR emitter is connected, so no IR
>    goes out.
> 4. From My Drivers, add **Hue Sync Box** to Hue Probe Room and name it
>    **Probe Sync Box**. Report its Driver Version.
> 5. Connections: bind Probe Sync Box's **Hue Bridge** connection to the
>    Hue Bridge's **Hue Sync Boxes** connection (drag from Probe Sync
>    Box's own row in the top pane). Read back the bridge's Hue Sync Boxes
>    list: it must name the house's sync box device and Probe Sync Box.
>    Then wait 30 seconds.
> 6. Probe Sync Box ▸ Actions ▸ **Pair Sync Box**: Box = "Type an address
>    (under Address)", Address = `192.0.2.7:8451`. Report Status and Box
>    ID every 10 seconds until Status no longer counts down (at most 2
>    minutes). Box ID must read `0A1B2C3D4E60`.
> 7. Probe Sync Box ▸ Properties ▸ **Debug Mode** = On (Set). Report
>    Status, Online, Wiring, Sync, Inputs, Follow Room and the HDMI n Sync
>    Mode rows as they read.
> 8. Connections for the in-line probe (P9), each video and HDMI audio
>    where both exist (report the exact row names used):
>    - Probe Player A's HDMI output → Probe Sync Box **HDMI 1**;
>    - Probe Player B's HDMI output → Probe Sync Box **HDMI 2**;
>    - Probe Sync Box **HDMI Out** → Probe TV's HDMI 1;
>    - Probe Player D's HDMI output → Probe TV's HDMI 2.
>    Read back Probe Sync Box's connections and Probe TV's.
> 9. Hue Probe Room's room connections: report the Video End Point, Audio
>    End Point and Video Audio End Point as they read; set Video End Point
>    and Video Audio End Point to Probe TV if they are not.
> 10. Run the chunk `p9_proxy_commands.lua` in **Probe Sync Box**'s Lua
>     command window (the "Run a probe chunk" steps below), `<params>` =
>     `Minutes = "120"`.
> 11. Confirm the baseline changed only by what this brief added (rule 6).
>
> Report: the backup's name, each device's driver, every read-back, the
> Lua Output lines, and the times of steps 5, 6 and 10.

(R1 ends with §2.2's block, filled in for `p9_proxy_commands.lua`.)

**On this VM, right before sending R1**, open the second fake's pairing
window for 30 minutes (it takes one registration, and only Probe Sync Box
knows that address); **after R1**, start P8 on the scratch room:

```
python3 -I tools/fakebox.py --state-dir build/fakebox-probe button --window 1800
# after R1:
tools/devctl.py log -n 200 | grep -E "syncbox version|forwarded"   # the tree reached Probe Sync Box
tools/devctl.py run "Run Lua" Name=p8 RoomName="Hue Probe Room" Minutes=120 Code="$(cat tools/probes/p8_room_variables.lua)"
```

**Between briefs:** `tools/devctl.py log -n 400 | grep -E "probe P[0-9]+ stop"`.
A probe that stopped (`time is up`, after 120 minutes) runs again before
the next brief: P8 with Run Lua, P9 or P12 as a first step of that brief.

P9's start lines (in the log, behind `Hue Sync Box:`) show what the box's
AV connections are bound to; `bound <AV proxy>/1000 HDMI 1 video: <id>`
names Probe Player A. Two caveats. The house's box device and Probe Sync
Box both forward as `[0A1B2C3D] Hue Sync Box:` (the first 8 hex digits of
the box ids are equal): every `probe P9` and `probe P12` line is Probe Sync
Box's, since only it runs them, but the drivers' own lines (Debug Mode)
need their content to tell them apart; the house's device is never routed
in this round. And if P9's start lines show no binding on the proxy, the
`bound 0/...` lines say whether the protocol device holds them.

## 5. P9: in line

**Settles** R3 P1 to P4 and P6 for the in-line wiring: `ON` and
`SET_INPUT` order and spacing; one `SET_INPUT` with `AUDIO` and `VIDEO` or
two; `PREV_DEV_LIST`'s format on OS 3.4.3; `OFF` or `DISCONNECT_OUTPUT` for
a source that bypasses the box and at Room Off; whether 1008 lists the
box's proxy id; which comes first, the command or the variable. With the
stage 3 code paired with the fake, it also runs C4's flow end to end: the
PUT to the fake, the read back, `INPUT_OUTPUT_CHANGED`.

**APIs:** `ReceivedFromProxy` [verified: API 25_proxy/_5],
`GetBoundProviderDevice` and `GetBoundConsumerDevices` [API
32_serial_network_device/_4, _3: on a proxy's id], `GetProxyDevices` [API
25_proxy/_1], `RoomGetId` [API 22_miscellaneous/_33], with P8's.

**Brief R2 for the Windows session:**

> **Brief R2 (#557): P9, source picks in Hue Probe Room.** Standing
> approval and the rules as in R1. No project change in this brief.
>
> In **Hue Probe Room**, do each step, then wait 20 seconds; after each,
> read Probe Sync Box's Status, Sync, Last Action and Online:
>
> - **a.** Watch **Probe Player A**.
> - **b.** Watch **Probe Player B**.
> - **c.** Watch **Probe Player D**.
> - **d.** Watch **Probe Player A**.
> - **e.** Room Off.
>
> Report for each step: the local time (hh:mm:ss), how you picked it, the
> four rows, and the Lua Output lines of Probe Sync Box that start with
> `Hue Sync Box: probe P9 cmd` (its Lua tab open throughout, rule 13).

**On this VM, after R2:** `tools/devctl.py log -n 400 | grep -E "probe
P(8|9)"`, and what the stage 3 code wrote:
`python3 -I tools/fakebox.py --state-dir build/fakebox-probe log -n 60`
and `... state --path execution`.

**Expected lines:**

```
probe P9 cmd t=<ms> +<ms>ms on 5001 ON: (no parameters)
probe P9 cmd t=<ms> +<ms>ms on 5001 SET_INPUT: AUDIO="..." INPUT="1000" OUTPUT="2000" PREV_DEV_LIST=(below) VIDEO="..."
probe P9 cmd PREV_DEV_LIST: "<raw>"
probe P9 cmd PREV_DEV_LIST ids: <id> <id>
probe P8 change <room>/1008 Current_Video_Path t=<ms> ...: "<...>"
probe P9 cmd t=<ms> +<ms>ms on 5001 DISCONNECT_OUTPUT: ...      (step c, or OFF)
probe P9 cmd t=<ms> +<ms>ms on 5001 OFF: (no parameters)        (step e)
```

**How the outcome amends the contract:**

| Seen | Amends |
|---|---|
| `ON` before `SET_INPUT`, or after, and the gap | §3 `queue.lua`: the wake rides in the input's PUT whatever the order (as built); §5 `syncbox_driver_spec.lua`: the observed order is the main case, the other stays tested |
| One `SET_INPUT` with `AUDIO` and `VIDEO` true | §3 `av.lua`: as built |
| Two (`1000` then `3000`, or the reverse) | §3 `av.lua`: the second for the same input is confirmed without a second PUT (C4 says so); a spec for that order |
| `PREV_DEV_LIST`'s format | Contracts C4, row `SET_INPUT`: the format; §3 `av.lua` may parse it as a hint, never as the only source |
| Player D: `DISCONNECT_OUTPUT` alone, `OFF` alone, or both | C4 rows `OFF` and `DISCONNECT_OUTPUT`: the mapping as seen |
| Room Off: `DISCONNECT_OUTPUT` then `OFF` | §3 `queue.lua`: the pending When The Source Leaves The Box write is replaced by At Room Off when `OFF` follows within the settle, not sent first |
| 1008 lists the box's AV proxy id | §4 `room.lua` and `av.lua`: edge case I15 and W20 can check `room.video_path` for the box |
| 1008 lists no box | §4: I15 and W20 rely on the commands only; research §3.3's offer is dropped |
| The variables change before or after `SET_INPUT`, by N ms | §5: in line the mode comes from the input, so nothing waits on the room; the number goes to P10's reading |
| Director sends `SET_INPUT` again while the confirmation is pending | §3 `queue.lua`: a repeat of the pending intent joins it, no second PUT |

## 6. P10: behind a receiver

**Settles** research §3.1's table: whether `SET_INPUT` 1000 comes again
when the source behind the receiver changes; whether `PREV_DEV_LIST` names
the source or only the receiver; `ON`, `OFF`, `DISCONNECT_OUTPUT`; whether
an audio `SET_INPUT` comes; what a Listen source does to the box (the
provisional answer 2 of contract §2).

**On this VM, before R3:**

```
python3 -I tools/fakebox.py --state-dir build/fakebox-probe set behavior.arcBypassMode 1
```

**Brief R3 for the Windows session:**

> **Brief R3 (#557): P10, the box behind a receiver.** Standing approval
> and the rules as in R1; this brief changes Connections and adds two
> devices (rule 2), all deleted in R6.
>
> 1. Add to Hue Probe Room from the driver database, by R1's rules:
>    **Probe Receiver** (an AV receiver with at least two HDMI inputs, an
>    audio input such as an analog or CD input, and if possible a second
>    HDMI output, named like HDMI Out 2, Monitor Out 2 or Zone 2) and
>    **Probe CD** (a CD player or tuner: audio only). Report each driver and
>    the receiver's output rows.
> 2. Disconnect Probe Player A and Probe Player B from Probe Sync Box
>    (HDMI 1 and HDMI 2, video and audio). Each Disconnect names the two
>    devices; read both lists after each.
> 3. Connect: Probe Player A → Probe Receiver's HDMI input 1; Probe
>    Player B → its HDMI input 2; Probe CD → its audio input; Probe
>    Receiver's (first) HDMI output → Probe Sync Box **HDMI 1** (video, and
>    audio if the receiver's output offers it). Keep Probe Sync Box HDMI Out
>    → Probe TV HDMI 1 and Probe Player D → Probe TV HDMI 2.
> 4. Read Hue Probe Room's Video End Point, Audio End Point and Video
>    Audio End Point. Expected at Composer's defaults: Probe TV, Probe
>    Receiver, Probe Receiver; set them so if not, and report.
> 5. Wait 20 seconds; read Probe Sync Box's Wiring, Follow Room and
>    Source Sync Modes. Wiring should read behind a receiver.
> 6. In Hue Probe Room, each step then 20 seconds, reading Status, Sync,
>    Last Action after each: a. Watch Probe Player A; b. Watch Probe
>    Player B; c. Listen Probe CD; d. Watch Probe Player D; e. Watch Probe
>    Player A; f. Room Off.
>
> Report as in R2, plus the read-backs of steps 1 to 5.

**Expected lines:** P9's `cmd` lines for each step; the unknowns are
whether step b brings a `SET_INPUT` at all, and what step c brings.

**How the outcome amends the contract:**

| Seen | Amends |
|---|---|
| Step b brings `SET_INPUT` 1000 again | §3 `av.lua` behind a receiver: each `SET_INPUT` takes the mode from the room's current source, as built |
| Step b brings nothing | §3 and §5: behind a receiver, while routed, a room `on_change` (a new source) sets the mode without a command; the bullet "Behind a receiver" of §3 gains it, `driver.lua` hands `av` the room's changes |
| `PREV_DEV_LIST` names Probe Player B | §3 `av.lua`: on OS 3.4.2 and later the mode comes from `PREV_DEV_LIST`'s source first, the room second |
| It names only Probe Receiver | §3: the room alone |
| Step c sends the box `DISCONNECT_OUTPUT` or `OFF` | §2 answer 2 ("start music sync anyway"): `follow.lua` drives music sync from the room's Listen selection behind a receiver too, overriding that command; §3 and §4 say so |
| Step c sends an audio `SET_INPUT` (3000) | §3 `av.lua`: an audio-only route through the box is Music, as in line |
| Step c sends nothing | As `DISCONNECT_OUTPUT`, without a command to react to: the room alone decides (§4) |
| Step d sends `DISCONNECT_OUTPUT` | When The Source Leaves The Box, as built |
| An audio `SET_INPUT` in steps a, b, e | §3: as P9's two-command row |

## 7. P11: from the receiver's second output (and P11b)

**Settles** research §4.1 choices A and B: Director sends the box no AV
command; the box is never offered as a room endpoint; 1008 contains the
receiver for a source that passes it (W17). P11b shows choice C's danger.

**On this VM, before R4:**

```
python3 -I tools/fakebox.py --state-dir build/fakebox-probe set behavior.arcBypassMode 0
python3 -I tools/fakebox.py --state-dir build/fakebox-probe set behavior.soloMode 1
```

**Brief R4 for the Windows session:**

> **Brief R4 (#557): P11, the box on the receiver's second output.**
> Standing approval and the rules as in R1; this brief changes Connections.
>
> 1. Disconnect Probe Receiver's HDMI output from Probe Sync Box HDMI 1,
>    and Probe Sync Box HDMI Out from Probe TV HDMI 1 (video and audio).
>    Read both lists after each.
> 2. Connect Probe Receiver's (first) HDMI output → Probe TV HDMI 1.
> 3. If Probe Receiver has a second HDMI output: connect it → Probe Sync
>    Box **HDMI 1** (video, and audio if offered). If it has none, connect
>    nothing to Probe Sync Box and say so. Probe Sync Box **HDMI Out**
>    stays unconnected.
> 4. Read Hue Probe Room's Video End Point, Audio End Point and Video
>    Audio End Point, and open each one's drop-down to list every device it
>    offers (MSAA, then Cancel; rule 1). Is Probe Sync Box among them?
> 5. Wait 20 seconds; read Probe Sync Box's Wiring, Follow Room, Source
>    Sync Modes, Status.
> 6. In Hue Probe Room, each step then 20 seconds, reading Status, Sync,
>    Last Action after each: a. Watch Probe Player A; b. Watch Probe
>    Player B; c. Listen Probe CD; d. Watch Probe Player D; e. Room Off.
> 7. P11b: connect Probe Sync Box **HDMI Out** (video) → Probe TV HDMI 3.
>    Then a. Watch Probe Player A; b. Watch Probe Player D; c. Room Off,
>    each with 20 seconds and the same reads. Report which input Probe TV
>    shows for step a if Composer or the room shows it. Then disconnect
>    Probe Sync Box HDMI Out again.
>
> Report as in R2, plus the read-backs of steps 1 to 5 and 7.

**Expected lines:** in steps 6a to 6e no `probe P9 cmd` line but
`BINDING_CHANGE_ACTION` (at step 3) and perhaps `GET_AUDIO_INPUTS`;
P8's 1008 changes naming Probe Receiver for a and b, not for d; the
stage 3 code's own lines (Debug Mode On) for Follow Room's wake and sync.
In 7a, `ON` and `SET_INPUT` would show Director routing through the box.

**How the outcome amends the contract:**

| Seen | Amends |
|---|---|
| No `ON`, `SET_INPUT`, `OFF` in step 6 | §3: on the second output the proxy's commands are only logged, as built |
| AV commands in step 6 | §3 and §5: `av.lua` still ignores them in that wiring; Status names the misconnection (a stage 4 offer); the manual says how to connect |
| The endpoint lists never offer Probe Sync Box | Contracts C1.2's "no room binding" confirmed |
| They offer it | C1.2 reopened (a finding for the owner, not a stage 3 change) |
| 1008 names Probe Receiver for A and B, not for D | §4 `follow.lua` W17 (choice B): "the source leaves the box" when 1008 lacks the receiver the box's HDMI 1 is bound to |
| 1008 never names the receiver | W17 falls back to the per-source "Do not sync" (choice A) in every case; §4 and the manual say so |
| Listen: 1007 names Probe Receiver | §4 `follow.lua`: Music on that Listen, as built |
| P11b 7a sends the box `SET_INPUT` | The manual's "never connect HDMI Out in solo mode" stays and gains why (agent D's documentation); a Status warning is a stage 4 offer |

## 8. P12: room lifecycle

**Settles** W3 to W6 and W16: the system event payloads for rooms;
whether a device's `RoomGetId()` follows a move at once; what a listener
does when its room is deleted; how a listener on a missing room or variable
fails.

**APIs** (cited in the chunk): `RegisterSystemEvent`,
`UnregisterSystemEvent`, `OnSystemEvent` and `C4SystemEvents` [verified:
API 7_event/_1, _5.5, _6.1, _4.2; the event names as the bridge registers
them, `src/hue_bridge/driver.lua` `PROBE_EVENTS`], `RoomGetId` and
`GetDevices` [API 22_miscellaneous/_33, _9], `GetDevicesByC4iName`, and the
listener calls of P8.

**On this VM, before R5** (P8 on the second scratch room, which R5
deletes):

```
tools/devctl.py run "Run Lua" Name=p8 RoomName="Hue Probe Room 2" Events=off Minutes=60 \
  Code="$(cat tools/probes/p8_room_variables.lua)"
```

**Brief R5 for the Windows session:**

> **Brief R5 (#557): P12, renaming, moving and deleting rooms.** Standing
> approval and the rules as in R1; this brief moves a device, renames and
> deletes a room (rule 2), and changes a property (rule 7).
>
> 1. Run `p12_room_lifecycle.lua` in **Probe Sync Box**'s Lua command
>    window ("Run a probe chunk" below), `<params>` = `Minutes = "60"`.
>    Report its Lua Output lines.
> 2. Read Probe Sync Box's Follow Room and Status. Follow Room should read
>    "This device's room (Hue Probe Room)".
> 3. Move Probe Sync Box to **Hue Probe Room 2** (drag its row in the
>    System Design tree onto that room, checked twice, rule 18; if no drag
>    moves it, stop and report). Wait 20 seconds; read Follow Room, Status,
>    Last Action.
> 4. Move it back to **Hue Probe Room**. Wait 20 seconds; read the same.
> 5. Set Follow Room to **Hue Probe Room 2** (Set). Wait 20 seconds; read
>    Follow Room and Status.
> 6. Rename Hue Probe Room 2 to **Hue Probe Room 2b**. Wait 20 seconds;
>    read Follow Room (the shown text, and the drop-down's items through
>    MSAA, then Cancel) and Status.
> 7. Delete the room **Hue Probe Room 2b** (it is empty). Confirm the
>    prompt (approved). Wait 30 seconds; read Follow Room, Status, Attention
>    and Last Action.
> 8. Set Follow Room back to "This device's room (Hue Probe Room)" (Set).
>    Read Status.
>
> Report: the times of steps 3 to 8, every read, every prompt's exact
> text, and the Lua Output lines that start with `Hue Sync Box: probe P12`.

**Expected lines:**

```
probe P12 start device <id> in hue_syncbox.c4z: RoomGetId <room>; Director's room <room> "Hue Probe Room"; <n> rooms
probe P12 bogus listener 987654/1000: error <text>            (or "no error")
probe P12 bogus variable <room>/1999: error <text>            (or "no error", and perhaps a bogus callback)
probe P12 system events: registered OnItemAdded=<id> OnItemRemoved=<id> OnItemNameChanged=<id> OnItemMoved=<id> ...
probe P12 system event t=<ms>: "<c4soap ... name="OnItemMoved" ...>"       (step 3, if it fires)
probe P12 RoomGetId <room> -> <room 2> t=<ms> (Director's room <room 2> "Hue Probe Room 2")
probe P12 room renamed <id>: "Hue Probe Room 2" -> "Hue Probe Room 2b" t=<ms>
probe P12 system event t=<ms>: "<c4soap ... name="OnItemRemoved" ...>"     (step 7)
probe P12 room removed <id>="Hue Probe Room 2b" t=<ms>
probe P8 change <room 2>/... (anything P8's listener on the deleted room still says)
```

**How the outcome amends the contract:**

| Seen | Amends |
|---|---|
| A rename fires `OnItemNameChanged` with the room's id and an `itemtype` | §4 `room.lua` (W3): the label is refreshed on that event, matched by `iditem` |
| A rename fires nothing | W3: the label is refreshed when the room list is read (each poll), as built |
| `RoomGetId()` changes at once after a move | §5 `driver.lua` (W6): re-read on every poll, as built |
| `RoomGetId()` keeps the old room while `GetDevices` shows the new one | §5: W6 reads `GetDevices{ DeviceIds = <own id> }.roomId` instead |
| `OnItemMoved` fires, with this device's id | §5: registered and acted on at once; the poll stays as the fallback |
| A delete fires `OnItemRemoved` with the room's id | §4 (W4): "Follows a deleted room" at that event; the room list stays the check |
| Only the room list shows the delete | §4 (W4): the room list on each poll, as built |
| P8's listener on the deleted room gets a last callback (an empty value, say) | §4 `room.lua`: such a value after a delete is not a Room Off; the delete is checked first |
| The bogus room raises an error | §4 (W16): `pcall` catches it, as built |
| It raises nothing and no callback comes | §4 (W16): a follow with no first callback within 2 s counts as "its variables do not answer" |
| Step 6's Follow Room shows the new name | W3 as built; otherwise §5 refreshes the DYNAMIC_LIST on the rename |

## 9. Cleanup (brief R6)

**On this VM first:** `stop_all.lua` on the bridge (§2.3).

> **Brief R6 (#557): cleanup.** Standing approval and the rules as in R1;
> this brief deletes rooms and devices (rule 2).
>
> 1. Run `stop_all.lua` in **Probe Sync Box**'s Lua command window
>    (`<params>` empty); report its lines.
> 2. Delete the room **Hue Probe Room** with every device in it (Probe
>    TV, Probe Player A, B and D, Probe Receiver, Probe CD, Probe Sync
>    Box). Confirm each prompt (approved); report its exact text.
> 3. Read back: the Hue Bridge's Hue Sync Boxes connection lists only the
>    house's sync box device; that device's Status, Online, Wiring,
>    Driver Version and Debug Mode are as before the round; Master
>    Bedroom's room connections are unchanged.
> 4. Confirm the window title and that the System Design row count is back
>    to the baseline of R1 (rule 6).
>
> Report the reads and the counts.

**Then on this VM:**

```
python3 -I tools/fakebox.py --state-dir build/fakebox-probe stop
tools/devctl.py unpin
tools/devctl.py log -n 100 | grep -iE "error|warn"
```

The results go into the issue (#557) as a comment, into contract §3 to §5
as the tables above say, and into this file's status line.

## 10. Order

1. P8 (§3): Run Lua on the bridge, brief P8, step f from this VM, step g.
2. The stage 3 dev build installed in Composer (§2.3), then R1 (§4).
3. R2 (P9), R3 (P10), R4 (P11, P11b), R5 (P12), each with its steps on
   this VM before it, each sent after the previous report.
4. R6 and the VM's cleanup (§9).

Each step waits at most a minute (the owner's rule); the probes stop by
themselves after their `Minutes`.

## Sources

- Snap One DriverWorks SDK under `~/c4-tools/reference/` (paths in the
  markers above and in each chunk's comments), read only.
- Snap One helper library, `~/c4-tools/drivers-common-public/`:
  `global/lib.lua` (`ROOM_VARS`), `global/msp.lua` (the room parsers,
  `ROOM_OFF`), `global/handlers.lua` (`GetDeviceVariables` keyed by the
  variable id as text, each entry with a `name`), read only.
- This repository: [`hdmi-sync-stage3-design.md`](hdmi-sync-stage3-design.md),
  [`hdmi-sync-contracts.md`](hdmi-sync-contracts.md),
  [`syncbox-wirings-research.md`](syncbox-wirings-research.md),
  [`syncbox-control4-research.md`](syncbox-control4-research.md),
  [`dev-loop.md`](dev-loop.md), [`composer-remote.md`](composer-remote.md),
  [`fakebox-design.md`](fakebox-design.md), [`design.md`](design.md).
