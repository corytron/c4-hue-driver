# Analysis 4: devices + common (hue_light, hue_scene, common/dispatch, log, devloop)

All paths relative to the repository's `src/`. L = hue_light/driver.lua, S = hue_light/light/state.lua, SC = hue_scene/driver.lua, DL = common/devloop.lua.

## Security

**S1. HIGH (dev builds only). Dev loop executes unauthenticated code over plain HTTP.** DL:196 builds `"http://" .. S.host .. path`; DL:296-298 compiles `files["driver.lua"]` with `loadstring` and runs it in the real global environment (no setfenv; DL:83). Nothing signs or hashes the bundle, and `/commands` (DL:473-488) lets the server call any `ExecuteCommand` and set any property. Trigger: anyone on the LAN who can answer as the dev server (ARP/DHCP spoof, or a hostname in the Dev Server property resolved via a hostile DNS) gets arbitrary Lua with full `C4:*` access on the controller within one 3 s tick. Fix: require HTTPS with a pinned server fingerprint or an HMAC over `files` with a shared secret stored outside Properties, and refuse `set_property` for the Dev Server property itself.

**S2. HIGH (dev builds only). Every report ships all Properties in cleartext.** DL:158-166 `snapshot()` copies the whole `Properties` table plus shadowed `UpdateProperty` values; DL:231-232 attaches it to every `report()` (startup, heartbeat every 30 s, every command_done, every reload). On the bridge this includes whatever property holds the Hue application key / bridge address. DL:93-96 + DL:118-129 also capture every `print` line into `S.log`, shipped by DL:453. Fix: strip a denylist (anything matching key/secret/password/token) in `snapshot()` and never shadow those properties.

**S3. MEDIUM (dev builds only). Any device in the project can push code into a light/scene.** L:536-554 and SC:625-644 accept `DEV_RELOAD` from any sender; `apply_forwarded` (DL:660-684) only checks the `tree` string, never that the sender is the bound bridge. Trigger: a third-party driver calls `C4:SendToDevice(lightId, "DEV_RELOAD", {tree="light", files=...})`. Fix: ignore `DEV_RELOAD` unless `params` arrive from `bridge` (the bridge should include its device id and the light compare it with `bound_bridge()`), or have the bridge sign the bundle.

**S4. LOW. Release builds cannot enable the loop: verified.** L:16-24 / SC:17-25 only ever get a module if `common/devloop.lua` is packaged; the Dev Server property alone does nothing. The only way a release is "tricked" is `tools/build.sh` shipping the file without `--dev` (outside this slice; worth a build-time assertion).

**S5. LOW. Untrusted params used as strings without coercion.** S:107-108 `st.rid = params.rid` and SC:551-552 store the raw value; L:162 `st.rid:match`, SC:206 `st.rid:match` then crash if it is not a string. On the controller all SendToDevice params are strings, but the dev loop's `execute` (DL:475) passes JSON values straight through, so `{"params":{"rid":5}}` from the server wedges `Hue Light ID`/`Status` rendering until the next configure. Fix: `tostring()` in `state.configure` / SC:552 (as `text()` already does for the other fields).

**S6. LOW. Log injection in forwarded lines.** L:84-86 / SC:104-106 `own_line` only checks the line prefix; a Hue name containing `\n[WARN] Hue Light: ...` (name is logged at L:530, SC:607, L:575) produces forged lines in the dev-server log. Fix: `line:gsub("[\r\n]", " ")` in `log.emit` (common/log.lua:35) or in the HUE_LOG sink.

Format strings: all `log.*` calls use literal format strings with user data as `%s` arguments, and `emit`/`always` pcall `string.format` (log.lua:31, 40). No issue found.

## Memory and resource

**M1. LOW. `early` is unbounded before late init.** L:461, SC:529 append every bridge message with no cap. A bridge streaming `HUE_STATE` at event rate to a light whose `OnDriverLateInit` is delayed (Director loading a large project) keeps all of them; each is applied in order at L:466-476. Fix: keep only the latest message per command name (configure, state, forgotten are all idempotent "latest wins").

**M2. LOW. `S.driver_files` cache never prunes.** DL:361/366 add one entry per device id ever seen on binding 1 (deleted devices included); `forwarded` is pruned (DL:391-393) but this table is not. Bounded by lifetime device count; fine for one house.

**M3. LOW. String-keyed `bound` table defeats the driverFileName cache.** DL:355 looks up `S.driver_files[id]` with the key type `GetBoundConsumerDevices` returns, DL:361/366 store under `tonumber(id) or id`. If the keys are strings, every tick re-runs `C4:GetDevices` and `kinds[id]` (DL:397) is always nil, so no device is ever forwarded. Fix: normalise `id` with `tonumber` once at DL:355 and DL:396.

**M4. LOW. Fallback timers survive a failed `OnDriverDestroyed` across reload.** DL:279-286 continues the reload when the destroy hook raises; the old `fallback[...]` timers (L:278) and `pending.timer` (SC:336) then fire into the old closures and send a duplicate `*_CHANGED` through the old module's `C4:SendToProxy`. Fix: on that warning path, also walk and cancel nothing is possible from devloop; instead make `OnDriverDestroyed` wrap each `settle` in `pcall`.

