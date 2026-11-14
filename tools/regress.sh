#!/usr/bin/env bash
# Dev-loop regression pass (docs/release-checklist.md §1, steps 2–4 and 9):
# runs the bridge's read-only actions through tools/devctl.py against a
# --dev build on the house, prints each action's Status and Last Action, and
# scans the shipped log for errors. Needs tools/devserver.py running and the
# dev bridge polling it (devctl.py status). Creates nothing, deletes nothing,
# and renames nothing unless --with-renames is given (#344). The actions are
# 1.2's merged ones with their parameters (docs/simplify-actions-design.md
# §3.3): the old command names answered as hidden aliases until 2.0 removed
# them (#514, docs/hdmi-sync-design.md §10 O15). Link Device's top row
# (dev:suggested), like Link Devices before it, registers a bound device the
# bridge lacks, and also re-links a device with a suggested match, as the
# owner's click on that row would.
#
# Usage: tools/regress.sh [--with-renames] [--server http://127.0.0.1:8080]
#   --with-renames  also run Resolve Names' "Hue names to Composer"
#                   (names:hue_to_composer, Adopt Hue Names until 1.2) and its
#                   names:keep_composer row (Accept Names As They Are), which
#                   change the live project: the first renames every device
#                   whose Composer name differs from its Hue name. Off by
#                   default.
#   --server URL    passed on to tools/devctl.py (default: build/dev/server.json)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
	sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p}' "$0"
}

with_renames=no
devctl_args=()
while [[ $# -gt 0 ]]; do
	case "$1" in
		--with-renames) with_renames=yes ;;
		-h | --help) usage; exit 0 ;;
		--server) devctl_args+=("$1" "${2:?--server needs a URL}"); shift ;;
		*) devctl_args+=("$1") ;;
	esac
	shift
done
DEVCTL=(python3 -I "$ROOT/tools/devctl.py" "${devctl_args[@]}")
fail=0

say() { printf '\n== %s\n' "$*"; }
expect() { # expect <pattern> <text> <label>
	if grep -qE "$1" <<<"$2"; then
		printf 'PASS  %s\n' "$3"
	else
		printf 'FAIL  %s (no match for /%s/)\n' "$3" "$1"
		fail=$((fail + 1))
	fi
}

say "status"
status="$("${DEVCTL[@]}" status 2>&1)" || { echo "$status"; echo "devctl status failed: is tools/devserver.py running and the dev bridge polling?"; exit 2; }
echo "$status"
expect "last_seen|seen" "$status" "bridge talking to the dev server"

run_action() { # run_action "Action" [Param=value ...] -> prints the wait output
	local id
	id="$("${DEVCTL[@]}" run "$@" 2>&1)" || { echo "run failed: $id"; fail=$((fail + 1)); return 1; }
	"${DEVCTL[@]}" wait "$id" --timeout 120 2>&1
}

# An action's handler returns before the bridge answers, and the property
# snapshot in `status` refreshes only with the 30 s heartbeat: read the
# shipped log (every Status and Last Action text is logged as it is set)
# until <pattern> shows up, at most <seconds>; prints the matching lines.
settle() { # settle <pattern> <seconds>
	local out
	for _ in $(seq 1 "$2"); do
		out="$("${DEVCTL[@]}" log 2>&1 | tail -300 | grep -E "$1" | tail -3)"
		if [[ -n "$out" ]]; then echo "$out"; return 0; fi
		sleep 2
	done
	echo "(no match in the shipped log after $2 tries)"; return 1
}

# Diagnostics' "Check the connection now" (Test Connection until 1.2, its
# alias until 2.0): the check logs "Test Connection via <host>: ...".
say "Diagnostics: Check the connection now"
run_action "Diagnostics" "What=diag:test" >/dev/null
out="$(settle "Test Connection via .*: (OK|.*) after [0-9]+ s" 20)"; echo "$out"
expect "Test Connection via .*: OK after" "$out" "the connection check answers OK"

# Diagnostics' "Read everything from the bridge now" (Refresh All; the
# scenes alone were Refresh Scenes, both aliases until 2.0): the full read,
# whose Last Action carries the scene counts.
say "Diagnostics: Read everything from the bridge now"
run_action "Diagnostics" "What=diag:refresh" >/dev/null
out="$(settle "Refreshed from the bridge: |Read everything from the bridge: " 30)"; echo "$out"
expect "Refreshed from the bridge: .*Scenes: [0-9]+ scenes? \+ [0-9?]+ time-based on bridge" "$out" \
	"the full read reports the scene counts"

# Room Audit (an alias from 1.2) went in 2.0 with nothing to click in its
# place: since 1.2 the pickers' rows mark a device whose Hue room and Control4
# room differ, on every read (docs/simplify-actions-design.md §1.3).

# Link Device's top row, every bound device the bridge does not know yet
# (Link Devices until 1.2, its alias until 2.0).
say "Link Device: every bound device the bridge does not know yet"
out="$(run_action "Link Device" "Device=dev:suggested")"; echo "$out" | grep -E "Last Action" | head -2
expect "registered|Linked|No .* devices|bound" "$out" "Link Device reports"

say "Resolve Names: Hue names to Composer / keep the Composer names"
if [[ "$with_renames" == yes ]]; then
	# Adopt Hue Names until 1.2, its alias until 2.0.
	out="$(run_action "Resolve Names" "Names=names:hue_to_composer")"; echo "$out" | grep -E "Last Action" | head -2
	expect "names|Names|Renamed|differ" "$out" "Hue names to Composer reports"
	# Accept Names As They Are until 1.2, its alias until 2.0. With
	# bridge/names.lua (every build since 1.2) the names follow each other by
	# themselves and Resolve Names answers this row with a refusal.
	out="$(run_action "Resolve Names" "Names=names:keep_composer")"; echo "$out" | grep -E "Last Action" | head -2
	expect "names|Names|Accepted|differ" "$out" "keep the Composer names reports"
else
	echo "SKIP  Resolve Names: it acts on the device names of the live project (--with-renames runs it)"
fi

say "Lights Report (dev action: the summaries in the log)"
out="$(run_action "Lights Report")"; echo "$out" | grep -E "Status|Last Action" | head -2

say "shipped log: errors"
log="$("${DEVCTL[@]}" log 2>&1 | tail -400)"
errors="$(grep -nE "\[ERROR\]|attempt to|stack traceback|runtime error" <<<"$log" || true)"
if [[ -n "$errors" ]]; then
	echo "$errors"; echo "FAIL  errors in the shipped log"; fail=$((fail + 1))
else
	echo "PASS  no error lines in the last 400 log lines"
fi
echo "$log" | grep -E "resync done|scene resync done|zone light resync done|stream will use|event stream: connecting to|event stream connected" | tail -6

say "result"
if [[ $fail -eq 0 ]]; then echo "ALL PASS"; else echo "$fail check(s) failed"; fi
exit $fail
