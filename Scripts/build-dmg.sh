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
hdiutil create \
  -volname "$DMG_VOLUME_NAME" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

rm -rf "$DMG_STAGING"

DMG_SIZE=$(du -h "$DMG_PATH" | awk '{print $1}')
echo "✓ Built $DMG_PATH ($DMG_SIZE)"
