#!/usr/bin/env bash
# Build build/hue_bridge.c4z and build/hue_light.c4z with Control4's dp3 packager.
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
DRIVERS=(hue_bridge hue_light)

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
		rm -f "$stage/common/devloop.lua"
	fi

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
