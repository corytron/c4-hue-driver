#!/usr/bin/env bash
# Regenerate src/hue_bridge/bridge/ca_bundle.lua from the PEM files in
# src/hue_bridge/certs/. tests/spec/certs_spec.lua fails if they drift.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERTS="$ROOT/src/hue_bridge/certs"
OUT="$ROOT/src/hue_bridge/bridge/ca_bundle.lua"
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
