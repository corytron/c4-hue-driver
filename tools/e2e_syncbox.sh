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
#            flows, faults, devhooks, models; routing (#557), which is
#            routing-inline, routing-onein, routing-receiver, routing-second
#            and routing-faults; and stage4 (#568), which is programming,
#            buttons, periods, offers, area-name and takeover; each also by
#            its own name (default all)
#   --trace  print every HTTPS exchange of the transport
#   --keep   keep the temporary directory (the fakes' logs, the drivers')
#
# What it does, in a private temporary directory (several runs at once do not
# meet: their own CA, their own state directory, ports the system picks):
#   1. a CA for this run (tools/fakebox/ca.py ca under the directory) and
#      the archive the transport reads as the extracted .c4z: its
#      certs/hsb_ca.pem the repository's bundle followed by that CA, its
#      certs/decoy.pem the repository's decoy;
#   2. the suites in groups that share no box, each group with a fake of its
#      own (tools/fakebox.py serve, its own state directory and log), every
#      port of 127.0.0.1 the system's pick, read back from its server.json:
#      pinning to models (in that order, on one fake) with HSB2
#      0A1B2C3D4E5F (the flows), HSB2 0A1B2C3D4E60 (another box at the same
#      address), then HSB1, HSB3 and HSB3_standalone (0A1B2C3D4E61 to
#      0A1B2C3D4E63); each routing suite (#557) with its box: routing-inline
#      HSB2 0A1B2C3D4E64, routing-onein HSB3 0A1B2C3D4E67, routing-receiver
#      HSB2_behind_receiver 0A1B2C3D4E65, routing-second HSB2_second_output
#      0A1B2C3D4E66, routing-faults HSB2 0A1B2C3D4E68; and each suite of
#      stage 4 (#568) with its HSB2: programming 0A1B2C3D4E69, buttons
#      0A1B2C3D4E6A, periods 0A1B2C3D4E6B, offers 0A1B2C3D4E6C, area-name
#      0A1B2C3D4E6D, takeover 0A1B2C3D4E6E. One fake per group keeps a busy
#      group from slowing another's answers past the scaled timeouts;
#   3. lua5.1 tests/e2e/syncbox_e2e.lua with that environment (E2E_*) and
#      TZ=UTC (the periods suite's clock times), once per group, the groups
#      at the same time. Each group's PASS/FAIL/SKIP
#      lines and summary are printed in that order once all have ended,
#      then a total;
#   4. the fakes stopped (also on failure or interruption).
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
#   JOBS             how many groups run at once (default: nproc; 1 runs
#                    them one after the other)
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
FAKE_PIDS=()

