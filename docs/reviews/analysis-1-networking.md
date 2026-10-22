# Analysis 1: bridge networking and credential layer

Scope: `src/hue_bridge/driver.lua`, `bridge/{http,stream,sse,commands,conntest,pairing,credentials,pinning,altaddr,config}.lua`. Read-only. Paths below are relative to `src/hue_bridge/`.

## Findings

### Re-entrancy and lifecycle

**H1 (high) Messages before late init crash the handler.** `driver.lua:1011` (`HUE_SET`), `:1128` (`HUE_HELLO`), `:811`, `:1145`, `:1199`, `:1216` index `state.lights` / `state.stream`, which are nil until `OnDriverLateInit` (`:1306`, `:1329`). Trigger: controller boot; a light driver's late init sends `HUE_HELLO`/`HUE_SET` before the bridge's late init has run (inter-driver order is not guaranteed), or an owner clicks Forget Pairing / Connection Test early. Result: "attempt to index nil" in the bridge; the light never gets its configuration until its next hello. Fix: a `late_init_done` guard at the top of `dispatch` command handling (queue hellos, drop or report the rest).

**H2 (high) An error inside `http.request`'s OnDone leaves a light's command queue dead.** `http.lua:159` does `responses[#responses]` before checking `err_code`, and `:170` compares `response.code` with no nil check; nothing in that OnDone is pcall-wrapped, and `callback(result)` (`:178`) is only reached if nothing raised. In `commands.lua:239` a light with `inflight` set never flushes again, so one unusual transport result (nil `responses`, response without `code`) silences that light until `stop()`/reload. Same shape in `http.stream` (`http.lua:235`). Fix: build `result` inside a `pcall`, always call the callback (with `ok=false` on error).

**M1 (medium) Stale `choose_stream_address` result after an IP change.** `driver.lua:363-389` captures `family` from the `state.ip` at call time and, in the callback, writes `state.stream_family`/`state.stream_ip` and restarts the stream, with no check that `state.ip` is still the same. Trigger: enter IP A, correct it to B within the 10 s self-check timeout; A's check times out after B's succeeded, so the final state is `stream_family(A)` while commands use B; the stream reconnects to A spellings forever. Fix: capture `state.ip` and a generation counter; ignore the callback when either changed. The same stale capture exists in `pairing.pair(state.ip, ...)` (`driver.lua:457`; `creds.ip` = old IP at `pairing.lua:99`).

**M2 (medium) Unbounded retries replay stale commands.** `commands.lua:289-296`: every transport error/5xx/429 is retried with backoff capped at 8 s and no failure cap; `bridge_request`'s synchronous "not paired" result (`driver.lua:152`) has `code == nil` so is retriable too. Trigger: bridge offline for 20 minutes while several sliders were moved; each light re-PUTs every 8 s (each a 5 s connect timeout, serialised by Director's per-host queue), and when the bridge returns all the minutes-old states land, overriding whatever the Hue app set meanwhile. Fix: cap retries by count or age (drop after ~30 s) and treat "not paired" as non-retriable.

