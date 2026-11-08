# The TLS check's probe bindings: removing them from Director (research, #329)

> **Research for issue #329, 2026-11-08.** Read-only; no code was changed. It answers the three questions of the issue and recommends the smallest fix. Status key as in `docs/design.md`: **[verified: file]** = read in the DriverWorks reference or in Control4's public helper code; **[code: file:line]** = this repository at `main` f8a8bed; **[hardware: …]** = seen on the house; **[assumed]** = not confirmed. Abbreviations: `API/` = `~/c4-tools/reference/docs-driverworks-api/source/includes/`, `FUND/` = `~/c4-tools/reference/docs-driverworks-fundamentals/source/includes/`, `COMMON/` = `~/c4-tools/drivers-common-public/`. Nothing from those files is copied here; every claim is a paraphrase with its source.

## Short answers

1. **Yes, there is one documented call that deletes a binding: `C4:RemoveDynamicBinding(idBinding)`**, available from 1.6.0 (`API/22_miscellaneous/_31-RemoveDynamicBinding.md`). The bridge driver's minimum OS is 3.3.0 (`src/hue_bridge/driver.xml:16`), so every supported controller has it. The reference never says the call applies to a binding made by `C4:CreateNetworkConnection`, and it names no other way to delete a network binding: that it removes a probe binding is **[assumed]** until the house shows it. Today the driver only disconnects and clears the address of each probe binding, then never touches it again.
2. **By the documented options, Director has no reason to retry.** The probes run with `AUTO_CONNECT`, `KEEP_CONNECTION` and `MONITOR_CONNECTION` all off. What Director does internally with a connect whose TLS handshake failed is not documented, nor what `NetDisconnect` does to a connect still pending, nor what `NetConnect` does on a binding whose address is cleared. A cleared binding is a state Director knows ("unaddressed"), and the binding itself stays. That matches the issue: nothing reported a removal, because nothing asked for one.
3. **The probe count is already at its floor.** A controller that verifies spends two ids once per Director version, and the remembered verdict skips every later check on that version. Reusing fixed ids is a problem today: on the house a reused id inherited the old connection or did nothing. Keep the counter until the house shows that an id that was removed and then created again behaves like a new one.
4. **Fix:** add `RemoveDynamicBinding` after the existing disconnect and clear of each probe id, and remove the ids earlier runs left behind, once, at the end of the next check. A persisted mark records how far that has gone. The fake runtime needs one small method. Details in §4, house checks in §5.

## 1. Can a dynamic network binding be deleted? (Q1)