# shellcheck disable=SC2317,SC2329 # run by the EXIT trap
cleanup() {
	local pid
	for pid in "${FAKE_PIDS[@]}"; do
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	done
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

# 2. The groups: the suites that share boxes, in order, each with a fake of
# its own (tools/fakebox.py serve, its state directory, every port the
# system's pick), so that no fake serves two groups at once.
SUITE_GROUPS=("pinning,flows,faults,devhooks,models" routing-inline routing-onein routing-receiver routing-second
	routing-faults programming buttons periods offers area-name takeover)
GROUP_BOXES=(
	"HSB2:0A1B2C3D4E5F HSB2:0A1B2C3D4E60 HSB1:0A1B2C3D4E61 HSB3:0A1B2C3D4E62 HSB3_standalone:0A1B2C3D4E63"
	"HSB2:0A1B2C3D4E64"
	"HSB3:0A1B2C3D4E67"
	"HSB2_behind_receiver:0A1B2C3D4E65"
	"HSB2_second_output:0A1B2C3D4E66"
	"HSB2:0A1B2C3D4E68"
	"HSB2:0A1B2C3D4E69"
	"HSB2:0A1B2C3D4E6A"
	"HSB2:0A1B2C3D4E6B"
	"HSB2:0A1B2C3D4E6C"
	"HSB2:0A1B2C3D4E6D"
	"HSB2:0A1B2C3D4E6E"
)
# The name each group's own box goes by in E2E_ROUTING (none for the first).
ROUTING_NAMES=("" inline onein receiver second faults programming buttons periods offers area takeover)
STAGE4_SUITES=" programming buttons periods offers area-name takeover "

# The suites of a group that --only names ("routing" names every routing-*).
wanted_in() {
	local group="$1" out="" suite item
	local -a names items
	IFS=',' read -r -a names <<<"$group"
	for suite in "${names[@]}"; do
		if [[ -z "$ONLY" ]]; then
			out+="${out:+,}$suite"
			continue
		fi
		IFS=',' read -r -a items <<<"$ONLY"
		for item in "${items[@]}"; do
			if [[ "$item" == "$suite" || ("$item" == routing && "$suite" == routing-*) ||
				("$item" == stage4 && "$STAGE4_SUITES" == *" $suite "*) ]]; then
				out+="${out:+,}$suite"
				break
			fi
		done
	done
	printf '%s' "$out"
}

fakebox_of() {
	printf 'python3 -I tools/fakebox.py --state-dir %s' "$WORK/state-$1"
}

# Each box of group $1 as FIXTURE:ID:PORT, in its order, from its fake's
# server.json (written once every box and the control API listen); nothing
# while it is not there.
ports_of() {
	local i="$1"
	local -a boxes
	read -r -a boxes <<<"${GROUP_BOXES[$i]}"
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
' "$WORK/state-$i/server.json" "${boxes[@]}"
}

CHOSEN=()
RAN=()
for i in "${!SUITE_GROUPS[@]}"; do
	CHOSEN[i]="$(wanted_in "${SUITE_GROUPS[$i]}")"
	if [[ -n "${CHOSEN[$i]}" ]]; then
		RAN+=("$i")
	fi
done
if [[ ${#RAN[@]} -eq 0 ]]; then
	echo "e2e: --only $ONLY names no suite (see --help)" >&2
	exit 2
fi

# The fakes of the groups that run, all at once.
declare -A FAKE_OF
for i in "${RAN[@]}"; do
	serve_args=(serve --port 0 --control-port 0 --cert-base "$WORK/ca" --time-scale "$FAKE_TIME_SCALE")
	for box in ${GROUP_BOXES[$i]}; do
		serve_args+=(--box "$box")
	done
	# shellcheck disable=SC2046 # fakebox_of prints a command and its fixed options
	$(fakebox_of "$i") "${serve_args[@]}" >"$WORK/fake-$i.log" 2>&1 &
	FAKE_OF[$i]=$!
	FAKE_PIDS+=("$!")
done

declare -A SPECS_OF
for i in "${RAN[@]}"; do
	specs=""
	for _ in $(seq 1 100); do
		if specs="$(ports_of "$i" 2>/dev/null)"; then
			break
		fi
		specs=""
		if ! kill -0 "${FAKE_OF[$i]}" 2>/dev/null; then
			echo "e2e: the fake of ${SUITE_GROUPS[$i]} exited at start:" >&2
			cat "$WORK/fake-$i.log" >&2
			exit 2
		fi
		sleep 0.2
	done
	if [[ -z "$specs" ]]; then
		echo "e2e: the fake of ${SUITE_GROUPS[$i]} did not start within 20 s:" >&2
		cat "$WORK/fake-$i.log" >&2
		exit 2
	fi
	SPECS_OF[$i]="$specs"
done

# 3. The suites, each group a lua5.1 process of its own (its output and its
# driver's log in WORK), JOBS of them at a time.
run_group() {
	local n="$1" list="$2" main="" other="" models="" routing=""
	local -a specs
	read -r -a specs <<<"${SPECS_OF[$n]}"
	if [[ -n "${ROUTING_NAMES[$n]}" ]]; then
		routing="${ROUTING_NAMES[$n]}=${specs[0]}"
	else
		main="${specs[0]}"
		other="${specs[1]}"
		models="${specs[2]},${specs[3]},${specs[4]}"
	fi
	E2E_ARCHIVE="$WORK/archive" \
		E2E_ADDRESS="10.0.2.150" \
		E2E_MAIN="$main" \
		E2E_OTHER="$other" \
		E2E_MODELS="$models" \
		E2E_ROUTING="$routing" \
		E2E_FAKEBOX="$(fakebox_of "$n")" \
		E2E_TIME_SCALE="$TIME_SCALE" \
		E2E_FAKE_TIME_SCALE="$FAKE_TIME_SCALE" \
		E2E_ONLY="$list" \
		E2E_TRACE="$TRACE" \
		E2E_LOG="$WORK/driver-$n.log" \
		TMPDIR="$WORK" \
		TZ=UTC \
		lua5.1 tests/e2e/syncbox_e2e.lua >"$WORK/out-$n.txt" 2>&1
	echo "$?" >"$WORK/exit-$n"
}

JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || JOBS=1
pids=()
for i in "${RAN[@]}"; do
	while [[ "$(jobs -rp | wc -l)" -gt "$((JOBS + ${#FAKE_PIDS[@]} - 1))" ]]; do
		wait -n 2>/dev/null || true
	done
	run_group "$i" "${CHOSEN[$i]}" &
	pids+=("$!")
done
for pid in "${pids[@]}"; do
	wait "$pid" 2>/dev/null || true
done

status=0
total_pass=0
total_fail=0
total_skip=0
for i in "${RAN[@]}"; do
	cat "$WORK/out-$i.txt"
	code="$(cat "$WORK/exit-$i" 2>/dev/null || echo 2)"
	summary="$(grep -E '^e2e: [0-9]+ passed, [0-9]+ failed, [0-9]+ skipped$' "$WORK/out-$i.txt" | tail -n 1 || true)"
	if [[ -z "$summary" ]]; then
		echo "e2e: the group ${SUITE_GROUPS[$i]} ended without its summary (exit $code)"
		status=1
		continue
	fi
	read -r p f k <<<"$(sed -E 's/^e2e: ([0-9]+) passed, ([0-9]+) failed, ([0-9]+) skipped$/\1 \2 \3/' <<<"$summary")"
	total_pass=$((total_pass + p))
	total_fail=$((total_fail + f))
	total_skip=$((total_skip + k))
	if [[ "$code" -ne 0 ]]; then
		status=1
	fi
done
if [[ ${#RAN[@]} -gt 1 ]]; then
	echo "e2e total: $total_pass passed, $total_fail failed, $total_skip skipped"
fi

# 4. The fakes stopped (the trap kills them on any other way out).
for i in "${RAN[@]}"; do
	# shellcheck disable=SC2046 # fakebox_of prints a command and its fixed options
	$(fakebox_of "$i") stop >/dev/null 2>&1 || true
done
if [[ "$status" -ne 0 && -z "$KEEP" ]]; then
	echo "e2e: run again with --keep to keep the fakes' logs and the drivers'"
fi
exit "$status"
