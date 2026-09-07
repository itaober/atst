# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**atst** (`a(i)-text-select-translate`) is a tiny macOS menu-bar translator written in pure Swift + SwiftUI + AppKit. No third-party deps. macOS 14+, Swift 5.9+ (Package.swift). The product is shipped as a self-signed `.app` inside a DMG.

## Commands

```bash
# Build for debug + run inline (fastest dev loop)
swift run atst

# Compile only
swift build

# Package a fully-formed .app bundle (release config, icons, Info.plist,
# ad-hoc codesign). Output: .build/atst.app
bash Scripts/build-app.sh

# Same as above, then wrap in a compressed DMG with /Applications symlink.
# Output: .build/atst.dmg
bash Scripts/build-dmg.sh

# Cut a release. Reads ## vX.Y.Z sections from both CHANGELOG files,
# builds DMG, tags, pushes tag, creates GitHub release titled "vX.Y.Z"
# with bilingual notes auto-stitched from CHANGELOG + sha256 in body.
# Refuses on dirty tree / missing CHANGELOG section / duplicate tag.
bash Scripts/release.sh v0.1.3
```

There is **no test suite**. Verify changes by `swift build` (catches type errors), then `bash Scripts/build-app.sh && open .build/atst.app` for runtime smoke tests.

## High-level architecture

### Two parallel translation flows

The app has two top-level user actions that take very different code paths:

1. **Selection translation** (`⌥D`) → `AppDelegate.translateSelection` → `viewModel.translateSelection` → fans out across every enabled `TranslationProvider` in parallel. The UI shows API rows (Google / Microsoft) stacked above an AI row.

2. **Screenshot translation** (`⌥S`) → `AppDelegate.translateScreenshot` → forks on `screenshotUseVisionOCR`:
   - **OCR ON (default)**: `VisionOCRService` → text → reuse `translateSelection` (so screenshots also get the multi-provider UI)
   - **OCR OFF, or OCR returned no text**: fall back to AI vision via `ScreenshotVisionService` (the legacy single-source path)
   - **AI vision unavailable**: surface `AppError.aiDisabledForVision` with a recovery hint

Anything you change to selection translation automatically benefits screenshot-with-OCR. Don't try to unify the AI vision path into `TranslationProvider` — image input has fundamentally different message shape and constraints, and `Google` / `Microsoft` can't accept images anyway.

Two more entry points feed the same `translateSelection` pipeline:

- **Manual input** — `TranslationState.input` renders a `TextEditor` in the tooltip; the panel is made key without activating the app, and its width follows the typed text with the normal `TooltipSizing` rule so the result doesn't jump. Reached from `⌥D` with nothing selected (`AppError.noSelectedText`); submission goes through `AppDelegate.translateText`, which the header refresh also uses (with `bypassCache: true`).
- **Reverse translation** — `TranslatorViewModel.resolveLanguages` runs `LanguageDetector` (NaturalLanguage, on-device) on the source. If it's confidently (≥0.5) the configured target language, providers are built for `secondaryTargetLanguage` instead. Cache keys, the AI prompt and the header label all use the *effective* target, so never read `configuration.targetLanguage` directly inside the translation path.

Line structure is preserved end to end: the AI prompt has an explicit keep-line-breaks rule plus a multi-paragraph example, Google and Microsoft send one array entry per non-blank line via `LineBatch`, and `VisionOCRService` merges soft-wrapped OCR lines into paragraphs (gap / indent / bullet heuristics) before handing text on.

### `TranslationProvider` protocol

In `Sources/atst/Translation/TranslationProvider.swift`. Three implementations:

- `OpenAIProvider` — OpenAI-compatible Chat Completions, SSE streaming, multimodal-aware (text path only; screenshot path lives separately). Owns the XML tag protocol (`<atst-result>` / `<atst-item>` / `<atst-phonetic>` / `<atst-desc>` / `<atst-translatable>`).
- `GoogleProvider` — unofficial `translate-pa.googleapis.com` endpoint. Public API key baked in. HTML entity decoder required for the response.
- `MicrosoftProvider` — unofficial Edge translator endpoint. JWT auth via `MicrosoftAuthToken` actor (cached, auto-refresh with 30s buffer, 401 retry).

