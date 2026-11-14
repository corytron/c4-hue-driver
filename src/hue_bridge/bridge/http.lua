-- HTTPS client for the Hue bridge: the shared core (common/https.lua)
-- configured for the bridge (#514, docs/hdmi-sync-stage1-design.md §3).
-- This module is that instance itself, not a copy, so every field a caller
-- or a spec reads or sets (http.ca, http.MAX_KEYED, ...) is the one the
-- requests use; a fresh require after package.loaded["bridge.http"] = nil
-- is a fresh instance with its own keyed queue.
--
-- Every request verifies the bridge certificate against the Signify roots.
-- Hostname verification is off because the certificate's CN is the bridge ID,
-- not the IP; the bridge ID is checked at the application layer instead (see
-- bridge/pairing.lua and docs/design.md).
--
-- The CA bundle ships inside the .c4z as certs/hue_ca_bundle.pem and is
-- referenced relative to the archive: on OS 3.4.2, C4:url prefixes
-- ssl_cabundle with the extracted archive's directory, and the option
-- replaces the system CA bundle, so trust is pinned to the two Signify roots
-- (spike runs 4 and 5; see docs/design.md). http.ca is the bundle in use,
-- { path = <file inside the archive> }; nil fails every request.
--
-- A request may adjust the TLS options through req.tls (http.options): the
-- development diagnostics (bridge/conntest.lua and bridge/pinning.lua, dev
-- builds only) and the TLS self-check (bridge/tlscheck.lua). No keyed
-- request does: bridge_request in hue_bridge/driver.lua clears req.tls.
--
-- A keyed request (req.key) carries the application key in the
-- hue-application-key header and refuses redirects. At most MAX_KEYED (3)
-- are in flight at once, the rest wait (security review 2026-11-13, N-8,
-- #489): Director runs at most four C4:url transfers at once,
-- controller-wide [verified: hardware, docs/design.md "Concurrent
-- transfers"], so three leave one for every other driver while the bridge
-- does not answer. The event stream's transfers are not counted
-- (bridge/stream.lua caps its own, bridge/netstream.lua holds none).
--
-- The fields and functions, as before the move (common/https.lua documents
-- each): DEFAULT_TIMEOUT, CONNECT_TIMEOUT, MAX_KEYED, SLOT_GRACE_S, TEXT_ROW,
-- TEXT_LOG, CA_BUNDLE, ca, CERTIFICATE_ERRORS, INVALID_PATH; peer_text,
-- options, certificate_failure, url, decode, request, stream.

local https = require("common.https")

return https.new({
	-- Path inside the archive, see tools/gen_ca_bundle.sh.
	ca_bundle = "certs/hue_ca_bundle.pem",
	header_key = "hue-application-key",
	max_keyed = 3,       -- keyed requests in flight at once (see the header)
	timeout = 15,
	connect_timeout = 5,
	slot_grace_s = 10,   -- beyond a transfer's own timeout, before its slot is freed regardless
	-- The most bytes of peer text (http.peer_text) in a Composer row, Status
	-- or Attention, and in a log line (security review 2026-11-13, #489).
	text_row = 256,
	text_log = 2000,
	-- No body cap (max_body unset): the bridge's answers were never capped,
	-- and stage 1 changes nothing the bridge does.
	log_prefix = "",
})
