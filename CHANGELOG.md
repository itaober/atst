# Changelog

[简体中文](./CHANGELOG.zh-CN.md)

All notable changes are recorded here. Each version section is what gets pasted into the matching GitHub release notes.

## Unreleased

(no changes yet)

## v0.3.0

- **Translation activity sparkline** — stats section gains a 14-day mini chart showing daily translation volume. Solid line counts every translation (cache hits included); dashed line counts only fresh translations (cache misses). Hover any day for a popover with that day's exact numbers
- **Minimum macOS version raised to 14 (Sonoma)** — unlocks the native `chartXSelection` API for the sparkline's mouse-following tooltip. macOS 13 (Ventura) is no longer supported
- DMG size reduced ~60% (from ~5.3 MB to ~2.0 MB) thanks to pngquant-compressed app icon during build. Visually identical at icon render sizes
- Fixed pasteboard restoration when selection translation is re-triggered mid-capture — your original clipboard contents are no longer lost on rapid-fire ⌥D presses
- Trimmed the "Hotkeys blocked by another app" warning to one sentence (was a full paragraph)

## v0.2.2

- New "Notes on all desktops" toggle in General settings — when on, pinned notes follow you across Spaces / desktop switches instead of staying on the desktop they were pinned on. Default off; flipping it updates already-pinned notes live without needing to re-pin
- Settings copy polished throughout — tightened bilingual subtitles, dropped mixed-language phrases, renamed "TTL (days)" to "Days to keep" for clarity, fixed the Chinese "Reset" button label
- Fixed vertical alignment of items in the OCR recognition-language chip row — the "+ Add" pill and language chips are now centered on the same baseline rather than top-aligned

## v0.2.1

- Settings panel adopts Liquid Glass on macOS 26+ (Swift 6.2+ builds), matching the tooltip / pinned-note treatment from v0.2.0; older systems fall back to the existing menu material automatically
- All four right-side controls in the General page (target language, timeout, interface language, appearance) now align to a single right edge — segmented pickers no longer drift based on label width
- Settings header gains a version label (`atst v0.2.1`) that links to the matching release page, plus an auto-update pill that surfaces when a newer GitHub release is available
- Google translation now preserves newlines and blank lines in multi-line selections, keeping list / paragraph structure intact
- API providers can be reordered with ▲/▼ buttons in the API subpage; the tooltip and result panel honour the new order
- "翻译方式" section in General now lists API Translation above AI Translation, matching the tooltip layout
- Diagnostic for the macOS Secure Keyboard Entry trap: if another app (e.g. 1Password) is holding secure input, an orange warning now surfaces in Settings so the hotkey-not-working case is identifiable in seconds rather than mistaken for a permission bug
- Comprehensive internal cleanup pass — removed dead code, unused fields / parameters, vestigial methods, and orphaned UI files; no behaviour change

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