Google / Microsoft throw `AppError.providerUnavailable` / `providerRequestFailed(name:detail:)` so their rows never say "AI"; the `ai*` cases are for the OpenAI path only.

All providers return `AsyncThrowingStream<TranslationProviderEmission, Error>` so streaming (AI) and one-shot (API) flows share the same surface. `TranslatorViewModel` doesn't know which kind it's driving.

### Per-segment state

`TranslationState.text(TextSegments)` is the main translation state. `TextSegments` carries an array of `ProviderSegment` for API rows + an optional `ProviderSegment` for AI, plus `sourceLanguage` / `targetLanguage` for the header label. Each segment has its own lifecycle (`loading` / `streaming` / `success` / `failure`) and is updated independently as its provider's stream emits. `ProviderSegment.consecutiveFailures` (in-memory, per app run) drives the collapsed "failed N times · Disable" row once it reaches `APISegmentsBlock.collapseAfterFailures`. Screenshot AI vision uses its own state cases (`screenshotLoading` / `screenshotStreaming` / `screenshotSuccess`) — they're not crammed into `text(...)`.

Row rendering that both the live tooltip and pinned notes need lives in `SegmentRows.swift` (`CopyButton`, `APISegmentsBlock`). `APISegmentsBlock` also merges successful providers with identical text into one "Google · Microsoft" row — do that kind of presentation logic there, not in the view model.

When adding a provider: implement `TranslationProvider`, surface it in `TranslatorViewModel.makeProvider(for:)`, add an `APIProviderEntry` default in `AppConfiguration.defaultAPIProviders`.

### Cache schema (v2)

`TranslationCache` keys are per-segment:

- AI: `v2 | ai | <model> | <targetLang> | p<0/1> | e<0/1> | <normalize(text)>` (phonetic/explanation toggles invalidate)
- API: `v2 | <providerId> | <targetLang> | <normalize(text)>`

Untranslatable results (AI: `<atst-translatable>false</atst-translatable>`; API: source == result heuristic) skip the cache. Legacy `v1|…` keys are auto-purged on launch.

### Bilingual UI

Every user-facing string uses `L.pick("English", "中文")` (in `Sources/atst/Support/L.swift`). `L.override` is set from `AppConfiguration.uiLanguage` (`.auto` follows system, `.english` / `.chinese` lock). `AppDelegate` keeps the override in sync via the `settingsStore.$configuration` sink. **Don't** introduce raw user-facing strings — they break the language toggle.

### Tooltip mechanics

`FloatingPanelController` owns a single live `NSPanel` reused across translations. Sizing is driven from SwiftUI (`readSize` in `TranslationResultView`) into `setContentSize` with top-left anchoring (see the `TooltipPanel` subclass) so animations don't fight a moving y-origin.

Placement uses a Web-style flip algorithm: convert any anchor (mouse / point / rect) to a rect, then try right → below → above → left and pick the first that fully fits the screen's `visibleFrame`. Screenshots feed in via a `recognisedRect` reverse-engineered from PNG dimensions + mouse-release position in `ScreenshotProvider`.

The header strip is draggable — `WindowDragHandle` (in `TooltipShared.swift`) is an `NSViewRepresentable` layered as the header's `.background`; buttons sit on top and capture their own clicks. `panel.isMovable = true` but `isMovableByWindowBackground = false` so the translation body keeps `.textSelection(.enabled)` working.

`TooltipPanel` overrides `canBecomeKey` to `true` (needed for the manual-input editor); it's a `.nonactivatingPanel`, and the `⌥D` path shows it with `orderFrontRegardless` so the user's app keeps focus. Because the panel is not key after `⌥D`, **Esc is handled in the global CGEventTap** (`GlobalHotKeyMonitor.onEscape` → `FloatingPanelController.closeIfVisible`), not by a local key monitor.

Pinned notes (`PinnedNoteView`) are independent windows constructed from a `PinnedNoteSnapshot` of the live tooltip's segments. They use a separate `PinnedNoteController` and are draggable via the whole window background (different from the live tooltip — pinned notes are meant to be repositioned freely).

### Settings shell

