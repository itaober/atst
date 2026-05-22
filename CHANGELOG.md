# Changelog

[简体中文](./CHANGELOG.zh-CN.md)

All notable changes are recorded here. Each version section is what gets pasted into the matching GitHub release notes.

## Unreleased

(no changes yet)

## v0.1.2

- Target language dropdown now uses a native AppKit popup button (cleaner chevron)
- Bilingual `CHANGELOG.md` / `CHANGELOG.zh-CN.md` introduced
- `Scripts/release.sh` ties together build + git tag + GitHub release in one command

## v0.1.1

- Interface language picker added (Auto / English / 中文); Auto follows the system locale
- Target language is a dropdown over a curated preset list
- Default request timeout 60s → 10s
- README clarifies the `atst` acronym (`a` AI · `t` text · `s` select · `t` translate)
- Highlight tiny footprint (~2 MB DMG, ~4 MB installed)
- Liquid Glass tooltip recorded as a roadmap entry (auto-enables on macOS 26 + Xcode 26 / Swift 6.2)

## v0.1.0

- Initial public release.