Checked, sound: `arm` always `settle`s first (L:276, SC:334) so there is one timer per kind; the pre-hello log buffers are capped at 30 (L:112-114, SC:132-134); `S.log` is capped at 500 and only trimmed from the front (DL:96); `install_loader` removes the previous loader (DL:257-259); `request` closures die with `gen` (DL:191-194); `step_log` keeps unsent lines without duplicating them (DL:452-460).

## Races and ordering

**R1. MEDIUM. `OnBindingChanged` runs before late init and calls UpdateProperty/SendToProxy.** L:678-691, SC:762-774 are not gated on `late_init_done`; `hello()` → `refresh_status()` → `C4:UpdateProperty`, then `report_online()` → `C4:SendToProxy`, which the driver itself documents as unsafe before `OnDriverLateInit` (L:452-454). Trigger: the bridge's import creates the device and binds it immediately, so the new driver gets `OnBindingChanged(1, ..., true)` while still initialising. Fix: if `not late_init_done`, record the hint and return; `OnDriverLateInit` already calls `hello()`.

**R2. MEDIUM. CHANGING sent, then the send raises: proxy stuck in "changing".** L:318-324 and L:344-355 notify `*_CHANGING` before `C4:SendToDevice`; neither send is pcall'd, and `arm` comes after. SC:368-379 / SC:392-397 identical. If the send raises (bridge driver deleted while the stale `bridge` id is still cached, or Director rejecting the call), dispatch's pcall (common/dispatch.lua:27) swallows it, no fallback is armed, and the proxy never receives CHANGED. Same if `C4:ColorXYtoCCT` raises inside `from_color_target` (S:250) after L:344. Fix: compute params and arm the fallback before notifying CHANGING, and pcall the send (on failure, run `assume` at once).

**R3. LOW. A settled fallback can leave no CHANGED.** L:504-511 settle on any report of a pending field and set `changed.* = true`, but `report_brightness` returns false when `st.on == nil` (S:190) and `report_color` when no colour is known (S:210). A `HUE_STATE` carrying `brightness` without `on`, or `color_mode` without `x/y/mirek`, cancels the timer and sends nothing. Fix: when `report_*()` returns false after a settle, call the cancelled entry's `assume()` (as `stop()` does at L:293-295).

**R4. LOW (design-accepted). Slider spam: an older state settles the newer target.** Target A then B 100 ms later re-arms (L:325); the bridge's event for A arrives, L:504 settles B's fallback and reports A's value. B's final value only reaches the proxy if Hue emits a second event. Acceptable while the bridge forwards every event; worth a comment, or carry a sequence number in HUE_SET/HUE_STATE and settle only on `>=`.

**R5. LOW. Stored colour reported as current.** L:366-370 answers `LIGHT_COLOR_CHANGED` with the requested xy while the light is off, but the cache (`st.x/y`) is unchanged, so the next `SYNCHRONIZE` (L:593-597) reports the old colour; the proxy flips back. Fix: report nothing new on SYNCHRONIZE while `pending_color` exists, or cache the pending xy for `to_proxy_color`.

**R6. LOW. Negative or huge rates/targets pass through.** `tonumber(rate)` (L:311, L:336) may be negative, giving `C4:SetTimer(rate + 1000)` ≤ 0 at L:278, and `str(math.huge)` (S:82-83) formats `%d` on inf. Fix: clamp `rate` to ≥ 0 and `target` to 0..100 in `set_brightness`/`set_color`.

**R7. LOW. Scene ON then OFF inside the fallback window.** SC:398 cancels ON's timer; the bridge's delayed "static" for the recall then hits SC:589-591, settles OFF's pending and reports 100. Correct only because Hue emits "inactive" after the group turns off; if the bridge's HUE_SCENE_OFF path ever fails silently the switch stays on with no fallback. Fix: in HUE_SCENE_STATE, only settle when `params.active` agrees with `pending.on`, otherwise leave the timer running.

**R8. LOW. DEV_RELOAD tree filter relies on the .c4z file name.** DL:648-654 derives the tree from `^hue_(%w+)%.c4z$`; a differently named dev package returns nil, and DL:667 then applies any tree's bundle (a scene bundle into a light). L:542 filters only when `params.tree` is present; an older bridge omits it. Fix: have the light/scene driver pass its own tree constant to `apply_forwarded` instead of guessing from the file name.

Checked, sound: `HUE_CONFIGURE` after `HUE_FORGOTTEN` clears `forgotten` (S:116, SC:562) and `blocker()` recovers; `HUE_FORGOTTEN` and unbind cancel both fallbacks (L:528-529, L:686-687); devloop `reload` calls `OnDriverDestroyed` first (DL:279) so a pending fallback cannot fire into the new instance; `late_init_done` and `early` are per-chunk and `OnDriverLateInit` is called synchronously after the chunk (DL:300-306); `TOGGLE` on a scene uses `pending.on` (SC:717-729); the stuck-tick abandonment bumps `gen` so orphan transfers are dropped (DL:579-588); `STOP` after a confirmed state just re-sends CHANGED (L:290-296); `color_forced` voids a stored colour when something else turns the light on (S:145-147); `dispatch.call` pcalls every handler so one failing handler cannot take down the entry point.
