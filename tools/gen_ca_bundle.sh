#!/usr/bin/env bash
# Regenerate the two derived forms of the Signify root CAs from the PEM files
# in src/hue_bridge/certs/:
#   src/hue_bridge/certs/hue_ca_bundle.pem   shipped in the .c4z; C4:url reads
#                                            it as ssl_cabundle="certs/..."
#   src/hue_bridge/bridge/ca_bundle.lua      embedded copy, written to the
#                                            sandbox for the fallback option
# tests/spec/certs_spec.lua fails if either drifts.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERTS="$ROOT/src/hue_bridge/certs"
OUT="$ROOT/src/hue_bridge/bridge/ca_bundle.lua"
BUNDLE="$CERTS/hue_ca_bundle.pem"
cat "$CERTS/hue_root_bridge.pem" "$CERTS/hue_root_ca_01.pem" > "$BUNDLE"
echo "wrote $BUNDLE"
{
	echo "-- Signify's two root CAs for Hue bridge certificates, as one PEM bundle."
	echo "-- GENERATED from src/hue_bridge/certs/*.pem by tools/gen_ca_bundle.sh; do not edit."
	echo "-- Embedded as a string so the driver can write it to its sandbox at startup"
	echo "-- instead of depending on where the controller unpacks the .c4z."
	echo "return [["
	cat "$CERTS/hue_root_bridge.pem" "$CERTS/hue_root_ca_01.pem"
	echo "]]"
} > "$OUT"
echo "wrote $OUT"
