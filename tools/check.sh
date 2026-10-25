#!/usr/bin/env bash
# Run every check of the repository the same way on the VM and in CI
# (docs/cicd-gitops-design.md, section 3).
#
# Usage: tools/check.sh [--strict] [--only <name>...]
#   --strict          a check whose tool is not installed fails instead of
#                     being skipped (CI runs with it, so nothing is silently
#                     skipped on the runner)
#   --only <name>...  run only the named checks; they still run in the order
#                     below, whatever the order given
#
# Checks, in order:
#   lua-lint     luacheck src tests tools
#   lua-test     busted tests
#   shell        shellcheck -S style tools/*.sh (and setup-vm.sh if present)
#   python-lint  ruff check tools; ruff format --check tools
#   python-test  python3 -B -m unittest discover -s tools/tests (-B: no __pycache__,
#                whose constant-folded test vectors the secrets tree scan would flag)
#   xml          every src/*/driver.xml is well-formed (xml.etree, no xmllint)
#   powershell   Invoke-ScriptAnalyzer over tools/composer (skipped without pwsh)
#   workflows    actionlint; zizmor --min-severity medium .github/workflows
#   secrets      gitleaks over the working tree, then over the history of every
#                local ref (git log --all) or, in GitHub Actions, of HEAD only
#   house        python3 tools/deploy.py validate (deploy/house.yaml, offline)
#   changelog    python3 tools/changelog.py check (CHANGELOG.md, docs/changelog-design.md)
#
# One line per check: "ok <name>", "FAIL <name>" followed by the output of the
# failing command(s), or "skip <name> (<tool> not installed)". Exit 1 when a
# check failed, 2 on a usage error, else 0. Tools are looked up on PATH with
# ~/.local/bin first, where tools/setup-checks.sh installs them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH="$HOME/.local/bin:$PATH"

ALL_CHECKS=(lua-lint lua-test shell python-lint python-test xml powershell workflows secrets house changelog)

usage() {
	echo "usage: tools/check.sh [--strict] [--only <name>...]" >&2
	echo "checks: ${ALL_CHECKS[*]}" >&2
}

# The executables a check needs on PATH; a missing one makes the check a skip
# (or a failure with --strict).
tools_for() {
	case "$1" in
		lua-lint) echo luacheck ;;
		lua-test) echo busted ;;
		shell) echo shellcheck ;;
		python-lint) echo ruff ;;
		python-test | xml | house | changelog) echo python3 ;;
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
	run luacheck src tests tools
}

check_lua_test() {
	run busted tests
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
	run python3 -B -m unittest discover -s tools/tests
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
	run gitleaks dir . --config .gitleaks.toml --no-banner --redact || rc=1
	run gitleaks git . --config .gitleaks.toml --no-banner --redact "--log-opts=$(secrets_log_opts)" || rc=1
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

failed=()
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

for name in "${to_run[@]}"; do
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
			echo "FAIL $name ($missing not installed)"
			failed+=("$name")
		else
			echo "skip $name ($missing not installed)"
		fi
		continue
	fi
	fn="check_${name//-/_}"
	if "$fn" >"$log" 2>&1; then
		echo "ok $name"
	else
		echo "FAIL $name"
		sed 's/^/  /' "$log"
		failed+=("$name")
	fi
done

if [[ ${#failed[@]} -gt 0 ]]; then
	echo "check.sh: ${#failed[@]} failed: ${failed[*]}"
	exit 1
fi
