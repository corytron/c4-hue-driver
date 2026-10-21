#!/usr/bin/env bash
# Regenerate src/hue_bridge/certs/hue_ca_bundle.pem, the bundle shipped in
# the .c4z and read by C4:url as ssl_cabundle="certs/hue_ca_bundle.pem", from
# the two Signify root PEMs next to it. tests/spec/ca_bundle_spec.lua fails
# if it drifts.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERTS="$ROOT/src/hue_bridge/certs"
BUNDLE="$CERTS/hue_ca_bundle.pem"
cat "$CERTS/hue_root_bridge.pem" "$CERTS/hue_root_ca_01.pem" > "$BUNDLE"
echo "wrote $BUNDLE"
