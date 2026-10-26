#!/usr/bin/env bash
# Build one build/<driver>.c4z per src/<driver>/driver.xml (today hue_bridge, hue_light and
# hue_scene) with Control4's dp3 packager. That directory list is the one list of the packages
# (docs/prerelease-design.md, section 2): build/manifest.json names them, and the Release
# workflow and tools/deploy.py read it from there.
#
# Usage: tools/build.sh [--dev]
#   --dev   developer build: ships common/devloop.lua (the self-reloading dev
#           loop, see docs/dev-loop.md) with the dev key baked in as
#           common/devkey.lua, and allows the Lua command window in Composer
#           (dp3 --allowexecute). Release builds contain none of it.
#
# The dev key (docs/dev-loop.md, "Security") is the file tools/devserver.py
# uses: ~/.config/c4-hue-driver/devkey, or $C4_HUE_DEVKEY_FILE; created on
# first use. It is written into the stage of a dev build only and removed
# from it once packed; the dev packages are written 0600, since whoever
# holds one holds the key. The key is never printed or put on a command line.
#
# Each driver is staged into build/stage/<driver>/ with src/common copied in
# as common/, so `require("common.log")` resolves inside the .c4z the same way
# it does in the tests. The driver.xml <version> is set to the git commit
# count so every build from a newer commit is seen by Composer as an update.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DP3="${DP3:-$HOME/c4-tools/drivers-driverpackager/dp3/driverpackager.py}"
DRIVERS=()
for xml in "$ROOT"/src/*/driver.xml; do
	DRIVERS+=("$(basename "$(dirname "$xml")")")
done
if [[ ${#DRIVERS[@]} -eq 0 ]]; then
	echo "build.sh: no src/*/driver.xml" >&2
	exit 1
fi

extra_args=()
dev_build=no
for arg in "$@"; do
	case "$arg" in
		--dev) extra_args+=(--allowexecute); dev_build=yes ;;
		*) echo "unknown argument: $arg" >&2; exit 2 ;;
	esac
done

if [[ ! -f "$DP3" ]]; then
	echo "dp3 packager not found at $DP3 (set DP3=...)" >&2
	exit 1
fi

# A key in the source tree could be committed or packed into a release:
# the dev key only ever exists in the stage of a dev build.
if [[ -e "$ROOT/src/common/devkey.lua" ]]; then
	echo "src/common/devkey.lua must not exist: the dev key is written into the stage of a dev build only" \
		"(docs/dev-loop.md, Security); delete it" >&2
	exit 1
fi

dev_key=""
if [[ "$dev_build" == yes ]]; then
	# devserver.py creates the key file if missing (0600) and checks it; it
	# prints the path on stdout and the fingerprint on stderr.
	key_file="$(python3 "$ROOT/tools/devserver.py" --ensure-key)" || exit 1
	IFS= read -r dev_key < "$key_file" || true
	if [[ ! "$dev_key" =~ ^[0-9a-f]{64}$ ]]; then
		echo "the dev key in $key_file is not 64 lowercase hex characters" >&2
		exit 1
	fi
fi

version="$(git -C "$ROOT" rev-list --count HEAD)"
if [[ -n "$(git -C "$ROOT" status --porcelain -- src)" ]]; then
	echo "warning: src/ has uncommitted changes; version $version may repeat" >&2
fi

# The changelog at the bottom of every Documentation tab (docs/changelog-design.md
# §3): rendered once from CHANGELOG.md, as this release when HEAD carries a
# v* tag, as a development build in a --dev build, else as it stands.
# The Release workflow names its tag in C4_HUE_RELEASE_TAG: a commit can carry both a
# prerelease tag and a stable one, and describe would pick either.
release_tag="${C4_HUE_RELEASE_TAG:-$(git -C "$ROOT" describe --tags --exact-match --match 'v*' HEAD 2>/dev/null || true)}"
changelog_args=()
if [[ "$dev_build" == yes ]]; then
	changelog_args=(--dev-build "$version")
elif [[ -n "$release_tag" ]]; then
	changelog_args=(--release "${release_tag#v}" --build "$version" --date "$(date -u +%F)")
fi
changelog_html="$ROOT/build/changelog.html"
mkdir -p "$ROOT/build"
python3 -I "$ROOT/tools/changelog.py" check --file "$ROOT/CHANGELOG.md" >/dev/null
python3 -I "$ROOT/tools/changelog.py" html --file "$ROOT/CHANGELOG.md" "${changelog_args[@]}" > "$changelog_html"

stage_root="$ROOT/build/stage"
rm -rf "$stage_root"
mkdir -p "$stage_root"
if [[ "$dev_build" == yes ]]; then
	# Even a build that fails half-way leaves no key in the stage.
	trap 'rm -f "$stage_root"/*/common/devkey.lua' EXIT
fi