`MenuBarSettingsView` is a thin three-page shell (header / footer / routing / save / reset) driven by a `[SettingsRoute]` stack:
- **General** (root, `SettingsGeneralPage.swift`) — permissions, target + secondary language, UI language, appearance, launch at login, pinned-note behaviour, provider toggles, hotkeys, OCR languages, cache; stats sparkline in `SettingsStatsSection.swift`
- **AI Translation** subpage — OpenAI-compatible config (incl. Timeout, which only applies to the AI request) + prompts nav
- **API Translation** subpage — built-in providers + future custom-HTTP placeholder
- **Translation Prompts** sub-subpage — system + smart-explanation prompt editors

When extending: prefer adding a row inside the existing General sections rather than creating a fourth page; the panel width is fixed and pages should feel like a single tool. Reset restores `defaultConfig` wholesale except the AI endpoint fields (URL, key, models).

## Release workflow

1. Make code changes, commit, push.
2. Add a `## vX.Y.Z` section to **both** `CHANGELOG.md` and `CHANGELOG.zh-CN.md`. The script reads bullets verbatim out of each section.
3. Commit the CHANGELOG update.
4. `bash Scripts/release.sh vX.Y.Z` — builds DMG, tags, pushes tag, creates the GitHub release.

Release titles are version-only (`v0.1.2`, not `v0.1.2 — feature X`). Notes are bilingual changelog excerpts; do **not** duplicate install instructions there — the README already covers them.

`release.sh` sets `ATST_VERSION=$VERSION` before invoking `build-dmg.sh`. That env var threads down to `build-app.sh`, which writes the stripped semver (`0.1.3`) into the .app's `CFBundleShortVersionString`. `Branding.versionDisplay` reads that at runtime to render `atst v0.1.3` in the settings header. Local `swift run` builds and unflagged `build-app.sh` runs fall back to `dev`, which `Branding` displays verbatim.

`UpdateChecker` hits `api.github.com/repos/itaober/atst/releases/latest` once per app launch (and on settings-open, throttled to a 4h TTL). A newer tag → an orange "Update vX.Y.Z" pill next to the title that opens the GitHub release page. Private-repo gotcha: the API returns 403 to unauthenticated requests against private repos, so the pill silently never appears. Make the repo public for this feature to surface anything.

## Conventions worth knowing

- **XML output protocol** is the contract between AI prompts and `TranslationOutputParser`. Any change to tag names (`atst-result` / `atst-item` / `atst-phonetic` / `atst-desc` / `atst-translatable`) needs synchronised updates to: parser, prompt assembly in `OpenAIProvider`, screenshot prompt in `ScreenshotVisionService`, and few-shot examples. Parser tolerates incomplete tags during streaming so users see token-by-token output.
- **Provider classification**: `TranslationProviderID.segmentKind` distinguishes `ai` vs `api`. Cache source, UI grouping, and cache key shape all key off this — don't bypass it.
- **Codesigning is ad-hoc** (`codesign --sign -` in `build-app.sh`). Each rebuild gets a fresh signature, so macOS TCC may reset Accessibility permission on upgrade. Users with the same bundle ID (`dev.local.atst`) keep their cache + settings across versions.
- **No hotkey via Carbon**: the global hotkey monitor is a CGEventTap (`GlobalHotKeyMonitor`), not Carbon's `RegisterEventHotKey`. The trade-off: needs Accessibility permission, but doesn't pollute the global hotkey table. The tap can't start without the grant, so `AppDelegate.promptForAccessibilityIfNeeded` shows the system prompt once per app version on launch.
- **Prewarm on modifier press**: the tap also sees `flagsChanged`; pressing a bound hotkey's modifier triggers `prewarmAllProviders` (throttled to once per 2 min). There is deliberately no periodic prewarm timer.
- **Launch at login** is `SMAppService.mainApp`, applied idempotently from the configuration sink; it only works from a bundled .app.

## Diagnostics

- App logs: `/tmp/atst.log` (rotated at ~1 MB to `/tmp/atst.old.log`)
- Last screenshot sent to AI vision: `/tmp/atst-last-screenshot.png`
- Cache: `~/Library/Caches/dev.local.atst/translations.json`
- Settings: `~/Library/Preferences/dev.local.atst.plist`
