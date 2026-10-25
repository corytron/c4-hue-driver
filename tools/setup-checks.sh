#!/usr/bin/env bash
# Install the tools tools/check.sh needs into ~/.local/bin, without sudo
# (docs/cicd-gitops-design.md, section 3). The same script runs on the VM and
# in CI (ubuntu-latest already has shellcheck and pwsh; luacheck and busted
# come from luarocks in the Lua job, not from here).
#
# Usage: tools/setup-checks.sh
#
# Pinned versions. Python tools go through `python3 -m pip install --user
# --break-system-packages` (pipx or uv when pip is missing); actionlint and
# gitleaks are release binaries downloaded with curl into a fresh temporary
# directory, verified against the sha256 below before anything is moved into
# ~/.local/bin, and never run from the download directory. A tool already
# present at the pinned version is skipped; shellcheck-py is skipped whenever
# any shellcheck is on PATH. Prints one line per tool, then every version. In
# GitHub Actions ($GITHUB_PATH set) ~/.local/bin is appended to the job's PATH.
set -euo pipefail

RUFF_VERSION=0.17.2
ZIZMOR_VERSION=1.31.1
SHELLCHECK_PY_VERSION=0.10.0.1 # ships shellcheck 0.10.0
SHELLCHECK_VERSION=0.10.0

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

# Install a PyPI package (`name==version`) for the user: pip, else pipx, else
# uv, else a clear failure.
pip_install() {
	local spec="$1"
	if python3 -m pip --version >/dev/null 2>&1; then
		python3 -m pip install --user --break-system-packages --quiet \
			--disable-pip-version-check --no-warn-script-location "$spec"
	elif command -v pipx >/dev/null 2>&1; then
		pipx install --force "$spec" >/dev/null
	elif command -v uv >/dev/null 2>&1; then
		uv tool install --force "$spec" >/dev/null
	else
		echo "setup-checks.sh: cannot install $spec: none of python3 -m pip, pipx or uv is available" >&2
		exit 1
	fi
}

# install_pip_tool <command> <package> <package version> <version the command reports>
install_pip_tool() {
	local cmd="$1" package="$2" package_version="$3" want="$4" have
	have="$(version_of "$cmd")"
	if [[ "$have" == "$want" ]]; then
		echo "$cmd $want: already installed ($(command -v "$cmd"))"
		return
	fi
	pip_install "$package==$package_version"
	have="$(version_of "$cmd")"
	if [[ "$have" != "$want" ]]; then
		echo "setup-checks.sh: installed $package==$package_version but $cmd reports '${have:-nothing}' (wanted $want)" >&2
		exit 1
	fi
	echo "$cmd $want: installed ($(command -v "$cmd"))"
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
