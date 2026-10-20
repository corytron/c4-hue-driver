# Spike checklist: pairing and the event stream

Run in Composer Pro with the `hue_bridge.c4z` from this branch. The light
driver is unchanged. Write down the exact property text and Lua output at
each step; the wording is designed to tell us which code path ran.

Set `Debug Mode` to On before starting and keep the Lua output window open.

## A. Update and pair

1. Drivers → Add or update drivers → update `hue_bridge.c4z`. The existing
   bridge device keeps its IP. `Driver Version` shows the new build.
2. New properties appear: `Bridge Model`, `Event Stream`, `Events Received`,
   `Last Event`, `Stream Timeout (s)` = 3600, `Stream Watchdog (s)` = 300.
   `Event Stream` reads "Not paired". `Status` must *not* say "Certificate
   install failed"; if it does, copy the message and stop here.
2a. As soon as an IP is set the driver probes four ways of handing the CA
   bundle to `C4:url` against `/api/0/config`. Expected Lua output:
   `CA probe cabundle certs/ in archive  OK` (the bundle shipped inside the
   .c4z), `cabundle sandbox relative` FAIL or OK (tells us whether the base
   directory is the archive or the sandbox), `cacerts sandbox absolute OK`
   (known from run 4), `insecure OK`. `CA Mode` should read
   `ssl_cabundle=certs/hue_ca_bundle.pem`. Copy the four lines.
   Then Actions → **Check CA Pinning**: `Status` should end with "Pinning
   check passed". "FAILED" would mean the bundle doesn't replace the system
   CAs; "inconclusive" means the controller couldn't reach example.com.
2b. Actions → **Diagnose Certificates** is optional now; run 4 answered the
   directory questions. **Probe CA Paths** re-runs the probe at any time.
3. Actions → **Pair Bridge** *without* pressing the link button.
   - Expect `Bridge Model` = `BSB002` (or `BSB003` on a Bridge Pro) and
     `Status` = "Press the link button on the bridge, then run Pair Bridge
     again".
   - **If instead** `Status` says "Pairing failed: Bridge not reachable: …",
     copy the whole message. An SSL/certificate error here is the most
     important single result of the spike.
4. Press the bridge's link button, then **Pair Bridge** again within 30 s.
   - Expect `Status` = "Paired", `Bridge ID` = 16 hex digits, and
     `Event Stream` = "Connecting" then "Connected since HH:MM:SS".
4a. Actions → **Reload Credentials**. Expect `Status` = "Stored credentials
   readable and match memory". "NOT readable" a minute after pairing would
   mean the encrypted store doesn't return the key at all, which step 12
   would also show.
5. Actions → **Test Connection**. Expect `Status` = "Test OK: HTTP 200,
   bridge <id>". Anything else: copy it.

## B. Does the stream arrive live?

6. Note the time. In the Hue app, toggle one light. Watch `Events Received`
   and `Last Event`.
   - **Live:** the count goes up and `Last Event` shows the current time
     within about 1–2 s. (The bridge batches to one container per second.)
   - **Not live:** nothing changes until the stream ends (step 8). This
     means `OnBodyChunk` buffers, and we switch to the fallback design.
   - Also toggle it a few times quickly and note whether `Events Received`
     rises by the number of toggles or fewer.
7. In the Lua output, each event logs as `event <id> update: light`. Note
   whether any lines appear that are *not* from your toggles; those would be
   keepalives or other devices.

## C. Timeout and reconnect

8. Set `Stream Timeout (s)` to 60, press Set. `Event Stream` goes through
   "Stopped" / "Connecting" / "Connected since". Wait 60–70 s.
   - Expect `Event Stream` = "Disconnected: transfer error 28: …
     Reconnecting in 1 s", then "Connected since" with a new time.
   - Record the exact error text and whether the controller honoured 60 s
     or cut off earlier.
9. Set `Stream Timeout (s)` to 86400 (the max) and Set. Wait two minutes
   and toggle a light: it should still arrive. Record whether the
   controller accepted the value (the transfer must not end at 300 s, the
   `C4:url` default).
10. Set `Stream Watchdog (s)` to 30 and Set. Do nothing for 40 s. Expect
    "Disconnected: watchdog: no data for 30 s. Reconnecting in 1 s" then
    reconnection. (If you see keepalive counts rising in the debug log
    instead, the bridge sends heartbeats and the watchdog never fires;
    record that too.) Put it back to 300 afterwards.
11. Unplug the bridge's Ethernet cable for 30 s. Expect "Disconnected: …"
    with growing "Reconnecting in N s" values (1, 2, 4 …), then
    "Connected since" within a minute of plugging it back in.

## D. Restart and soak

12. Restart Director. Expect `Status` = "Paired" and `Event Stream` =
    "Connected since" without touching anything (the key came from
    encrypted persistent storage). Toggle a light to confirm.
13. Leave it running for at least an hour with the defaults. Then note
    `Event Stream`, `Events Received`, and whether the Lua output shows
    any reconnects or errors.
14. Actions → **Forget Pairing**: `Status` returns to "Not paired",
    `Event Stream` = "Stopped". Pair again afterwards (steps 3–4).

## What to report

For each step, the property text and any Lua output lines. For steps 3, 6,
8 and 9, the result decides the design, so exact wording matters there.
