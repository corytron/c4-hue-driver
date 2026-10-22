# Analysis 2: lights.lua + registry.lua

Files: `src/hue_bridge/bridge/lights.lua` (2600 lines), `src/hue_bridge/bridge/registry.lua` (566 lines). Read-only review.

## Findings

### R1. `importing` / `resyncing` guard has no deadline (Medium)
- lights.lua:1647, 1680 set `importing = true`; it is cleared only inside the AddDevice / fetch callback chain (1650, 1684). lights.lua:1290 same for `resyncing`.
- If an AddDevice callback never fires (Composer disconnects mid-add, Director swallows the error, the http layer never calls back) the flag stays set for the life of the Lua state. Every action then returns "Busy: importing" (1501-1508) and every `resync()` is parked in `resync_pending` (1286-1288), so stream reconnects stop refreshing state until a reload.
- Fix: have driver.lua arm a one-shot timer when a job starts and clear the flag (logging "import abandoned") if `finish` has not run after N minutes.

### R2. Post-add reconcile can tombstone or unbind the device just created (Medium, hardware-dependent)
- lights.lua:1562 registers the entry, 1651/1762 run `reconcile(true)` in the same callback chain, registry.lua:512-520 decide by `bound` then `present`.
- If `GetBoundConsumerDevices` does not yet reflect the `C4:Bind` issued at 1550 (asynchronous in Director) the new entry is not in `bound`; if `GetDevices` already lists it, it flips to "unbound" (519) and is skipped by events (1393) until `OnBindingChanged` arrives; if `GetDevices` also lags, it is **tombstoned** (517) with a spurious "deleted in Composer while the bridge was not watching" warning, removed from the registry, and only recovers when the light's next hello re-adopts it.
- Fix: in `reconcile`, skip entries created in this batch (or with `created_at` within the last ~60 s), or defer the post-add reconcile to the next resync.

### R3. Bound-set nil read as "nothing bound" (Medium, assumption to verify)
- lights.lua:529-543: `project_bound_set` turns a nil `GetBoundConsumerDevices` into an empty set (comment cites API 32/_3). If Director can return nil transiently at startup, the late-init `reconcile` moves **every** linked entry to "unbound" (registry.lua:519), persists it, and the fan-out (1240) and event path (1393) skip all lights until the next resync re-links them. With GetDevices also empty nothing is tombstoned, so it self-heals, but there is a dead window after boot.
- Fix: treat nil as unknown when the registry has linked entries and GetDevices is also empty, or skip the late-init reconcile until the first successful resync.

### R4. `save()` write order lets a crash drop a tombstone (Low-Medium)
- registry.lua:260-266 writes `lights`, then `rooms`, then `tombstones`. `tombstone()` (460-470) moves a rid from `lights` to `tombs`. A reload/crash between the first and third PersistSetValue leaves the rid in neither table: the deleted device's light shows as "new" and Import All New Lights re-creates the device the owner deleted (the §3 forbidden outcome).
- Fix: write `tombstones` before `lights` (the crash window then yields entry + stale tombstone, which is harmless because `unimported_models` excludes registered rids).
- Related, flagged in-file as an assumption (registry.lua:29-32): if PersistGetValue can return the pre-save value after a reload, a reload right after an import loses the entries and the next import duplicates devices. Worth a hardware check.

### R5. Stale `announced` entries produce false conflicts (Low-Medium)
- lights.lua:1008 stores every hello; it is cleared only by goodbye (1067), forget (1976) and forget_request (2003). `relink()` (1780-1823) and `reconcile`'s tombstone path (1153-1159) leave `announced[device].rid` pointing at the old rid.
- Trigger: device A is re-linked from X to Y; a restored or re-bound device D later hellos with rid X. lights.lua:1039-1045 sees `announced[A].rid == X` and reports "devices A and D both announce X; neither adopted", although A no longer holds X. lights.lua:1905 (Link Devices) reads the same stale table. Memory-only; a reload clears it.
- Fix: in `relink` set `announced[device_id].rid = new_rid`, and clear `announced[entry.device_id]` for tombstoned rids in `reconcile`.

### R6. Light deleted on the bridge during an in-flight AddDevice (Low)
- `add_light` checks `self.models[rid]` at OK time (1618), which covers "deleted between picker and OK". But `on_container` can run between AddDevice callbacks (1370 sets `models[rid] = nil`) while `jobs` still holds the model; `on_added` (1555) registers it anyway and `push` (1566) finds no model and sends nothing. Result: a linked device for a light that is gone; the next resync marks it gone. Correct eventually, but the "Added" text is misleading.
- Fix: in `add_next` skip jobs whose `self.models[job.model.rid]` is nil and count them as failed.

