-- The bridge's TLS self-check (issue #53): the shared check
-- (common/tlscheck.lua, which documents what it proves and what it cannot)
-- configured for the Hue bridge (#514, docs/hdmi-sync-stage1-design.md §3).
-- This module is that instance itself; a fresh require after
-- package.loaded["bridge.tlscheck"] = nil is a fresh instance, which has
-- forgotten this run's "pinned" answer (only the store carries it over).
--
-- Every bridge request pins trust to the two Signify roots by naming them as
-- ssl_cabundle (bridge/http.lua). Once the bridge has passed the (unkeyed)
-- identity check, it is asked once more with the same TLS options but the
-- decoy bundle, certs/decoy_ca.pem (in the same relative form as
-- http.CA_BUNDLE): that request must fail certificate verification.
--
-- The request is GET /api/0/config, the bridge's public configuration, and
-- it never carries the application key: the key goes only to a peer
-- verified against the Signify roots, and this one is verified against
-- nothing. The verdict ("pinned", "not_pinned", "inconclusive") is
-- remembered per Director version under tls_pinned_on, by remember_pinned()
-- when the driver calls it; pinned_before() reads it back (bridge/identity.lua,
-- the TLS gate, docs/design.md "TLS self-check in release builds").
--
-- The fields and functions, as before the move: DECOY_CA, PATH, TIMEOUT,
-- STORE_NAME; run(ip, callback), director_version(), remember_pinned(),
-- pinned_before().

local http = require("bridge.http")

return require("common.tlscheck").new({
	https = http,
	-- Path inside the archive, in the same relative form as http.CA_BUNDLE.
	decoy_ca = "certs/decoy_ca.pem",
	path = "/api/0/config",
	timeout = 10,
	-- The persisted Director version on which the check answered "pinned".
	store_name = "tls_pinned_on",
	label = "TLS check",
})
