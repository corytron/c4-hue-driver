#!/usr/bin/env bash
# The Hue Sync Box driver end to end against the Python fake box (#547,
# docs/fakebox-design.md §6): the real src/hue_syncbox/driver.lua, run in
# lua5.1 with the fake runtime, its C4:url over real HTTPS through curl
# (tests/helpers/real_url.lua) to tools/fakebox.py, walking the owner's flows
# (tests/e2e/syncbox_e2e.lua). Not part of `busted tests` or CI: it needs
# curl and listening sockets. tools/check.sh --only e2e runs it.
#
# Usage: tools/e2e_syncbox.sh [--only SUITE[,SUITE...]] [--trace] [--keep]
#   --only   run only these suites of tests/e2e/syncbox_e2e.lua: pinning,
#            flows, faults, devhooks, models (default all, in that order)
#   --trace  print every HTTPS exchange of the transport
#   --keep   keep the temporary directory (the fake's log, the driver's log)
#
# What it does, in a private temporary directory (several runs at once do not
# meet: their own CA, their own state directory, ports the system picks):
#   1. a CA for this run (tools/fakebox/ca.py ca under the directory) and
#      the archive the transport reads as the extracted .c4z: its
#      certs/hsb_ca.pem the repository's bundle followed by that CA, its
#      certs/decoy.pem the repository's decoy;
#   2. the fake (tools/fakebox.py serve) with five boxes, each on a port of
#      127.0.0.1 the system picks, read back from its server.json: HSB2
#      0A1B2C3D4E5F (the flows), HSB2 0A1B2C3D4E60 (another box at the same
#      address), then HSB1, HSB3 and HSB3_standalone (0A1B2C3D4E61 to
#      0A1B2C3D4E63); its control API on another such port;
#   3. lua5.1 tests/e2e/syncbox_e2e.lua with that environment (E2E_*), one
#      PASS/FAIL/SKIP line per check and a summary;
#   4. the fake stopped (also on failure or interruption).
# Exit 0 when every check passed, 1 when one failed, 2 when the run could not
# start (a tool or file missing, the fake not starting).
#
# Environment:
#   TIME_SCALE       real seconds per second of the driver's fake clock for
#                    curl's timeouts (default 0.25: a silent box costs 1.5 s
#                    a read instead of the driver's 6 s)
#   FAKE_TIME_SCALE  the fake's --time-scale (default 10: its 30 s restart
#                    takes 3 s; the pairing window is held open longer, see
#                    the Lua script)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ONLY=""
TRACE=""
KEEP=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--only)
		[[ $# -ge 2 ]] || {
			echo "e2e: --only needs a suite list" >&2
			exit 2
		}
		ONLY="$2"
		shift 2
		;;
	--trace)
		TRACE=1
		shift
		;;
	--keep)
		KEEP=1
		shift
		;;
	-h | --help)
		sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		echo "e2e: unknown argument $1 (see --help)" >&2
		exit 2
		;;
	esac
done

TIME_SCALE="${TIME_SCALE:-0.25}"
FAKE_TIME_SCALE="${FAKE_TIME_SCALE:-10}"

for tool in curl lua5.1 python3 openssl; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "e2e: $tool is not installed" >&2
		exit 2
	fi
done
for file in tools/fakebox.py tools/fakebox/ca.py tools/fakebox/mdns.py tests/fixtures/hue_syncbox.json; do
	if [[ ! -f "$file" ]]; then
		echo "e2e: $file is missing (docs/fakebox-design.md §4, §5)" >&2
		exit 2
	fi
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/c4e2e.XXXXXX")"
case "$WORK" in
*[[:space:]]*)
	echo "e2e: the temporary directory $WORK holds white space; set TMPDIR to a path without" >&2
	rm -rf "$WORK"
	exit 2
	;;
esac
STATE="$WORK/state"
FAKEBOX="python3 -I tools/fakebox.py --state-dir $STATE"
FAKE_PID=""

