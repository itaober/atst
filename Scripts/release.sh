#!/usr/bin/env bash
#
# One-shot release script for atst.
#
# Usage:
#   bash Scripts/release.sh v0.1.2
#
# What it does:
#   1. Sanity-checks the version arg and the working tree
#   2. Verifies the version section exists in both CHANGELOG.md and
#      CHANGELOG.zh-CN.md
#   3. Builds the .app + DMG via Scripts/build-dmg.sh
#   4. Tags HEAD with the version
#   5. Pushes the tag to origin
#   6. Creates a GitHub release titled exactly with the version, body
#      auto-stitched from the two CHANGELOG sections (EN + zh-CN), DMG
#      attached
#
# Notes:
#   - The script refuses to run if the working tree is dirty or the
#     CHANGELOG sections are empty / placeholder
#   - It does NOT write back to the CHANGELOG; renaming "Unreleased" →
#     "vX.Y.Z" stays a manual edit you commit before tagging, so the
#     release diff is reviewable

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1:-}"

if [[ -z "$VERSION" ]]; then
  echo "Usage: bash Scripts/release.sh vX.Y.Z" >&2
  exit 1
fi

if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "✗ Version must look like 'v1.2.3' (got '$VERSION')" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "✗ Working tree is dirty. Commit or stash your changes first." >&2
  git status --short >&2
  exit 1
fi

if git rev-parse "$VERSION" >/dev/null 2>&1; then
  echo "✗ Tag $VERSION already exists locally." >&2
  exit 1
fi

# Pull the section between '## vX.Y.Z' and the next '## ' header out of
# a CHANGELOG file. Strips leading/trailing blank lines.
extract_section() {
  local file="$1"
  awk -v ver="## $VERSION" '
    $0 == ver       { in_section = 1; next }
    in_section && /^## / { exit }
    in_section      { print }
  ' "$file" | awk 'NF { found = 1 } found' | awk '
    { lines[NR] = $0 }
    END {
      # Trim trailing blank lines
      while (NR > 0 && lines[NR] == "") NR--
      for (i = 1; i <= NR; i++) print lines[i]
    }
  '
}

EN_NOTES="$(extract_section CHANGELOG.md)"
ZH_NOTES="$(extract_section CHANGELOG.zh-CN.md)"

if [[ -z "$EN_NOTES" ]]; then
  echo "✗ No '## $VERSION' section found in CHANGELOG.md. Add it and rerun." >&2
  exit 1
fi
if [[ -z "$ZH_NOTES" ]]; then
  echo "✗ No '## $VERSION' section found in CHANGELOG.zh-CN.md. Add it and rerun." >&2
  exit 1
fi

echo "→ Building DMG"
bash Scripts/build-dmg.sh

DMG_PATH="$ROOT_DIR/.build/atst.dmg"
if [[ ! -f "$DMG_PATH" ]]; then
  echo "✗ DMG missing at $DMG_PATH" >&2
  exit 1
fi

DMG_SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
echo "→ DMG SHA-256: $DMG_SHA"

echo "→ Creating git tag $VERSION"
git tag -a "$VERSION" -m "$VERSION"
git push origin "$VERSION"

# Assemble bilingual release notes. Title is intentionally just the
# version — descriptive subtitles live in CHANGELOG bullets, not in the
# release header.
NOTES_FILE="$(mktemp)"
cat > "$NOTES_FILE" <<EOF
## English

$EN_NOTES

## 简体中文

$ZH_NOTES

---

\`\`\`
shasum -a 256 atst.dmg
$DMG_SHA  atst.dmg
\`\`\`
EOF

echo "→ Creating GitHub release"
gh release create "$VERSION" \
  --repo itaober/atst \
  --title "$VERSION" \
  --notes-file "$NOTES_FILE" \
  "$DMG_PATH"

rm -f "$NOTES_FILE"

echo "✓ Released $VERSION → https://github.com/itaober/atst/releases/tag/$VERSION"