for driver in "${DRIVERS[@]}"; do
	stage="$stage_root/$driver"
	cp -R "$ROOT/src/$driver" "$stage"
	cp -R "$ROOT/src/common" "$stage/common"
	if [[ "$dev_build" == yes ]]; then
		# What common/devloop.lua checks every bundle and command against.
		# printf is a builtin, so the key is on no command line.
		(umask 077 && printf 'return "%s"\n' "$dev_key" > "$stage/common/devkey.lua")
	else
		# Release builds: no dev loop, none of the bridge's development
		# handlers (bridge/devtools.lua) nor the connection experiment and
		# pinning check modules they drive, and none of the DEV-ONLY
		# properties and actions.
		rm -f "$stage/common/devloop.lua" "$stage/bridge/devtools.lua" \
			"$stage/bridge/conntest.lua" "$stage/bridge/pinning.lua"
		awk '/<!-- DEV-ONLY BEGIN/ { skip = 1 } !skip { print } /<!-- DEV-ONLY END -->/ { skip = 0 }' \
			"$stage/driver.xml" > "$stage/driver.xml.release" && mv "$stage/driver.xml.release" "$stage/driver.xml"
		if grep -q "DEV-ONLY" "$stage/driver.xml" || [[ -e "$stage/bridge/devtools.lua" || -e "$stage/common/devloop.lua" \
			|| -e "$stage/common/devkey.lua" || -e "$stage/bridge/conntest.lua" || -e "$stage/bridge/pinning.lua" ]]; then
			echo "release build still carries development items in $driver" >&2
			exit 1
		fi
	fi
	# The changelog replaces the marker line in the staged manual only; src/
	# keeps the marker. A manual without the marker fails the build.
	doc="$stage/www/documentation.html"
	if [[ "$(grep -c '^<!-- CHANGELOG -->$' "$doc")" != 1 ]]; then
		echo "$doc: needs exactly one <!-- CHANGELOG --> line (docs/changelog-design.md)" >&2
		exit 1
	fi
	python3 -I - "$doc" "$changelog_html" <<'PY'
import sys
doc, fragment = sys.argv[1], sys.argv[2]
with open(doc, encoding="utf-8") as f:
    text = f.read()
with open(fragment, encoding="utf-8") as f:
    html = f.read().rstrip("\n")
with open(doc, "w", encoding="utf-8") as f:
    f.write(text.replace("<!-- CHANGELOG -->", html, 1))
PY
	# Apache 2.0 §4: the license and notice travel with every package.
	cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$stage/"
	# The device drivers' shared module is of no use to the bridge.
	if [[ "$driver" == hue_bridge ]]; then
		rm -f "$stage/common/device.lua"
	fi
	# The drivers' own copy of the version: Director's answer is empty at the
	# first init of a device created by AddDevice (docs/status.md, 2026-10-24).
	printf 'return "%s"\n' "$version" > "$stage/common/build_version.lua"

	# dp3 only stamps <version>/<modified> when building from a manifest, so
	# generate one listing everything staged (directories recursively).
	manifest="$stage/$driver.c4zproj"
	{
		echo "<Driver type=\"c4z\" name=\"$driver\" squishLua=\"false\">"
		echo "<Items>"
		for entry in "$stage"/*; do
			name="$(basename "$entry")"
			[[ "$name" == "$driver.c4zproj" ]] && continue
			if [[ -d "$entry" ]]; then
				echo "	<Item type=\"dir\" name=\"$name\" recurse=\"true\"/>"
			else
				echo "	<Item type=\"file\" name=\"$name\"/>"
			fi
		done
		echo "</Items>"
		echo "</Driver>"
	} > "$manifest"

	rm -f "$ROOT/build/$driver.c4z"
	python3 "$DP3" --driver-version "$version" --update-modified "${extra_args[@]}" \
		"$stage" "$ROOT/build" "$driver.c4zproj" >/dev/null

	if [[ ! -f "$ROOT/build/$driver.c4z" ]]; then
		echo "dp3 did not produce build/$driver.c4z" >&2
		exit 1
	fi
	if [[ "$dev_build" == yes ]]; then
		# The package carries the key: as secret as the key file.
		chmod 600 "$ROOT/build/$driver.c4z"
		rm -f "$stage/common/devkey.lua"
		echo "built build/$driver.c4z (version $version, DEV build, carries the dev key)"
	else
		echo "built build/$driver.c4z (version $version)"
	fi
done

# build/manifest.json: what this build is, for the release assets and for
# tools/deploy.py (docs/cicd-gitops-design.md, section 5.2). The tag is the
# exact release tag on HEAD, or null for a build between releases.
tag="$release_tag"
commit="$(git -C "$ROOT" rev-parse HEAD)"
dev_json=false
[[ "$dev_build" == yes ]] && dev_json=true
{
	echo "{"
	echo "  \"schema\": 1,"
	if [[ -n "$tag" ]]; then
		echo "  \"tag\": \"$tag\","
		echo "  \"version\": \"${tag#v}\","
	else
		echo "  \"tag\": null,"
		echo "  \"version\": null,"
	fi
	echo "  \"build\": $version,"
	echo "  \"commit\": \"$commit\","
	echo "  \"built_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
	echo "  \"dev\": $dev_json,"
	echo "  \"packages\": {"
	last="${DRIVERS[${#DRIVERS[@]}-1]}"
	for driver in "${DRIVERS[@]}"; do
		sum="$(sha256sum "$ROOT/build/$driver.c4z" | cut -d' ' -f1)"
		bytes="$(stat -c %s "$ROOT/build/$driver.c4z")"
		sep=","
		[[ "$driver" == "$last" ]] && sep=""
		echo "    \"$driver.c4z\": {\"sha256\": \"$sum\", \"bytes\": $bytes}$sep"
	done
	echo "  }"
	echo "}"
} > "$ROOT/build/manifest.json"
python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$ROOT/build/manifest.json"
echo "wrote build/manifest.json (build $version${tag:+, $tag})"
