# Analysis 3: scenes.lua, groups.lua, hue_model.lua

Paths are under `/home/cory/projects/c4-hue-driver/src/hue_bridge/bridge/`. Read-only review; nothing run.

## Findings

### F1. `adding` / `resyncing` flags can stick forever, freezing every action and all later resyncs — Medium-High
- scenes.lua:1051-1056, 1370-1373, 1434, 1532; fetch_all 563-590.
- What: `resync()` sets `resyncing = true` and relies on the http callback chain to clear it; `add_scene`/`add_all_of_group` set `adding = true` and rely on the `C4:AddDevice` callback. While either flag is set, `busy_text()` (1299) refuses Add, Re-link, Forget, Link Devices, Adopt/Accept Names, and `resync()` only parks itself in `resync_pending` (1051). Nothing ever times out.
- Trigger: (a) the smart_scene `ctx.http` call at 572 throws synchronously or never calls back: `protect` at 564 logs it but `done` is never invoked, so `resyncing` stays true; (b) `self.ctx.http` at 563 throws before any callback (set at 1055, throw at 1056, no pcall); (c) `AddDevice` never fires its callback (Composer disconnected mid-add). Afterwards every stream reconnect's resync is deferred forever and scene state in Control4 goes stale until reload.
- Fix: wrap `fetch_all`'s inner http call so any failure reaches `done(nil, err)`, pcall the `fetch_all` call in `resync`, and guard both flags with a timer (or let Refresh Scenes clear them).

### F2. `resync_pending` keeps only the latest `done`; earlier callers are never called — Medium
- scenes.lua:1052, 1080-1086.
- What: a second `resync(done2)` arriving while one is in flight (or while adding) overwrites `resync_pending`, so `done1` is silently dropped.
- Trigger: stream reconnect resync queued during Add All, then the owner clicks Refresh Scenes; the coordinator's connect-time `done` (status property, chained steps) never runs.
- Fix: keep a list of pending `done`s and invoke all of them from one coalesced resync.

### F3. Recall callback sends stale state after a later OFF, delete, or stream event — Medium
- scenes.lua:1232-1247; off at 1291-1293; delete at 1116-1125.
- What: the PUT callback unconditionally sets `scene.active = resulting` and sends `STATE resulting` when `r.ok`, checking only that the rid still maps to the same device (1235).
- Triggers: (1) recall then OFF inside the coalescing window: OFF already sent `inactive`; the recall response arrives and flips the switch back to active until the stream's inactive event (never, if the stream is down). (2) scene deleted on the bridge while the PUT is in flight: the entry is now `gone`, yet the callback sends `STATE static` for a gone scene (the captured `scene` table is detached from the catalogue, so the `scene.active` write is lost but the message still goes out). (3) a stream update already reported `dynamic_palette`; the callback computes `static` from a stale `auto_dynamic` and overwrites the catalogue. (4) two recalls of scenes in one room: both callbacks say active; only the stream corrects the loser.
- Fix: keep a per-rid command generation counter; in the callback, bail if the generation changed, if `current.state ~= "linked"`, or if `self.catalogue[rid] ~= scene`, and otherwise send `current_active(rid)`.

### F4. `off` reports inactive even when the grouped_light off was not issued — Medium
- scenes.lua:1285-1286, 1291-1293.
- What: `ctx.group_off(grouped)` returns a boolean (the default returns false, 87-90) but the result is ignored; `called = true`, `scene.active = "inactive"` and `STATE inactive` go out regardless.
- Trigger: driver queue refuses (no transport, rate limit, bridge offline): the switch shows OFF while the lights stay on and the scene stays `static`, so no stream event ever corrects it.
- Fix: honour the return value (or give `group_off` a callback) and send the inactive state only when the off was actually queued/acknowledged.

