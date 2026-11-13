#!/usr/bin/env bash
# Run every check of the repository the same way on the VM and in CI
# (docs/cicd-gitops-design.md, section 3).
#
# Usage: tools/check.sh [--strict] [--only <name>...]
#   --strict          a check whose tool is not installed fails instead of
#                     being skipped (CI runs with it, so nothing is silently
#                     skipped on the runner)
#   --only <name>...  run only the named checks; they still report in the order
#                     below, whatever the order given
#
# Checks, in order:
#   lua-lint     luacheck src tests tools (tools/parallel.py luacheck: shards of files
#                on every core, the output of one luacheck run)
#   lua-test     busted tests (tools/parallel.py busted: one busted a spec file on every
#                core, then busted's total)
#   lua-limits   python3 tools/lua_limits.py: no function of a Lua file under src/ has more
#                than 180 locals or 50 upvalues (luac5.1 -p -l -l; Lua 5.1 stops at 200 and 60;
#                docs/driver-locals-design.md)
#   shell        shellcheck -S style tools/*.sh (and setup-vm.sh if present)
#   python-lint  ruff check tools; ruff format --check tools
#   python-test  python3 -B -m unittest discover -s tools/tests, one process a test module
#                (tools/parallel.py unittest; -B: no __pycache__, whose constant-folded
#                test vectors the secrets tree scan would flag)
#   xml          every src/*/driver.xml is well-formed (xml.etree, no xmllint)
#   powershell   Invoke-ScriptAnalyzer over tools/composer (skipped without pwsh)
#   workflows    actionlint; zizmor --min-severity medium .github/workflows
#   secrets      gitleaks over the working tree and, at the same time, over the history
#                of every local ref (git log --all) or, in GitHub Actions, of HEAD only
#   house        python3 tools/deploy.py validate (deploy/house.yaml, offline)
#   changelog    python3 tools/changelog.py check (CHANGELOG.md, docs/changelog-design.md)
#   links        python3 tools/check_links.py: every link in every tracked Markdown
#                file and Documentation tab resolves (files and heading anchors)
#   doc-tabs     python3 tools/check_doc_tabs.py: nothing in a Documentation tab
#                (src/*/www/*.html) runs or fetches from outside the package: no script,
#                frame, object, embed, form, link or event handler, only relative src
#                and stylesheet addresses (security review 2026-11-13, I-7)
#
# The checks run at the same time (issue #456): each one's output is kept apart
# and reported in the order above as soon as it and every check before it are
# done, so the output is that of a serial run. secrets starts once python-lint
# is done, since ruff may write .ruff_cache while gitleaks reads the tree.
# JOBS (environment) caps how many checks run at once and how many processes
# each of lua-lint, lua-test and python-test starts (default: nproc); JOBS=1
# runs everything one at a time, as before #456, for debugging.
#
# One line per check: "ok <name>", "FAIL <name>" followed by the output of the
# failing command(s), or "skip <name> (<tool> not installed)". Exit 1 when a
# check failed, 2 on a usage error (JOBS not a whole number from 1 included),
# else 0. Tools are looked up on PATH with ~/.local/bin first, where
# tools/setup-checks.sh installs them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH="$HOME/.local/bin:$PATH"

ALL_CHECKS=(lua-lint lua-test lua-limits shell python-lint python-test xml powershell workflows secrets house changelog links doc-tabs)

usage() {
	echo "usage: tools/check.sh [--strict] [--only <name>...]" >&2
	echo "checks: ${ALL_CHECKS[*]}" >&2
}

# The executables a check needs on PATH; a missing one makes the check a skip
# (or a failure with --strict).
tools_for() {
	case "$1" in
		lua-lint) echo luacheck python3 ;;
		lua-test) echo busted python3 ;;
		lua-limits) echo luac5.1 python3 ;;
		shell) echo shellcheck ;;
		python-lint) echo ruff ;;
		python-test | xml | house | changelog | doc-tabs) echo python3 ;;
		links) echo python3 git ;;
		powershell) echo pwsh ;;
		workflows) echo actionlint zizmor ;;
		secrets) echo gitleaks ;;
		*) echo "check.sh: no such check: $1" >&2; exit 2 ;;
	esac
}

# Print the command, then run it; the check's log shows what was run.
run() {
	echo "\$ $*"
	"$@"
}

check_lua_lint() {
	run python3 -I tools/parallel.py luacheck src tests tools
}

