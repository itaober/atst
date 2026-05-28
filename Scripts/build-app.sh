#!/usr/bin/env bash
#
# Build atst.app as an installable bundle.
#
# Version handling:
#   - If $ATST_VERSION is set (e.g. "v0.1.3" or "0.1.3"), strip any
#     leading "v" and write the result into Info.plist's
#     CFBundleShortVersionString. Released DMGs flow through release.sh,
#     which sets this for us.
#   - If $ATST_VERSION is unset, fall back to "dev". The app reads this
#     value at runtime to render "atst v0.1.3" in the settings header,
#     or "atst dev" for local builds.
#
# Output: .build/atst.app (release-config, ad-hoc codesigned)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="atst"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_DIR="$ROOT_DIR/.build/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Version string for Info.plist. Strip a leading "v" if present so
# CFBundleShortVersionString is the bare semver (Apple-conventional).
VERSION="${ATST_VERSION:-dev}"
VERSION_STRIPPED="${VERSION#v}"

cd "$ROOT_DIR"
swift build -c release
swift Scripts/generate-icons.swift

# Compress the iconset PNGs (lossy but visually identical at icon sizes)
# and re-pack the icns. Cuts AppIcon.icns from ~4.2 MB to ~1.2 MB
# (-71%), which is the main contributor to the .app bundle size.
# Skipped silently if pngquant isn't installed — keeps the build working
# for fresh checkouts without forcing a brew install.
if command -v pngquant >/dev/null 2>&1; then
  for png in Resources/AppIcon.iconset/*.png; do
    pngquant --quality=80-95 --speed 1 --skip-if-larger --force --output "$png" "$png" || true
  done
  iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
else
  echo "ℹ️  pngquant not found — skipping icon compression. Install with: brew install pngquant"
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BUILD_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>dev.local.atst</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION_STRIPPED</string>
  <key>CFBundleVersion</key>
  <string>$VERSION_STRIPPED</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026</string>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --deep --sign - --requirements '=designated => identifier "dev.local.atst"' "$APP_DIR"

echo "$APP_DIR"