1. **The only documented deletion call is `C4:RemoveDynamicBinding(idBinding)`.** It removes a binding that was created dynamically and has existed since 1.6.0 **[verified: API/22_miscellaneous/_31-RemoveDynamicBinding.md]**. It must not run in `OnDriverInit`, and no events are sent for it before `OnDriverLateInit` **[verified: the same file; API/22_miscellaneous/_25.2-SafeUsageTable.md; FUND/28_api_specific_info/_2-DRIVERINIT.md]**. A search of the whole reference for delete, remove or destroy calls on bindings or network connections finds nothing else **[verified: grep of `~/c4-tools/reference`]**. `docs/edge-cases-ux.md` ("Facts the policy rests on") reached the same list by an earlier sweep.
2. **Whether it covers network bindings is not documented.** Its counterpart `AddDynamicBinding` lists only `CONTROL` and `PROXY` as types **[verified: API/22_miscellaneous/_1-AddDynamicBinding.md]**. `CreateNetworkConnection` describes what it makes as a dynamic network connection, also available from 1.6.0 **[verified: API/32_serial_network_device/_1-CreateNetworkConnection.md]**. The section on serial and network calls (`API/32_serial_network_device/`) has no removal call of its own. So `RemoveDynamicBinding` is the only candidate, and that it removes a binding made by `CreateNetworkConnection` is **[assumed]**.
3. **Director does have a removal event for network bindings.** The system events a driver can register for include `OnNetworkBindingAdded` (17), `OnNetworkBindingRemoved` (18), `OnNetworkBindingRegistered` (19) and `OnNetworkBindingUnregistered` (20) **[verified: API/7_event/_1-RegisteringforSystemEvents.md, API/7_event/_5.5-RegisterSystemEvent.md]**. On the house, probe ids used for the first time were reported as registered and added. The issue's observation was that no "removed" report ever followed **[hardware: builds 414–418, the header of `src/hue_bridge/bridge/netcheck.lua`]**. With event 18 registered, a dev build can see whether `RemoveDynamicBinding` raises it (§5).
4. **Control4's own helper code never deletes a network binding.** Its websocket and SSDP modules let a connection go with `NetDisconnect` and `SetBindingAddress(id, '')`. The websocket module then counts any id from 6100 to 6199 whose address is empty as free and reuses it **[verified: COMMON/module/websocket.lua, `Close` and `setupC4Connection`; COMMON/module/ssdp.lua, `delete` and `disconnect`]**. So leaving cleared bindings behind is ordinary practice on Control4 controllers, and this driver copied it (`docs/raw-stream-design.md` §4).
5. **What the driver does today after a verdict** **[code]**:
   - `finish()` (`src/hue_bridge/bridge/netcheck.lua:308-321`) calls `close_open(check)` (`:296-303`), which calls `close(check, id)` (`:278-293`) for each probe id still open, the decoy's first. `close` makes two calls, each under its own `pcall` with a warning on failure: `C4:NetDisconnect(id, 443)` (`:282`), then `C4:SetBindingAddress(id, "")` (`:288`). It notes the time of the close for the 1.5 s gap. The verdict follows from a 1 ms timer (`:317-320`).
   - The decoy that failed is closed the same way in `decide()` (`:357`), before the control is opened on a fresh id.
   - `netcheck.cancel()` (`:461-475`) does the same through `close_open` (`:472`). `netgate:reset()` reaches it (`src/hue_bridge/bridge/netgate.lua:55-61`) on an address change, a transport change, Forget Pairing and `OnDriverDestroyed` (`src/hue_bridge/driver.lua:1066, 1099, 1870, 2390`).
   - After that the id is never touched again: reports on it are ignored (`netcheck.lua:508-525, 529-553`), and the persisted counter never hands it out again (`:230-258`). Nothing deletes it. On the house, every id from 6100 up to the counter, plus 6002 and 6003 (test builds 414–416) and 6004 to 6007 (the dev-only 1.2 probe, `src/hue_bridge/bridge/probe12.lua:65-94`), is still a cleared binding of the Hue Bridge device **[assumed: that they persist; the house saw reused ids "renamed", which needs the old entry to still be there]**.
6. **Whether these bindings survive a Director restart is unknown.** `AddDynamicBinding` says the driver must restore its dynamic bindings at every start, or they are gone after a Director restart **[verified: API/22_miscellaneous/_1-AddDynamicBinding.md, usage note]**. If that also holds for network bindings, a controller reboot would drop the leftovers by itself. The renames the house saw happened across driver updates, which do not restart Director, so they do not settle it **[assumed]**.

## 2. Retrying, cleared addresses and disconnect (Q2)

