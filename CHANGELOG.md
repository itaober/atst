# Changelog

[简体中文](./CHANGELOG.zh-CN.md)

All notable changes are recorded here. Each version section is what gets pasted into the matching GitHub release notes.

## Unreleased

(no changes yet)

## v0.2.0

- Translation tooltips and pinned notes now use native Liquid Glass on macOS 26+ when built with Swift 6.2+, while older systems automatically keep the existing AppKit tooltip material fallback

## v0.1.3

- General settings layout unified: every control in the section now aligns to a single right-edge guideline; target-language picker is upsized so its value reads as clearly as the row label
- Tooltip width now adapts to the source — short selections stay compact (320pt), long sentences or multi-line input expand to 480pt for comfortable reading
- Tooltip can no longer overflow the screen: a built-in ScrollView caps content at the available height, and the scroll bar disappears automatically when you drag the panel to a position with more room
- Cache is more selective: multi-line text, sentences over 200 chars, inputs containing URLs, and empty / punctuation-only results are all skipped — the cache fills with high-reuse words and phrases instead of single-use chunks
- App icon source is now full-bleed: the icon's source PNG controls the full visual (background + artwork) rather than being centred inside a system-drawn white squircle, eliminating the previous "tiny artwork inside a big white frame" problem

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
