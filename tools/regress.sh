#!/usr/bin/env bash
# Dev-loop regression pass (docs/release-checklist.md §1, steps 2–4 and 9):
# runs the bridge's read-only actions through tools/devctl.py against a
# --dev build on the house, prints each action's Status and Last Action, and
# scans the shipped log for errors. Needs tools/devserver.py running and the
# dev bridge polling it (devctl.py status). Creates nothing, deletes nothing.
#
# Usage: tools/regress.sh [--server http://127.0.0.1:8080]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVCTL=(python3 -I "$ROOT/tools/devctl.py" "$@")
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

say "Test Connection"
out="$(run_action "Test Connection")"; echo "$out" | grep -E "Status|Last Action" | head -4
expect "Test OK: HTTP 200" "$out" "Test Connection answers Test OK"

say "Refresh Scenes"
out="$(run_action "Refresh Scenes")"; echo "$out" | grep -E "Status|Last Action|Scenes" | head -4
expect "Scenes refreshed: [0-9]+ \+ [0-9]+ time-based on bridge" "$out" "Refresh Scenes reports the counts"

say "Room Audit"
out="$(run_action "Room Audit")"; echo "$out" | grep -E "Last Action" | head -2
expect "linked lights|not in the room|No linked|nothing to audit|audit" "$out" "Room Audit reports"

say "Link Devices"
out="$(run_action "Link Devices")"; echo "$out" | grep -E "Last Action" | head -2
expect "registered|Linked|No .* devices|bound" "$out" "Link Devices reports"

say "Adopt Hue Names / Accept Names As They Are"
out="$(run_action "Adopt Hue Names")"; echo "$out" | grep -E "Last Action" | head -2
expect "names|Renamed|differ" "$out" "Adopt Hue Names reports"
out="$(run_action "Accept Names As They Are")"; echo "$out" | grep -E "Last Action" | head -2
expect "names|Accepted|differ" "$out" "Accept Names reports"

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
echo "$log" | grep -E "resync done|scene resync done|zone light resync done|stream will use|event stream connected" | tail -6

say "result"
if [[ $fail -eq 0 ]]; then echo "ALL PASS"; else echo "$fail check(s) failed"; fi
exit $fail