1. **The probes' options switch every automatic behaviour off.** The decoy gets the stream's port options with only the CA file changed. The control gets the stream's options unchanged **[code: `netcheck.lua:214-221`; `src/hue_bridge/bridge/netstream.lua`, `port_options`]**. That means `AUTO_CONNECT = false`, `KEEP_CONNECTION = false` and `MONITOR_CONNECTION = false`. The reference ties them to three behaviours: Director connects by itself, Director re-establishes a dropped connection, and Director polls the connection **[verified: API/32_serial_network_device/_25-NetPortOptions.md]**. With all three off, nothing documented makes Director connect a probe binding again after the driver's single `NetConnect`.
2. **A failed handshake is not documented at all.** `OnConnectionStatusChanged` reports only ONLINE or OFFLINE **[verified: API/32_serial_network_device/_27-OnConnectionStatusChanged.md]**. On OS 3.4.3 a refused handshake reported neither **[hardware: build 418, `docs/raw-stream-design.md` §0.2]**. So whether Director still holds a pending connect, a socket or a TLS session for the decoy after the refusal cannot be read from the reference. One house result shows Director can keep connection state for a binding the driver had closed and cleared: build 415's decoy, on a reused id, answered 43 ms after ONLINE, which is taken for the old connection being inherited **[hardware: `netcheck.lua` header]**. In builds 414 to 416 a close made inside `ReceivedFromNetwork` took effect only when the binding was next created. Since then closes run from a timer **[code: `netcheck.lua:373-388`, `step_ended`]**.
3. **`NetDisconnect` is documented only as disconnecting a binding and port** **[verified: API/32_serial_network_device/_24-NetDisconnect.md]**. The reference does not say whether it cancels a connect still in progress, or whether an OFFLINE report follows it. `docs/raw-stream-design.md` §3 assumes such a report and `bridge/netstream.lua` counts on it.
4. **`SetBindingAddress` is documented for moving an existing connection to another address, with a `NetConnect` recommended afterwards** **[verified: API/32_serial_network_device/_16-SetBindingAddress.md]**. An empty address is not mentioned there. Clearing comes from Control4's helper modules (§1 finding 4). `OnNetworkBindingChanged` covers a binding being addressed or unaddressed, which shows an unaddressed binding is a state Director keeps, not a removal **[verified: API/32_serial_network_device/_28-OnNetworkBindingChanged.md]**.
5. **What `NetConnect` does on a binding with a cleared address is not documented** **[verified: API/32_serial_network_device/_23-NetConnect.md says nothing on it]**. It does not arise here: the driver never calls `NetConnect` on a closed probe id **[code]**, and Director has no documented reason to (finding 1).
6. **Composer may show the leftovers.** `SetBindingStatus` notes that Composer's Network Tools window marks connections that are not kept open as Offline (yellow) **[verified: API/32_serial_network_device/_17-SetBindingStatus.md]**. Leftover probe bindings may therefore appear there, and on the Connections ▸ Network tab, as offline rows of the Hue Bridge **[assumed; `docs/raw-stream-design.md` §5 test 9 never recorded whether dynamic bindings appear at all]**.
7. **The slower fan keypad** has no documented link to a disconnected, unaddressed binding with every automatic option off. **[assumed: such a binding costs Director only its entry]**. Once the bindings are removed, the owner can compare again.

## 3. Fewer probes, and fixed binding ids (Q3)

1. **Where the verdict is remembered** **[code]**:
   - `netcheck.STORE_NAME = "netcheck_pinned_on_v2"` (`netcheck.lua:159`; "_v2" since build 417 discarded the verdicts of builds 414–416).
   - `netcheck.remember_pinned()` (`:558-571`) stores the running Director version there. `netgate` calls it on a pinned verdict (`netgate.lua:90-93`). The version comes from `tlscheck.director_version()` (`src/hue_bridge/bridge/tlscheck.lua:149-155`, `C4:GetVersionInfo`).
   - `netcheck.pinned_before()` (`netcheck.lua:576-588`) compares it with the running version. `netcheck.run()` answers "pinned" from it without a probe (`:452-455`), and `netgate` lets an inconclusive answer pass on such a version (`netgate.lua:99-102`).
   - The run's answer is held in `state.net_check` (`driver.lua:80, 282-290`), so the gate runs once per start and probes only on a version that never answered pinned.
2. **Two probes per check is the floor.** A silent decoy alone cannot mean "pinned": silence could also be a connect that was never made. The control, made seconds later the same way, is the evidence that it was made (`netcheck.lua` header, "Why a silent decoy reads pinned"). A decoy that answers already ends the check after one probe (`:347-353`). So on a controller that verifies, the check spends two ids once per Director version. The house's later reconnects used the remembered verdict: "no probe, connected in 0.5 s" (`docs/raw-stream-design.md` §0.2).
3. **Remembering not_pinned too would save one id per start, but only on a controller that does not verify.** It would change the fallback rule (Web transfer until the next start, `netgate.lua:20-26`), and none has been seen. Not recommended. One side finding: such a controller spends one id per start. After 900 starts the ids run out, every check then answers inconclusive (`netcheck.lua:413-421`), and `netgate` holds the stream with retries (`netgate.lua:103-114`) instead of falling back to Web transfer. It is unreachable in practice, and a later fix could reuse removed ids (finding 5).
4. **Reusing fixed ids is a problem today.** On the house, an id that had been used, then cleared, was only renamed by `CreateNetworkConnection`. It then either inherited the old connection (build 415) or did nothing (build 416), so a probe on it proved nothing **[hardware: `netcheck.lua` header; `docs/raw-stream-design.md` §0.2]**. That is why every probe takes a new id from the persisted counter `netcheck_next_binding` (`netcheck.lua:145, 230-258`). Control4's websocket module reuses cleared ids, but it does not need to prove a fresh handshake.
5. **After removal, fixed ids might become usable, but only with proof.** If `RemoveDynamicBinding` really deletes the entry, creating the id again should be reported as registered and added, not renamed. Even then, whether Director keeps a TLS session per peer rather than per binding is unknown, and that alone could make a reused decoy answer. Keep the counter in the fix. Reuse is a later step, and only after a house test shows a removed and recreated decoy staying silent after a control that succeeded (§5 step 6).