# shellcheck disable=SC2317,SC2329 # run by the EXIT trap
cleanup() {
	if [[ -n "$FAKE_PID" ]]; then
		kill "$FAKE_PID" 2>/dev/null || true
		wait "$FAKE_PID" 2>/dev/null || true
	fi
	if [[ -n "$KEEP" ]]; then
		echo "e2e: kept $WORK"
	else
		rm -rf "$WORK"
	fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# 1. The CA and the archive.
CA_PEM="$(python3 -I tools/fakebox/ca.py --base "$WORK/ca" ca)"
mkdir -p "$WORK/archive/certs"
cat src/hue_syncbox/certs/hsb_ca.pem "$CA_PEM" >"$WORK/archive/certs/hsb_ca.pem"
cp src/hue_syncbox/certs/decoy.pem "$WORK/archive/certs/decoy.pem"

# 2. The fake: five boxes and the control API, every port the system's pick.
BOXES=(HSB2:0A1B2C3D4E5F HSB2:0A1B2C3D4E60 HSB1:0A1B2C3D4E61 HSB3:0A1B2C3D4E62 HSB3_standalone:0A1B2C3D4E63)
serve_args=(serve --port 0 --control-port 0 --cert-base "$WORK/ca" --time-scale "$FAKE_TIME_SCALE")
for box in "${BOXES[@]}"; do
	serve_args+=(--box "$box")
done
# shellcheck disable=SC2086 # FAKEBOX is a command and its fixed options
$FAKEBOX "${serve_args[@]}" >"$WORK/fake.log" 2>&1 &
FAKE_PID=$!

# Each box as FIXTURE:ID:PORT, in the order above, from server.json (written
# once every box and the control API listen); nothing while it is not there.
ports_of() {
	python3 -I -c '
import json, sys, urllib.parse
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        info = json.load(f)
except (OSError, ValueError):
    sys.exit(1)
port = {b["id"]: urllib.parse.urlsplit(b["url"]).port for b in info.get("boxes", [])}
out = []
for spec in sys.argv[2:]:
    fixture, box_id = spec.split(":")
    if box_id not in port:
        sys.exit(1)
    out.append("%s:%s:%s" % (fixture, box_id, port[box_id]))
print(" ".join(out))
' "$STATE/server.json" "${BOXES[@]}"
}

SPECS=""
for _ in $(seq 1 100); do
	if SPECS="$(ports_of 2>/dev/null)"; then
		break
	fi
	if ! kill -0 "$FAKE_PID" 2>/dev/null; then
		echo "e2e: the fake exited at start:" >&2
		cat "$WORK/fake.log" >&2
		FAKE_PID=""
		exit 2
	fi
	sleep 0.2
done
if [[ -z "$SPECS" ]]; then
	echo "e2e: the fake did not start within 20 s:" >&2
	cat "$WORK/fake.log" >&2
	exit 2
fi
read -r MAIN OTHER M1 M2 M3 <<<"$SPECS"

# 3. The flows.
status=0
E2E_ARCHIVE="$WORK/archive" \
	E2E_ADDRESS="10.0.2.150" \
	E2E_MAIN="$MAIN" \
	E2E_OTHER="$OTHER" \
	E2E_MODELS="$M1,$M2,$M3" \
	E2E_FAKEBOX="$FAKEBOX" \
	E2E_TIME_SCALE="$TIME_SCALE" \
	E2E_FAKE_TIME_SCALE="$FAKE_TIME_SCALE" \
	E2E_ONLY="$ONLY" \
	E2E_TRACE="$TRACE" \
	E2E_LOG="$WORK/driver.log" \
	TMPDIR="$WORK" \
	lua5.1 tests/e2e/syncbox_e2e.lua || status=$?

# 4. The fake stopped (the trap kills it on any other way out).
# shellcheck disable=SC2086 # FAKEBOX is a command and its fixed options
$FAKEBOX stop >/dev/null 2>&1 || true
if [[ "$status" -ne 0 && -z "$KEEP" ]]; then
	echo "e2e: run again with --keep to keep the fake's log and the driver's"
fi
exit "$status"
