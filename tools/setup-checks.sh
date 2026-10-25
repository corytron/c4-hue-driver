#!/usr/bin/env bash
# Install the tools tools/check.sh needs into ~/.local/bin, without sudo
# (docs/cicd-gitops-design.md, section 3). The same script runs on the VM and
# in CI (ubuntu-latest already has shellcheck and pwsh; luacheck and busted
# come from luarocks in the Lua job, not from here).
#
# Usage: tools/setup-checks.sh
#
# Pinned versions. The Python tools (ruff, zizmor, shellcheck-py) are pinned in
# tools/requirements-checks.txt by version and by the sha256 of every file PyPI
# has for that version, and installed one at a time with `python3 -m pip
# install --require-hashes --no-deps --only-binary=:all: --user
# --break-system-packages`: pip refuses a file whose hash is not listed, any
# dependency and any source build. That check is pip's, so a machine without
# `python3 -m pip` fails with a clear line (there is no pipx or uv fallback).
# actionlint and gitleaks are release binaries downloaded with curl into a
# fresh temporary directory, verified against the sha256 below before anything
# is moved into ~/.local/bin, and never run from the download directory. A
# tool already present at the pinned version is skipped; shellcheck-py is
# skipped whenever any shellcheck is on PATH. Prints one line per tool, then
# every version. In GitHub Actions ($GITHUB_PATH set) ~/.local/bin is appended
# to the job's PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUIREMENTS="$ROOT/tools/requirements-checks.txt"

# The version tools/requirements-checks.txt pins for a package; exits when the
# file pins none.
pinned_version() {
	local version
	version="$(awk -v name="$1" '$1 ~ "^" name "==" { sub(/^[^=]*==/, "", $1); print $1; exit }' "$REQUIREMENTS")"
	if [[ -z "$version" ]]; then
		echo "setup-checks.sh: $REQUIREMENTS pins no version of $1" >&2
		exit 1
	fi
	echo "$version"
}

RUFF_VERSION="$(pinned_version ruff)"
ZIZMOR_VERSION="$(pinned_version zizmor)"
SHELLCHECK_PY_VERSION="$(pinned_version shellcheck-py)"
# The package's version is the shellcheck it ships plus a build number (0.10.0.1
# ships 0.10.0); the command reports the shellcheck version.
SHELLCHECK_VERSION="${SHELLCHECK_PY_VERSION%.*}"

ACTIONLINT_VERSION=1.7.12
ACTIONLINT_ASSET="actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz"
ACTIONLINT_URL="https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/${ACTIONLINT_ASSET}"
ACTIONLINT_SHA256=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8

GITLEAKS_VERSION=8.30.1
GITLEAKS_ASSET="gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
GITLEAKS_URL="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/${GITLEAKS_ASSET}"
GITLEAKS_SHA256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb

BIN="$HOME/.local/bin"
mkdir -p "$BIN"
export PATH="$BIN:$PATH"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The version a tool reports, or nothing when it is not on PATH.
version_of() {
	command -v "$1" >/dev/null 2>&1 || return 0
	case "$1" in
		ruff | zizmor) "$1" --version 2>/dev/null | awk 'NR == 1 { print $2 }' ;;
		shellcheck) shellcheck --version 2>/dev/null | awk '/^version:/ { print $2 }' ;;
		actionlint) actionlint --version 2>/dev/null | awk 'NR == 1 { print $1 }' ;;
		gitleaks) gitleaks version 2>/dev/null | awk 'NR == 1 { sub(/^v/, "", $1); print $1 }' ;;
		luacheck) luacheck --version 2>/dev/null | awk 'NR == 1 { print $2 }' ;;
		busted) busted --version 2>/dev/null | awk 'NR == 1 { print $1 }' ;;
		pwsh) pwsh --version 2>/dev/null | awk 'NR == 1 { print $2 }' ;;
	esac
}

