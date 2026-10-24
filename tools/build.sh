#!/usr/bin/env bash
# Build build/hue_bridge.c4z, build/hue_light.c4z and build/hue_scene.c4z with Control4's dp3 packager.
#
# Usage: tools/build.sh [--dev]
#   --dev   developer build: ships common/devloop.lua (the self-reloading dev
#           loop, see docs/dev-loop.md) and allows the Lua command window in
#           Composer (dp3 --allowexecute). Release builds contain neither.
#
# Each driver is staged into build/stage/<driver>/ with src/common copied in
# as common/, so `require("common.log")` resolves inside the .c4z the same way
# it does in the tests. The driver.xml <version> is set to the git commit
# count so every build from a newer commit is seen by Composer as an update.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DP3="${DP3:-$HOME/c4-tools/drivers-driverpackager/dp3/driverpackager.py}"
DRIVERS=(hue_bridge hue_light hue_scene)

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

version="$(git -C "$ROOT" rev-list --count HEAD)"
if [[ -n "$(git -C "$ROOT" status --porcelain -- src)" ]]; then
	echo "warning: src/ has uncommitted changes; version $version may repeat" >&2
fi

stage_root="$ROOT/build/stage"
rm -rf "$stage_root"
mkdir -p "$stage_root"

for driver in "${DRIVERS[@]}"; do
	stage="$stage_root/$driver"
	cp -R "$ROOT/src/$driver" "$stage"
	cp -R "$ROOT/src/common" "$stage/common"
	if [[ "$dev_build" != yes ]]; then
		# Release builds: no dev loop, none of the bridge's development
		# handlers (bridge/devtools.lua) nor the connection experiment and
		# pinning check modules they drive, and none of the DEV-ONLY
		# properties and actions.
		rm -f "$stage/common/devloop.lua" "$stage/bridge/devtools.lua" \
			"$stage/bridge/conntest.lua" "$stage/bridge/pinning.lua"
		awk '/<!-- DEV-ONLY BEGIN/ { skip = 1 } !skip { print } /<!-- DEV-ONLY END -->/ { skip = 0 }' \
			"$stage/driver.xml" > "$stage/driver.xml.release" && mv "$stage/driver.xml.release" "$stage/driver.xml"
		if grep -q "DEV-ONLY" "$stage/driver.xml" || [[ -e "$stage/bridge/devtools.lua" || -e "$stage/common/devloop.lua" ]]; then
			echo "release build still carries development items in $driver" >&2
			exit 1
		fi
	fi
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
		echo "built build/$driver.c4z (version $version, DEV build)"
	else
		echo "built build/$driver.c4z (version $version)"
	fi
done