## 4. Recommendation (Q4)

### 4.1 The calls at the end of a check, in order

At every verdict (`finish`) and every cancel (`cancel`), from a timer or an action as today, never inside a Director callback:

1. For each probe id of the check that is still open, the decoy's first, three calls, each under its own `pcall`:
   - `C4:NetDisconnect(id, 443)`, as today, to end a connection (and a connect still pending, **[assumed]**, §2 finding 3);
   - `C4:SetBindingAddress(id, "")`, as today, so that if removal turns out to do nothing on some OS release, the binding is left exactly as today;
   - `C4:RemoveDynamicBinding(id)`, which is new.

   The decoy that failed gets the same three calls in `decide()` before the control. The 1.5 s gap then also separates its removal from the control's creation.
2. Once per controller: `C4:RemoveDynamicBinding(id)` for every id from the persisted mark up to the counter as it stood when this check started. These are the ids earlier builds handed out and never removed, plus any id whose run ended in mid-probe without `OnDriverDestroyed` (a power cut). The range never goes past 6999 and never goes below 6100.
3. `C4:PersistSetValue("netcheck_removed_below", next_id)`, written only when the mark moves.
4. The verdict from the 1 ms timer, as today.

The stream's 6001, the mDNS binding 6008 and the dev-only 6004 to 6007 are never removed. The house-only leftovers 6002 and 6003 sit below 6100 and are left to the one-off step of §5. Shipped code does not name them (the rule against one-off tooling in the drivers).

### 4.2 `src/hue_bridge/bridge/netcheck.lua`

- **A new constant:** `netcheck.REMOVED_NAME = "netcheck_removed_below"`, persisted, a number: every probe id below it has been removed. Add a module-local `removed_below` copy for this run, as `next_id` is kept beside the counter.
- **`remove(id)`:** `C4:RemoveDynamicBinding(id)` under `pcall`. It returns the error text, or nil.
- **`close(check, id)`:** after the clear, `remove(id)`, with a warning on failure in the style of the two existing ones (`could not remove binding %d: %s`).
- **`tidy(check)`** replaces the `close_open(check)` call in `finish()` (`:315`) and in `cancel()` (`:472`):

  ```lua
  -- The end of a check: its open probe ids closed, cleared and removed;
  -- then the ids earlier runs handed out and never removed (from the mark up
  -- to the counter as it stood when this check started); then the mark moves.
  local function tidy(check)
  	close_open(check)
  	local from = math.max(removed_below or netcheck.FIRST_ID, stored_mark())
  	local to = math.min(check.sweep_to or from, netcheck.LAST_ID + 1)
  	local failed, first_err = 0, nil
  	for id = from, to - 1 do
  		local err = remove(id)
  		if err then
  			failed, first_err = failed + 1, first_err or err
  		end
  	end
  	if to > from then
  		log.debug("network connection TLS check: removed the probe bindings %d to %d left by earlier runs", from, to - 1)
  	end
  	if failed > 0 then
  		log.warn("network connection TLS check: %d earlier probe binding(s) could not be removed: %s", failed, first_err)
  	end
  	local mark = math.min(math.max(from, to, next_id or 0), netcheck.LAST_ID + 1)
  	if mark > from then
  		removed_below = mark
  		-- PersistSetValue(REMOVED_NAME, mark) under pcall, with a warning, as allocate_id stores the counter
  	end
  end
  ```

  `stored_mark()` reads `REMOVED_NAME` the way `stored_next_id()` (`:230-240`) reads the counter: a whole number from `FIRST_ID` up, else `FIRST_ID`.