# Install one package of tools/requirements-checks.txt for the user, in pip's
# hash-checking mode. Only that package's lines (`name==version \` and its
# `--hash` lines) go to pip, so nothing else in the file is installed with it.
pip_install() {
	local package="$1" requirement="$WORK/requirements-$1.txt"
	awk -v name="$package" '
		$1 ~ "^" name "==" { found = 1 }
		found { print; if ($0 !~ /\\$/) exit }
	' "$REQUIREMENTS" >"$requirement"
	if ! grep -q -- '--hash=sha256:' "$requirement"; then
		echo "setup-checks.sh: $REQUIREMENTS lists no sha256 hashes for $package; not installed" >&2
		exit 1
	fi
	if ! python3 -m pip --version >/dev/null 2>&1; then
		echo "setup-checks.sh: cannot install $package: python3 -m pip is not available (install python3-pip); the hash-checked install needs pip" >&2
		exit 1
	fi
	python3 -m pip install --require-hashes --no-deps --only-binary=:all: \
		--user --break-system-packages --quiet --disable-pip-version-check --no-warn-script-location \
		--requirement "$requirement"
}

# install_pip_tool <command> <package> <package version> <version the command reports>
install_pip_tool() {
	local cmd="$1" package="$2" package_version="$3" want="$4" have
	have="$(version_of "$cmd")"
	if [[ "$have" == "$want" ]]; then
		echo "$cmd $want: already installed ($(command -v "$cmd"))"
		return
	fi
	pip_install "$package"
	have="$(version_of "$cmd")"
	if [[ "$have" != "$want" ]]; then
		echo "setup-checks.sh: installed $package==$package_version but $cmd reports '${have:-nothing}' (wanted $want)" >&2
		exit 1
	fi
	echo "$cmd $want: installed ($(command -v "$cmd"), sha256 verified by pip)"
}

# install_release_binary <command> <version> <url> <asset name> <sha256>
# The archive holds the binary at its top level under the command's name.
install_release_binary() {
	local cmd="$1" want="$2" url="$3" asset="$4" sha256="$5" have actual dir
	have="$(version_of "$cmd")"
	if [[ "$have" == "$want" ]]; then
		echo "$cmd $want: already installed ($(command -v "$cmd"))"
		return
	fi
	if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
		echo "setup-checks.sh: $cmd $want is pinned for Linux x86_64 only; this is $(uname -s) $(uname -m)" >&2
		exit 1
	fi
	dir="$WORK/$cmd"
	mkdir -p "$dir/extract"
	curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 \
		--output "$dir/$asset" "$url"
	actual="$(sha256sum "$dir/$asset" | awk '{ print $1 }')"
	if [[ "$actual" != "$sha256" ]]; then
		echo "setup-checks.sh: sha256 mismatch for $asset: expected $sha256, got $actual; not installed" >&2
		exit 1
	fi
	tar -xzf "$dir/$asset" -C "$dir/extract" "$cmd"
	install -m 0755 "$dir/extract/$cmd" "$BIN/$cmd"
	have="$(version_of "$cmd")"
	if [[ "$have" != "$want" ]]; then
		echo "setup-checks.sh: installed $asset but $cmd reports '${have:-nothing}' (wanted $want)" >&2
		exit 1
	fi
	echo "$cmd $want: installed ($BIN/$cmd, sha256 verified)"
}

install_pip_tool ruff ruff "$RUFF_VERSION" "$RUFF_VERSION"
install_pip_tool zizmor zizmor "$ZIZMOR_VERSION" "$ZIZMOR_VERSION"
if command -v shellcheck >/dev/null 2>&1; then
	echo "shellcheck $(version_of shellcheck): already on PATH ($(command -v shellcheck)); shellcheck-py not installed"
else
	install_pip_tool shellcheck shellcheck-py "$SHELLCHECK_PY_VERSION" "$SHELLCHECK_VERSION"
fi
install_release_binary actionlint "$ACTIONLINT_VERSION" "$ACTIONLINT_URL" "$ACTIONLINT_ASSET" "$ACTIONLINT_SHA256"
install_release_binary gitleaks "$GITLEAKS_VERSION" "$GITLEAKS_URL" "$GITLEAKS_ASSET" "$GITLEAKS_SHA256"

if [[ -n "${GITHUB_PATH:-}" ]]; then
	echo "$BIN" >> "$GITHUB_PATH"
	echo "GitHub Actions: $BIN appended to GITHUB_PATH"
fi

echo "versions:"
for tool in ruff zizmor shellcheck actionlint gitleaks luacheck busted pwsh; do
	if command -v "$tool" >/dev/null 2>&1; then
		echo "  $tool $(version_of "$tool") ($(command -v "$tool"))"
	else
		echo "  $tool (not installed)"
	fi
done