### F5. An empty but 200 `/scene` response marks every imported scene gone — Medium-Low
- scenes.lua:568-570, 595-605, 1004-1009.
- What: `data = {}` passes the `type(items) == "table"` check, `absorb` replaces the catalogue with an empty one, and `reconcile_scenes` sets every linked entry `gone` with `gone_since`, sends CONFIGURE gone + STATE inactive to all devices, and fills Attention.
- Trigger: Bridge Pro returning an empty list during boot or a partial outage. The next resync relinks them, but `gone_since` stamps and the attention churn remain in the log.
- Fix: treat an empty `data` while the registry has linked entries as suspect (check the body's `errors` array, or require two consecutive empties before marking gone).

### F6. Scene rids are not validated before being spliced into the request path — Low-Medium
- scenes.lua:1232 (`SCENE_PATH .. "/" .. rid`); hue_model.lua:549-553 (`item.id ~= nil`, any type); scenes.lua:822-872 (hello adopts any non-empty string rid once the device is bound).
- What: `entry_for_command` only checks "non-empty string, in registry". The registry is fed by the catalogue (bridge JSON `id`, unvalidated) and by `HUE_SCENE_HELLO.rid` from a scene device's persisted data. A rid like `../grouped_light/<x>?` or one containing `#` becomes part of the PUT URL.
- Trigger: a tampered or restored-from-backup scene device announcing a crafted rid while bound; or a bridge returning a non-UUID id.
- Fix: accept only `^[%w%-]+$` rids in `hue_model.scene`, `hello`, and `entry_for_command`; also drop non-string `item.id` (a table-typed id is a fresh table key on every `add` event, growing the catalogue, scenes.lua:1099).

### F7. `groups:rebuild` can crash on mixed-type child rids — Low
- groups.lua:105 (`table.sort(roomless)`), hue_model.lua:401-404 (`ref.rid ~= nil`, any type).
- What: `roomless` is a plain-sorted array of rids; if bridge_home children carry a number and a string (or a table), `table.sort` raises "attempt to compare", aborting `absorb` or `apply` inside OnBodyChunk.
- Fix: `text(ref.rid)` in `update_group`, or sort with a `tostring` comparator.

### F8. Forget Scene can be undone by the device's own hello — Low-Medium
- scenes.lua:1726-1736 vs 859-876.
- What: `forget` removes the entry, sends `HUE_SCENE_FORGOTTEN`, then unbinds; the unbind is pcall-wrapped and may fail (1733-1735). A hello from that device carrying its rid, while it is still bound and the rid is unregistered, is auto-adopted at 872 ("from its own persisted rid").
- Trigger: unbind fails, or the device's hello (sent on its own late init) is processed before it handles FORGOTTEN.
- Fix: remember forgotten `(device_id, rid)` pairs in memory and refuse auto-adoption for them; let Link Devices be the explicit path back.

### F9. Recalls are not coalesced; rapid taps hit the bridge's grouped-command limit — Low-Medium
- scenes.lua:1232.
- What: every `HUE_SCENE_RECALL` is a direct PUT; `off` goes through the driver's coalescer but recall does not. A keypad double-tap or a programming loop sends N PUTs; the bridge answers 429 for the extras and the callback sends the cached (now wrong) status.
- Fix: drop a recall for a rid that already has a PUT in flight (or route it through the group queue keyed by `group_rid`).

### F10. Stale `conflicts` are never cleared when the claimant disappears without a goodbye — Low
- scenes.lua:839, 866, 1660 set; cleared only at 782-788, 902-904, 972-973, 1583, 1729.
- What: a claimant device deleted in Composer while the bridge is not watching never sends GOODBYE; `reconcile` clears conflicts only for tombstoned rids, so the "2 devices claim" Attention item persists until reload.
- Fix: in `reconcile`, drop conflicts whose holder or claimant is absent from the bound/present sets.

### F11. `date_of` / `short_date_of` crash on a non-number timestamp — Low
- scenes.lua:181-193; used in 1213, 1495, 1885, 1961, 2039.
- What: `os.date(fmt, ts)` errors if a persisted `gone_since`/`deleted_at`/`unbound_since` is a string; it would take Attention, pickers and recall-of-gone down together.
- Fix: `tonumber(ts)` with a `"?"` fallback.

### F12. `duration` is unbounded — Low
- scenes.lua:1227-1228.
- What: `positive("1e400")` is `inf`; `math.floor(inf)` is `inf`, which the JSON encoder either rejects (throwing inside the command handler) or emits as invalid JSON.
- Fix: clamp to an integer range (Hue accepts up to a few minutes in ms).

### F13. Lights: a JSON-null name becomes "table: 0x…" — Low
- hue_model.lua:105, 109 (`tostring(item.metadata.name)` with only a `~= nil` check), vs the type-checked scene path at 499.
- Fix: use `text()` as `update_scene` does.

## Checked and sound
- No untrusted string is used as a Lua pattern or as a `string.format` format string; names always travel as arguments (`norm`, `sanitise` apply constant patterns to untrusted subjects only).
- Catalogue decode is linear and compact (`actions`/`palette` dropped, hue_model.lua:548-568); no recursion over the JSON; no quadratic string building (`table.concat` everywhere). Only waste: scenes.lua:1011 sorts all unimported scenes just to log a debug count.
- `last_configure`, `announced`, `early_hellos`, `empty_groups` are bounded by registry/device counts and cleared on goodbye/forget/relink/reconcile; no timers live in these modules; per-resync closures are two.
- Recall callback correctly ignores a re-linked or forgotten rid (1234-1236); `relink` clears both rids' caches (1582-1584).
- Resync is deferred while adding and adds are refused while resyncing, so the catalogue is not swapped under an Add All job; stream deletes mid-job only yield a linked entry that the next resync marks gone (converges).
- `groups:absorb` drops only the types present in the GET, so a partial fetch keeps the others; `apply` ignores type mismatches on a rid.
- Registry mutations are memory-first with one `flush()` per batch, and `save()` after every AddDevice; `bind` before `reg:add` can leave a bound-but-unregistered device on refusal, which Link Devices recovers.
- `scene_state_params` maps unknown `status.active` strings to `inactive` (698); event items are type-checked field by field (hue_model.lua:493-537).
