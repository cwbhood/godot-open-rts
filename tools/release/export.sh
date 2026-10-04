#!/usr/bin/env bash
# Export Ironbound for Windows, Linux and macOS and zip each build with a SHA-256 list.
#
#   GODOT=/path/to/godot tools/release/export.sh VERSION [windows linux macos]
#
# PROJECT_DIR=/path/to/checkout builds another checkout (the release workflow uses
# this to build any branch with the newest copy of this script).
#
# Needs Godot 4.7.2 with matching export templates installed. Output goes to dist/:
#   Ironbound-windows-x86_64.zip, Ironbound-linux-x86_64.zip, Ironbound-macos-universal.zip,
#   SHA256SUMS.txt
# The file names carry no version so the website can link to
# releases/latest/download/<name> and always get the newest build.
set -euo pipefail

VERSION="${1:?usage: export.sh VERSION [platforms...]}"
shift
PLATFORMS=("$@")
[ ${#PLATFORMS[@]} -eq 0 ] && PLATFORMS=(windows linux macos)
GODOT="${GODOT:-godot}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${PROJECT_DIR:-$HERE/../..}" && pwd)"
DIST="$ROOT/dist"
STAGE="$DIST/stage"
NOTES="$HERE/README-FIRST.txt"

cd "$ROOT"
rm -rf "$DIST"
mkdir -p "$STAGE"

# Crash reports from exported builds read the commit and branch from this file.
COMMIT="$(git rev-parse --short=10 HEAD 2>/dev/null || echo unknown)"
BRANCH="${BUILD_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)}"
printf '{"commit": "%s", "branch": "%s", "version": "%s"}\n' "$COMMIT" "$BRANCH" "$VERSION" > build_info.json

# macOS universal builds need ETC2/ASTC textures (Apple Silicon). Turn the import
# on for this build only and put project.godot back afterwards.
if printf '%s\n' "${PLATFORMS[@]}" | grep -qx macos && ! grep -q '^textures/vram_compression/import_etc2_astc=true' project.godot; then
	BACKUP="$(mktemp)"
	cp project.godot "$BACKUP"
	trap 'cp "$BACKUP" project.godot; rm -f "$BACKUP"' EXIT
	python3 - <<'PY'
import re
text = open("project.godot").read()
line = "textures/vram_compression/import_etc2_astc=true\n"
if re.search(r"^\[rendering\]\s*$", text, re.M):
    text = re.sub(r"^(\[rendering\]\s*\n)", lambda m: m.group(1) + "\n" + line, text, count=1, flags=re.M)
else:
    text = text.rstrip("\n") + "\n\n[rendering]\n\n" + line
open("project.godot", "w").write(text)
PY
fi

# Build the import cache once. The first pass can log errors for scenes whose
# dependencies are not imported yet, so it runs twice.
"$GODOT" --headless --path . --import || true
"$GODOT" --headless --path . --import

export_one() {
	local preset="$1" out="$2"
	mkdir -p "$(dirname "$out")"
	"$GODOT" --headless --path . --export-release "$preset" "$out"
	[ -s "$out" ] || { echo "export of $preset produced nothing" >&2; exit 1; }
}

with_notes() {
	sed "s/@VERSION@/$VERSION/; s/@COMMIT@/$COMMIT/" "$NOTES" > "$1/README-FIRST.txt"
	cp LICENSE "$1/LICENSE.txt"
	[ -f ASSET_CREDITS.md ] && cp ASSET_CREDITS.md "$1/ASSET_CREDITS.md"
	return 0
}

for platform in "${PLATFORMS[@]}"; do
	case "$platform" in
	windows)
		dir="$STAGE/Ironbound-windows"
		export_one "Windows Desktop" "$dir/Ironbound.exe"
		with_notes "$dir"
		(cd "$STAGE" && zip -qr9 "$DIST/Ironbound-windows-x86_64.zip" "Ironbound-windows")
		;;
	linux)
		dir="$STAGE/Ironbound-linux"
		export_one "Linux/X11" "$dir/Ironbound.x86_64"
		chmod +x "$dir/Ironbound.x86_64"
		with_notes "$dir"
		(cd "$STAGE" && zip -qr9 "$DIST/Ironbound-linux-x86_64.zip" "Ironbound-linux")
		;;
	macos)
		# Godot writes a zip holding the .app, named after config/name (ad-hoc signed, not notarized).
		export_one "macOS" "$DIST/Ironbound-macos-universal.zip"
		mkdir -p "$STAGE/macos-notes"
		with_notes "$STAGE/macos-notes"
		(cd "$STAGE/macos-notes" && zip -qj9 "$DIST/Ironbound-macos-universal.zip" ./*)
		;;
	*)
		echo "unknown platform: $platform" >&2
		exit 1
		;;
	esac
done

rm -rf "$STAGE"
(cd "$DIST" && sha256sum Ironbound-*.zip > SHA256SUMS.txt && cat SHA256SUMS.txt)