### R7. `early_hellos` grows unbounded before `load()` (Low)
- lights.lua:1001-1005 appends every pre-load hello with no de-duplication by device. If driver.lua delays `load()`/`configure_all()` (unpaired bridge, init error) and 50 light drivers retry hello on a timer, the list grows without limit; `configure_all` (940-944) then answers each duplicate.
- Fix: key the queue by `device_id or rid` (last hello wins).

### R8. Unpruned memory-only maps (Low)
- `announced_new` (1194, 1362) is never cleared, not even on light delete (1370): bounded by distinct rids ever seen, but a light re-added with the same rid is never logged as new again.
- `offline_since` (754) is cleared only for models present in the current GET or on a delete event; rids that vanish from `/light` keep their stamp.
- `macs` (785, 1409) accumulates per device rid; only device delete events prune it.
- `conflicts` set from hello (1014) persists until the claimant says goodbye or is forgotten; a claimant deleted in Composer without a goodbye (bridge offline) and never registered is not tombstoned by reconcile, so the Attention item stays until reload.
All bounded by physical device counts; none is per-resync growth.

### R9. `refresh_registry` cannot clear a field that became nil (Low)
- lights.lua:842-847 builds `changed` from `fields`, in which nil values (device record missing, mac unknown) are invisible to `pairs`, so a stale `mac_address`, `device_name` or `model` persists forever and `relink_hint` (611) may match by a MAC the device no longer has. Fix: use `registry.CLEAR` for keys whose model-derived value is nil.

### R10. Clock assumptions (Low)
- `deleted_at`, `gone_since`, `unbound_since`, `created_at` use `now()` (registry.lua:357, 411, 466); `offline_since` is compared with `now - since >= 24h` (lights.lua:2414). A controller booting with a wrong clock stamps 1970 dates; an NTP jump forward makes the offline nag fire immediately for lights seen offline at boot, a jump backward silences it. Cosmetic, except an R2 fix of "created within 60 s" must tolerate this.

### R11. Hello `name`/`model` stored untyped (Low)
- lights.lua:974-975 copy `hello.name`/`hello.model` into the entry unchecked. Everything that renders them goes through `tostring` (sanitise, label) except lights.lua:2088 and 2388, which pass `d.entry.name` straight to `string.format("%s")`; on plain Lua 5.1 a non-string errors inside the Attention property text. Params from `SendToDevice` arrive as strings in practice, so this needs a misbehaving light driver. Fix: `tostring()` in `adopt`.

## Checked and sound
- No untrusted string reaches a pattern position: `norm`, `sanitise`, `v1_tag`, `role_of` (`find` with `plain=true`, 217) and `dump` use fixed patterns; names are always `%s` arguments, never format strings; every `%d` receives a `positive()`-coerced number.
- Picker texts are comma-sanitised everywhere (`light_label`, `entry_label`, `picker_rooms`, `picker_hue_rooms`, `picker_relink_devices`).
- JSON shape checks: `fetch_all` (738-741), `on_container` (1471-1477), `absorb` (768, 782), `on_device_item` (1440); nil-key table reads are safe in Lua.
- Double adoption is prevented structurally: `registry:add` refuses "exists" and "device exists" (339, 347-350); Link Devices adopts in sequence so a second same-name device cannot match the now-registered light (1921-1924); `hello` prefers the registry (1011), then the device's own held rid (1024).
- Reconcile iterates a snapshot (`rids()`), so tombstoning inside the loop is safe; an empty `present` is treated as unknown (503-508).
- A wrongly tombstoned but still bound device self-heals: its hello carries the rid, `adopt` -> `add` clears the tombstone (360).
- Goodbye identifies by device first (1059), so a stale persisted rid after re-link tombstones the right entry.
- Every callback body is pcall-wrapped (`protect` 160; resync 1295; create_lights 1572; import 1694), so a Lua error cannot leave `importing`/`resyncing` set (only a missing callback can, R1).
- `load()` refills the same tables, so `self.registry` identity holds across reload (registry.lua:224-226).
- `set_state` keeps exactly one timestamp per state (407-412); `normalise_entry` strips stale stamps (207-211).
- Room-name collisions in `by_key`/`shared` are counted deliberately, not silently overwritten (1893, 2197-2202).
