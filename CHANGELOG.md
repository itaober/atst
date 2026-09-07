# Changelog

[简体中文](./CHANGELOG.zh-CN.md)

All notable changes are recorded here. Each version section is what gets pasted into the matching GitHub release notes.

## Unreleased

- **Line breaks survive translation** — the AI prompt now demands the source's line / paragraph structure, Microsoft translates line by line like Google, and screenshot OCR merges soft-wrapped lines inside a paragraph so line-by-line translators see whole sentences
- **Reverse translation** — when the selection is already in your target language it's translated into a new **Secondary language** setting instead (Chinese ⇄ English by default)
- **Type to translate** — `⌥D` with nothing selected opens a text box in the tooltip; Return translates, Shift+Return inserts a newline
- **Launch at login** toggle in General settings
- **First-launch Accessibility prompt** — without the grant the hotkeys could never fire, and a fresh install sat there silently; the app now asks once per version and opens settings
- Tooltip header shows the detected source language and the target (`English → 简体中文`) instead of the app name
- Google and Microsoft rows merge into one when they return the same text
- A provider that fails three times in a row collapses to a single line with a **Disable** button instead of a full error every time
- `Esc` dismisses the tooltip (it never could — the panel wasn't a key window)
- Selection is read through the Accessibility API first (instant, no clipboard round-trip); the ⌘C fallback gives up after 0.6 s instead of 1.2 s, so the input box appears faster when nothing is selected
- Google / Microsoft errors are labelled with the provider's name instead of "AI"
- Pronunciation picks a voice matching the detected language instead of the system locale
- AI few-shot examples follow the target language (English targets no longer see Chinese examples)
- Connection prewarming happens when you press a hotkey's modifier key, replacing a permanent 4-minute timer
- Settings: permission rows drop the redundant refresh button; Timeout moves to the AI page (it never applied to Google / Microsoft); Reset restores everything except the AI endpoint, key and models; every toggle uses the same compact size
- README: corrected the Accessibility install step, added Troubleshooting, Apple Silicon requirement, fuller Privacy notes, environment-variable overrides; roadmap trimmed of shipped items

## v0.3.1

- Tooltip header is easier to grab — the drag region now bleeds edge-to-edge of the floating panel without changing the header's visible size, so you don't need pixel-perfect aim on the 22pt strip
- Cache size in Stats no longer wraps to two lines — the unit (KB / MB) renders in a smaller font next to the number, and the formatter switches to 1024-based progression (1 KB at 1024 bytes, not 1000) to match developer-tool conventions

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