- **`netcheck.run()`:** set `check.sweep_to = math.max(next_id or netcheck.FIRST_ID, stored_next_id())` right after creating the check (`:447`), before the address and memory short cuts. That way the run that answers from the memory, which is every start on a verifying controller, also tidies.
- **Why the old ids are removed at the end of a check, not at its start:** a burst of removals just before the decoy could disturb its creation. A silent decoy followed by a control that answers reads "pinned", so a disturbed decoy could turn into a false "pinned", which is the check's one dangerous error. At the end of a check nothing follows in that check. The next decoy is at least 30 s away (the retry) or a start away.
- **Why the mark moves to `next_id` and not to `sweep_to`:** every id handed out in this run has gone through `close()` by then, because only one check is ever in flight and `tidy` closes its open ids first. So a restart never removes anything twice. A failed removal still moves the mark, so a release that refuses the call costs one warning per check, not a growing list of retries.
- **The header,** "Probe binding ids" and "DriverWorks calls": every id is now created, addressed, optioned, connected, disconnected, cleared and **removed** (`API/22_miscellaneous/_31-RemoveDynamicBinding.md`, **[assumed]** for network bindings, #329). Also note the mark and the once-per-controller removal of earlier ids. The worst case is 900 removals in one tidy on a controller that used every id; a realistic one is a few ids. The house's count is read in §5 step 2.

### 4.3 `tests/helpers/fake_c4.lua`

The fake has no `RemoveDynamicBinding` **[code: the network section, `fake_c4.lua:860-958`]**. Without it the call raises inside the `pcall` and the specs pass with warnings, testing nothing. Add one method next to `NetDisconnect`, and mention it in the section's comment:

```lua
-- C4:RemoveDynamicBinding(id) [verified: API 22_miscellaneous/_31, from
-- 1.6.0; that it removes a binding made by CreateNetworkConnection is
-- assumed, #329]: Director forgets the binding, so NetPortOptions, NetConnect
-- and SendToNetwork on it raise here as on a binding never created, and a
-- later CreateNetworkConnection starts it afresh.
function c4:RemoveDynamicBinding(binding)
	record("RemoveDynamicBinding", binding)
	c4.network[binding] = nil
end
```

`c4.net_status` and `c4.net_receive` still deliver reports for a removed id, which is what a late report from Director would look like. `netcheck` already ignores those.

### 4.4 `tests/spec/netcheck_spec.lua`

Changes to what exists:

- `CLOSE` (`:36`) becomes `{ "NetDisconnect", "clear", "RemoveDynamicBinding" }`. `closed_once` (`:98-104`) checks that the last three names are those, with exactly one `NetDisconnect` and one `RemoveDynamicBinding`.
- "after the verdict" (`:554-565`): `assert.is_nil(c4.network[id])` (removed) replaces the check that the address reads `""`. The clear stays visible through `probe_calls`.
- Nothing else should change. Every existing fixture that seeds `netcheck_next_binding` (6120, 6999, 7000, the driver-level 7000) creates its first decoy, where it has one, before any removal. The only extra effect is the removals recorded at its verdict, which none of them asserts against.

New cases (one `describe("removal (#329)")` plus two driver-level assertions):

1. The failed decoy is removed after its close and clear, and before the control's `CreateNetworkConnection`. The control is still created no sooner than 1.5 s after that close.
2. On a pinned_before version with a counter of 6104 and no mark: one run removes 6100 to 6103 in order before the verdict is delivered, creates nothing, and leaves `netcheck_removed_below = 6104`. A second run, and a run after a module reload, removes nothing.
3. A fresh install on a pinned_before version removes nothing and writes no mark (the existing case at `:290-298` keeps its `assert.is_nil` of the counter).
4. After a full check (6100 and 6101) the mark is 6102. A reloaded module's next run removes neither id again.
5. `cancel()` during the decoy removes 6100 and moves the mark to 6101.
6. A `RemoveDynamicBinding` that raises: the verdict is unchanged, `NetDisconnect` and the clear still happened, there is one warning per id closed (and one for the earlier ids, if there are any), and the mark still moves.
7. A corrupt counter (10^9, a whole number, so `stored_next_id` accepts it): the run answers "probe binding ids exhausted", and its tidy removes 6100 to 6999 and nothing beyond.
8. Driver level: in "pinned: the probe ids closed and cleared…" (`:857`), `RemoveDynamicBinding` for 6100 and 6101 comes before the stream's `CreateNetworkConnection(6001)`. In that case and in "Forget Pairing and OnDriverDestroyed…" (`:1018`), there is no `RemoveDynamicBinding` for any id outside 6100 to 6999 (6001, 6008).

Verification: `busted tests/spec/netcheck_spec.lua tests/spec/netgate_spec.lua tests/spec/netstream_spec.lua`, then `tools/check.sh`.

### 4.5 Other files (coordinator)

- `src/hue_bridge/bridge/netgate.lua:15-16` (header: "its binding closed" → "closed, cleared and removed") and `src/hue_bridge/driver.lua:2390` (the comment on `net_gate:reset()`): wording only.
- `CHANGELOG.md`, under `## Unreleased` › Fixed, something like: "The network connection's TLS check now removes the connections it opened for its test once it has answered, and once removes those earlier versions left behind (#329)."
- `docs/status.md` (the #329 line) and `docs/raw-stream-design.md` §0.2, with the house result.
- `docs/README.md`: index this note under the research notes. It is not for the front page.

### 4.6 Lifecycle cases (the rule "edge cases before automation")

Removal touches only bindings this driver made for its own test. The owner never sees them as devices, cannot use them, and has no Composer control that would remove them. Making it automatic therefore takes no manual fix away from anyone.

- **A driver update in place:** `OnDriverDestroyed` → `netgate:reset()` → `cancel()` → tidy, so a probe in flight is removed. The new code's first check removes whatever the old code left.
- **A power cut in mid-probe:** that id stays until the next tidy, because it is below the counter and above the mark.
- **A project restored from a backup:** the counter, the mark and, presumably, Director's bindings come back as they were when the backup was taken, so they stay consistent with each other **[assumed]**. At worst the next tidy removes an id a second time, which should be harmless **[assumed: removing a missing binding does nothing]**.
- **The device deleted:** Director removes it with its bindings **[assumed]**; nothing for the driver to do.
- **A Web transfer owner:** the check never runs, so nothing is removed until the transport is Network connection again. The leftovers stay as harmless as they are today.

### 4.7 Not recommended

- **Fixed probe ids, or wrapping the counter,** until §5 step 6 passes (§3 finding 5).
- **Deferring removal with a timer:** add one only if the house shows that a removal made right after `NetDisconnect` does not take, as a close inside `ReceivedFromNetwork` once did not.
- **Registering `OnNetworkBindingRemoved` and its siblings in the shipped driver:** registered for device 0, they would report every device's network bindings into the Debug Mode log. Register them by hand in a dev build for the test instead.
- **Removing 6001 on Forget Pairing:** the stream recreates it at every start as tested in §0.2, so there is nothing to gain.

## 5. To verify on the house

Each step is short and none waits more than about a minute (house rule). Reading in Composer is always fine. Installs and the Lua command window are covered by the owner's standing approval, and every brief to the Windows session should say so.

1. **Before anything changes, record what is there.** The Windows session opens Composer ▸ Connections ▸ Network and Tools ▸ Network Tools, and records every row of the Hue Bridge device with its binding id, address and colour, with screenshots. Expected today: 6001 (the stream, connected) and 6008 (mDNS). If dynamic bindings are listed at all, there will also be offline, unaddressed rows for 6002, 6003, 6004 to 6007 and 6100 up to the counter.
2. **Test the call by hand on one leftover**, with a dev build (`docs/dev-loop.md`) and Debug Mode on. In the bridge's Lua command window:
   - print `C4:PersistGetValue("netcheck_next_binding")` and `C4:GetBindingsByDevice(0)` (from 3.0.0, it lists the device's network bindings with their addresses **[verified: API/32_serial_network_device/_2.5-GetBindingsByDevice.md]**; that 0 finds the bridge's own bindings is **[assumed]**, else pass the proxy's id);
   - register system events 17 to 20 (`C4:RegisterSystemEvent(C4SystemEvents["OnNetworkBindingRemoved"] or 18, 0)`, and the same for 17, 19 and 20);
   - run `C4:RemoveDynamicBinding(6002)`.

   Expected within a second: an `OnSystemEvent` line in the shipped log naming the removed or unregistered binding 6002, possibly an `OnPIP` (Refresh Navigators), and no error. `GetBindingsByDevice(0)` no longer lists 6002, and after a refresh the 6002 row has gone from the views of step 1. If nothing changes, `RemoveDynamicBinding` does not cover network bindings on OS 3.4.3: stop there and report on #329.
3. **If step 2 removed it, clean up the other house-only leftovers the same way:** 6003 and 6004 to 6007. Do this once, by hand, and never in shipped code.
4. **Install the fixed branch as a `--dev` build**, the usual feature-branch hardware test, recorded with `deploy.py record --no-manifest`. A dev build is used because Composer cannot show startup lines (`docs/composer-remote.md` rule 13), while the dev loop ships them. On the first start the version answers from the memory, so there is no probe. Expected:
   - one tidy removes 6100 up to the counter minus 1;
   - with Debug Mode on, the shipped log reads `removed the probe bindings 6100 to N left by earlier runs`, plus one removal event per id if the events are registered again as in step 2 (a registration does not outlive the driver instance **[assumed]**);
   - `Event Stream` reads `Connected since …` as quickly as before;
   - step 1's views show only 6001 and 6008.

   The release that follows ends the dev loop as usual.
5. **Update in place once more:** nothing is removed, and the persisted `netcheck_removed_below` equals `netcheck_next_binding`.
6. **Force one full check (dev build):**
   - clear the memory with `C4:PersistSetValue("netcheck_pinned_on_v2", "")` and reload (`tools/devctl.py reload`);
   - expected: the decoy on the counter's id stays silent, the control on the next id goes ONLINE and answers, and the verdict is pinned;
   - expected before `Event Stream` reads connected: removal events for both ids, and neither row in step 1's views;
   - optional, for the later question of fixed ids: create a removed id again by hand with `CreateNetworkConnection`, then remove it. Note whether Director reports it as registered and added (a new entry) or as renamed (the old one).
7. **Afterwards:** lamp commands confirm as quickly as before, and the owner can compare the fan keypad. That comparison is subjective, so record it as a note and do not block on it. If the house reboots from System Manager anyway, check step 1's views afterwards: this tells whether Director keeps dynamic network bindings across a restart (§1 finding 6).

Record the results as comments on #329 and in `docs/raw-stream-design.md` §0.2.

## 6. What was implemented (2026-11-08)

Steps 2–4 of §4 were built on `fix/tls-probe-bindings-329` as written, with one addition. The house checks of §5 are still to come.

- `close()` makes the three calls of §4.1, each under its own `pcall`, with a warning per failure. `tidy()` replaces `close_open()` in `finish()` and `cancel()`. `run()` sets `check.sweep_to` before its short cuts. The mark is `netcheck_removed_below` (`netcheck.REMOVED_NAME`), kept in this run as `removed_below`.
- **The addition: removing earlier runs' ids counts as a close for the 1.5 s gap** (`last_close`). `run()` cancels a check still in flight, and that cancel's tidy removes the leftovers. Without this rule the new decoy could follow that burst of removals by only what was left of an earlier gap. With it, no decoy is created less than 1.5 s after any removal. One side effect: a second run that finds the ids used up gives its answer 1.5 s later.
- Logging: when every leftover is removed, one debug line reads `removed the probe bindings A to B left by earlier runs`. When some fail, one warning reads `N of the probe bindings A to B left by earlier runs could not be removed: …`.
- `tests/helpers/fake_c4.lua` has `RemoveDynamicBinding` as in §4.3. `tests/spec/netcheck_spec.lua` covers the cases of §4.4, plus three more: the run's own copy of the mark while the store lags, an unusable mark (one that is not a whole number from 6100 up counts as 6100, and one past the counter removes nothing), and the gap after the leftovers when a run replaces a check.

## 7. Verified on the house (2026-11-08)

- With dev build 538, the check used probe bindings 6102 and 6103 and reached
  `pinned`. `netcheck_removed_below` moved to 6104, and no removal raised.
  After the 1.3 release (build 539), Director's binding list for the bridge
  no longer held any 6100-range id.
- The two 1.0-era leftovers, 6002 and 6003, were removed once by hand from
  the bridge's Lua tab (step 5 of the recommendation). `RemoveDynamicBinding`
  returned without error, and Director's list then held only binding 1 and
  the stream's 6001. So the call removes a `CreateNetworkConnection` binding,
  which section 1 could only assume.