check_lua_test() {
	run python3 -I tools/parallel.py busted tests
}

check_lua_limits() {
	run python3 -I tools/lua_limits.py
}

check_shell() {
	local files=(tools/*.sh)
	if [[ -f setup-vm.sh ]]; then
		files+=(setup-vm.sh)
	fi
	run shellcheck -S style "${files[@]}"
}

check_python_lint() {
	local rc=0
	run ruff check tools || rc=1
	run ruff format --check tools || rc=1
	return "$rc"
}

check_python_test() {
	if [[ ! -d tools/tests ]]; then
		echo "tools/tests/ does not exist: there are no Python unit tests to run"
		return 1
	fi
	run python3 -I tools/parallel.py unittest tools/tests
}

check_xml() {
	# xml.etree rejects what Composer would reject: unclosed tags, bad
	# entities, text outside the root element.
	run python3 -I -c '
import sys
import xml.etree.ElementTree as ET

rc = 0
for path in sys.argv[1:]:
    try:
        ET.parse(path)
        print("well-formed", path)
    except (ET.ParseError, OSError) as error:
        print(path + ": " + str(error), file=sys.stderr)
        rc = 1
sys.exit(rc)
' src/*/driver.xml
}

check_powershell() {
	run pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path tools/composer -Recurse -Severity Error -EnableExit"
}

check_workflows() {
	local rc=0
	run actionlint || rc=1
	run zizmor --min-severity medium .github/workflows || rc=1
	return "$rc"
}

# Which history the secrets check reads. Run by hand, every local ref
# (branches, tags, stashes and remote-tracking refs): a stale tag or branch
# can hold history that never reached GitHub, and a `git push --tags` or
# `--mirror` would publish it (security review 2026-10-25, finding 14). In CI
# (GitHub Actions sets GITHUB_ACTIONS=true) the history of the checked-out
# commit only: the full-depth checkout also holds every other branch and tag
# of the repository, whose findings are not this change's.
secrets_log_opts() {
	if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
		echo HEAD
	else
		echo --all
	fi
}

check_secrets() {
	local rc=0
	if [[ ! -f .gitleaks.toml ]]; then
		echo ".gitleaks.toml is missing: the secrets check needs the repository's gitleaks rules"
		return 1
	fi
	# The tree and the history at the same time (one after the other when
	# JOBS=1), each into its own log, printed in this order.
	local tree_log="$results/secrets-tree.log" history_log="$results/secrets-history.log" tree_pid history_pid
	(
		trap - INT
		run gitleaks dir . --config .gitleaks.toml --no-banner --redact
	) >"$tree_log" 2>&1 &
	tree_pid=$!
	if [[ "$max_jobs" -eq 1 ]]; then
		wait "$tree_pid" || rc=1
		tree_pid=""
	fi
	(
		trap - INT
		run gitleaks git . --config .gitleaks.toml --no-banner --redact "--log-opts=$(secrets_log_opts)"
	) >"$history_log" 2>&1 &
	history_pid=$!
	if [[ -n "$tree_pid" ]]; then
		wait "$tree_pid" || rc=1
	fi
	wait "$history_pid" || rc=1
	cat "$tree_log" "$history_log"
	return "$rc"
}

check_house() {
	if [[ ! -f tools/deploy.py ]]; then
		echo "tools/deploy.py is missing: the house check validates deploy/house.yaml with it"
		return 1
	fi
	run python3 tools/deploy.py validate
}

check_changelog() {
	run python3 -I tools/changelog.py check --file CHANGELOG.md
}

check_links() {
	run python3 -I tools/check_links.py
}

check_doc_tabs() {
	run python3 -I tools/check_doc_tabs.py
}

strict=no
selected=()
while [[ $# -gt 0 ]]; do
	case "$1" in
		--strict)
			strict=yes
			shift
			;;
		--only)
			shift
			if [[ $# -eq 0 || "$1" == --* ]]; then
				echo "check.sh: --only needs at least one check name" >&2
				usage
				exit 2
			fi
			while [[ $# -gt 0 && "$1" != --* ]]; do
				known=no
				for name in "${ALL_CHECKS[@]}"; do
					if [[ "$name" == "$1" ]]; then
						known=yes
					fi
				done
				if [[ "$known" == no ]]; then
					echo "check.sh: unknown check: $1" >&2
					usage
					exit 2
				fi
				selected+=("$1")
				shift
			done
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			echo "check.sh: unknown argument: $1" >&2
			usage
			exit 2
			;;
	esac
done

# Run in the canonical order, each selected check once.
to_run=()
for name in "${ALL_CHECKS[@]}"; do
	if [[ ${#selected[@]} -eq 0 ]]; then
		to_run+=("$name")
		continue
	fi
	for wanted in "${selected[@]}"; do
		if [[ "$wanted" == "$name" ]]; then
			to_run+=("$name")
			break
		fi
	done
done

# How many checks run at once (and, through the environment, how many
# processes each parallel check starts): JOBS, else every core.
if [[ -n "${JOBS:-}" ]]; then
	if [[ ! "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
		echo "check.sh: JOBS must be a whole number from 1 (JOBS=1 runs serially), not '$JOBS'" >&2
		exit 2
	fi
	max_jobs="$JOBS"
else
	max_jobs="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
fi

# The checks a check starts after: secrets reads the whole tree, where ruff
# (python-lint) may be writing .ruff_cache.
after_of() {
	case "$1" in
		secrets) echo python-lint ;;
	esac
}

# Check number N (an index into to_run) keeps its output in $results/N.log and
# its result in $results/N.status, written last: "ok", "fail", "skip <tool>"
# or "missing <tool>". A .status file means the check is done.
results="$(mktemp -d)"
trap 'rm -rf "$results"' EXIT
pids=()
printed=0
failed=()

set_status() {
	echo "$2" >"$results/$1.status.tmp"
	mv "$results/$1.status.tmp" "$results/$1.status"
}

# Start check N in the background. A background job ignores Ctrl-C unless
# told otherwise; this one stops with check.sh.
start_check() {
	local index="$1"
	(
		trap - INT
		status=fail
		if "check_${to_run[$index]//-/_}" >"$results/$index.log" 2>&1; then
			status=ok
		fi
		set_status "$index" "$status"
	) &
	pids[index]=$!
}

# How many started checks are not done.
running() {
	local count=0 index
	for index in "${!pids[@]}"; do
		[[ -e "$results/$index.status" ]] || count=$((count + 1))
	done
	echo "$count"
}

# Whether every check that check N starts after is done (or not selected).
after_done() {
	local before index
	for before in $(after_of "${to_run[$1]}"); do
		for index in "${!to_run[@]}"; do
			if [[ "${to_run[$index]}" == "$before" && ! -e "$results/$index.status" ]]; then
				return 1
			fi
		done
	done
}

# Wait until a check is done. A check whose shell ended without a result
# (killed) is a failure.
wait_one() {
	local index
	wait -n 2>/dev/null || true
	for index in "${!pids[@]}"; do
		if [[ ! -e "$results/$index.status" ]] && ! kill -0 "${pids[$index]}" 2>/dev/null; then
			echo "check.sh: the check ended without a result" >>"$results/$index.log"
			set_status "$index" fail
		fi
	done
}

# Print every result that is done, in order, up to the first that is not.
report_ready() {
	local name status tool
	while [[ $printed -lt ${#to_run[@]} && -e "$results/$printed.status" ]]; do
		name="${to_run[$printed]}"
		read -r status tool <"$results/$printed.status"
		case "$status" in
			ok) echo "ok $name" ;;
			skip) echo "skip $name ($tool not installed)" ;;
			missing)
				echo "FAIL $name ($tool not installed)"
				failed+=("$name")
				;;
			*)
				echo "FAIL $name"
				sed 's/^/  /' "$results/$printed.log"
				failed+=("$name")
				;;
		esac
		printed=$((printed + 1))
	done
}

for index in "${!to_run[@]}"; do
	name="${to_run[$index]}"
	missing=""
	read -r -a tools <<< "$(tools_for "$name")"
	for tool in "${tools[@]}"; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			missing="$tool"
			break
		fi
	done
	if [[ -n "$missing" ]]; then
		if [[ "$strict" == yes ]]; then
			set_status "$index" "missing $missing"
		else
			set_status "$index" "skip $missing"
		fi
		report_ready
		continue
	fi
	while [[ "$(running)" -ge "$max_jobs" ]] || ! after_done "$index"; do
		wait_one
		report_ready
	done
	start_check "$index"
done
while [[ $printed -lt ${#to_run[@]} ]]; do
	wait_one
	report_ready
done

if [[ ${#failed[@]} -gt 0 ]]; then
	echo "check.sh: ${#failed[@]} failed: ${failed[*]}"
	exit 1
fi