**M3 (medium) Stream properties have no bounds.** `driver.lua:141, :296`: `Stream Timeout (s)` = 0 gives `C4:url` timeout 0 (likely infinite); in single-queue mode (`:145`) that blocks every command forever behind the stream. A watchdog of 1-5 s (shorter than the bridge's keepalive interval) causes a reconnect+full-resync storm (lights GET plus the 351 KB scene catalogue on every cycle, `:302-321`), each cycle abandoning a transfer that holds a spelling queue (`stream.lua:106-114`). Fix: clamp timeout to [30, 86400] and watchdog to [60, timeout) when read.

**L1 (low) Abandoned-transfer events are delivered twice and overwrite status.** `stream.lua:169-181`: after a watchdog reconnect the old transfer stays open until its next chunk, so that chunk arrives on both the old (gen-mismatch path) and the new stream; `handle_event` (`:233-256`) then double-counts and writes "Connected since nil, ..." to the Event Stream property while the current stream may be `waiting`. Fix: in the gen-mismatch path deliver containers but skip stats/status, or skip delivery when the new stream is already `connected`.

**L2 (low) `OnDriverDestroyed` does not fence late callbacks.** `driver.lua:1348-1358` stops stream and queues but not: the `choose_stream_address` GET (`:377`, callback restarts the stream), pairing (`:457`), the 1 s reconcile timer (`:1245`), conntest's timer (`conntest.lua:137`). If Director delivers these after destroy they recreate a stream. Fix: a `destroyed` flag checked in `restart_stream` and the callbacks.

**L3 (low) Stream stuck in `connected` is not restartable.** `stream.lua:118` returns early when state is `connected`; if `handle_chunk` raises inside OnBodyChunk (an `on_container` consumer error, `:251`) the rest of that chunk's events are lost and, if Director aborts the transfer without an OnDone, the state never changes; Connect Event Stream then does nothing. Fix: pcall around `on_container` per container; let `start()` force a reconnect when `transfer == nil`.

**L4 (low) 401/403 on the stream is retried like an outage.** `stream.lua:192-195` aborts, `:275-292` reconnects with backoff forever; Status stays "Paired". A revoked key is never surfaced as such. Fix: on 401/403 stop the stream and set Status to "key rejected; re-pair".

### Security

**M4 (medium) Dev-only handlers are live in release builds.** `driver.lua:532` (`Hue_Request`: arbitrary method/path/host with the key in the header, `Raw` logs the whole body), `:675` (`Probe_Call`: invokes any `C4` method with JSON args and dumps the result, e.g. `Fn=PersistGetValue Args=["hue_app_key",true]` logs the application key), `:489` (`Test_Connection` with a `Host` param). They are registered unconditionally and reachable by any driver or programming via `SendToDevice`, and the log is shipped to the dev server. Fix: register these only when `devloop ~= nil`.

**M5 (medium) Bridge identity is not verified on the normal paths.** `http.lua:65` turns hostname verification off for the bridge by design, and the documented application-layer check (`:4-6`) exists only in the manual Test Connection (`driver.lua:515`). Pairing records whatever `/api/0/config` claims (`pairing.lua:32`), and neither the stream connect nor the resync compares `bridge_id`. Any Signify-signed device (another Hue bridge) answering at the configured IP receives the key and can feed state. Fix: GET `/clip/v2/resource/bridge` on `on_connected` (or in `choose_stream_address`) and stop with a Status error on mismatch.

**M6 (medium) SSE event size is unbounded.** `sse.lua:88` caps only the partial line; `self.data` (`:62`) accumulates `data:` lines until a blank line with no limit. Trigger: a bridge (or a device per M5) emitting endless `data: x\n` lines each under 1 MB; `event.data` grows until the Lua sandbox exhausts memory, and `C4:JsonDecode` is then handed a multi-MB string. Fix: track accumulated bytes and set `overflowed` past, say, 4 MB. Also `:81-82` re-`sub`s the whole buffer per line (O(n²) for a many-line chunk); walk with a position index and `sub` once.

**L5 (low) Pinning verdict can be a false "pinned".** `pinning.lua:24-31`: any failure without an HTTP code counts as pinned, including "could not start transfer" (CA file unopenable, `http.lua:124`) or a timeout. Fix: require a TLS error code (curl 60/77) for "pinned"; otherwise "inconclusive".

**L6 (low) Unvalidated key type from the bridge.** `pairing.lua:57-58` accepts `success.username` of any type; a table or number would be persisted (`credentials.lua:25`) and sent as a header. Fix: require a non-empty string matching `^[%w%-]+$`.

**L7 (low) `string.format("%s", nil)` in `single()`.** `driver.lua:369` formats `state.ip`, which is nil if the IP was cleared while pairing was in flight (`:477` then `:374`); Lua 5.1 raises. Fix: `tostring(state.ip)`.

**L8 (low) `OnSystemEvent` logs every project event unconditionally** (`driver.lua:1287`, `log.always`, probe events registered in release builds at `:1331`). Noise, not a leak; gate on debug or dev build.

## Checked and found sound

- URL/path construction: `req.ip` comes from `config.parse_ipv4` (strict dotted quad, `config.lua:15-31`) or `altaddr` spellings derived from it; light rids in paths are validated against the registry (`driver.lua:1011`); no format-string misuse (`log.always("%s", text)` at `:699`, `:1038` pass data as arguments); all Lua `find`s on untrusted text are plain (`:1290`, `:27`) or fixed patterns (`sse.lua:57`).
- Secrets: the key is persisted encrypted (`credentials.lua:17, :25`), never written to a property, `summary()` logs length only, `http.request`'s debug line logs URL and body but not headers (`http.lua:153`), the insecure diagnostic target gets no key (`driver.lua:1187`).
- TLS: `insecure` mode only reachable through the dev Connection Test; `system` mode (hostname verified) only for public hosts; relative CA bundle path fails closed (pcall at `http.lua:119-125`).
- Stream timers: watchdog, connected_timer and retry_timer are all cancelled in `stop()`, `drop_transfer()` and `handle_done()`; every callback is generation-gated; `on_connected` is deferred out of OnHeaders (rule 1). Chaining a transfer from OnDone is proven on hardware by pairing (`pairing.lua:84`), so `commands.lua:304` flushing from `on_done` is fine.
- Command queue: one timer per light, cancelled on re-arm and `stop()`; `generation` silences late timers and done(); duplicate done() guarded (`:261`); `lights` map bounded by registered rids; recursion through synchronous callbacks is cut by the `return` at `:297`.
- Spelling rotation persists across reload (`driver.lua:102-113`), so a reload's abandoned transfer does not block the successor.
- `altaddr` only pads octets below 8 (octal-safe); `config.parse_ipv4` rejects leading zeros so user input and generated spellings cannot collide.

## Handoffs outside this slice

`state.lights:resync` may overlap itself under fast reconnects (`driver.lua:302`); whether `lights.lua`/`scenes.lua` guard that, and whether `on_container` consumers can raise (L3), belongs to the lights/scenes analysis.
