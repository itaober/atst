#!/usr/bin/env bash
#
# Build a distributable .dmg installer for atst.
#
# Pipeline:
#   1. Build the .app via Scripts/build-app.sh (release config, signed).
#   2. Stage a temporary folder with the .app plus an /Applications symlink.
#   3. hdiutil produces a compressed read-only DMG into .build/atst.dmg.
#
# Output: $ROOT/.build/atst.dmg

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="atst"
APP_DIR="$ROOT_DIR/.build/$APP_NAME.app"
DMG_PATH="$ROOT_DIR/.build/$APP_NAME.dmg"
DMG_VOLUME_NAME="$APP_NAME"
DMG_STAGING="$ROOT_DIR/.build/dmg-staging"

cd "$ROOT_DIR"

echo "→ Building the .app bundle"
bash "$ROOT_DIR/Scripts/build-app.sh" >/dev/null

if [[ ! -d "$APP_DIR" ]]; then
  echo "✗ Expected $APP_DIR after build-app.sh, but it doesn't exist."
  exit 1
fi

echo "→ Preparing DMG staging directory"
rm -rf "$DMG_STAGING" "$DMG_PATH"
mkdir -p "$DMG_STAGING"
# Copy the .app into the staging dir (preserving signature) and add a
# clickable shortcut to /Applications so the user can drag-and-drop.
cp -R "$APP_DIR" "$DMG_STAGING/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING/Applications"

echo "→ Creating compressed DMG"
# `hdiutil create -srcfolder` mounts a temporary volume, copies into it and
# unmounts. On machines where an indexer or endpoint agent grabs every new
# volume, that unmount fails with "Resource busy" (49168) — reproducibly,
# even for a folder holding one text file, and `-nospotlight` doesn't help.
# `makehybrid` writes the HFS+ image straight from the folder without
# mounting anything; `convert` then compresses it into the same UDZO
# format as before. Symlinks (the /Applications shortcut) survive.
DMG_RAW="$ROOT_DIR/.build/$APP_NAME-raw.dmg"
rm -f "$DMG_RAW"
hdiutil makehybrid -hfs -hfs-volume-name "$DMG_VOLUME_NAME" -o "$DMG_RAW" "$DMG_STAGING" >/dev/null
hdiutil convert "$DMG_RAW" -format UDZO -ov -o "$DMG_PATH" >/dev/null
rm -f "$DMG_RAW"

rm -rf "$DMG_STAGING"

DMG_SIZE=$(du -h "$DMG_PATH" | awk '{print $1}')
echo "✓ Built $DMG_PATH ($DMG_SIZE)"
