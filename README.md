<div align="center">

<img src="Resources/AppIcon.iconset/icon_128x128.png" alt="atst" width="128" height="128" />

# atst

**a(i)-text-select-translate** — a tiny menu-bar translator for macOS

`a` (AI) · `t` (text) · `s` (select) · `t` (translate)

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)](#requirements)
[![Latest release](https://img.shields.io/github/v/release/itaober/atst?label=version&color=blue)](https://github.com/itaober/atst/releases/latest)
[![License](https://img.shields.io/badge/license-Apache--2.0-orange)](./LICENSE)

Hit a hotkey, get a translation. Works **out of the box** with built-in Google + Microsoft adapters, and unlocks AI-grade dictionary / explanation when you bring your own model.

[简体中文](./README.zh-CN.md) · [Install](#install) · [Usage](#usage) · [Features](#features)

</div>

---

## Highlights

- ⚡ **One-hotkey translation** — press `⌥D` on any selected text, anywhere in macOS, and a tooltip appears in ~200ms
- 🖼️ **Screenshot translation** — press `⌥S`, drag a region, get the translation. On-device Vision OCR by default (fast + private + free); falls back to AI vision if you've configured one
- 🔀 **Multi-source side-by-side** — Google and Microsoft results stack above your AI result, so you can cross-check at a glance
- 🧠 **AI dictionary mode** — for single words, AI providers can return multiple meanings, IPA phonetics, and a short usage explanation
- 📌 **Pin as note** — freeze a translation into a floating sticky note for later reference
- 💾 **Local cache** — repeat lookups hit a JSON cache, scoped per provider; configurable TTL and size cap
- 🫧 **Native Liquid Glass** — translation tooltips and pinned notes use Liquid Glass on macOS 26+ when available, with an automatic fallback on older systems
- 🪶 **Tiny footprint** — ~2 MB DMG, ~4 MB installed. Pure Swift/AppKit, no Electron, no Web view
- 🌐 **Bilingual UI** — auto English / Chinese based on system language, with a manual override
- 🆓 **Zero-config friendly** — works on a fresh install with no API keys (Google + Microsoft adapters); add an OpenAI-compatible endpoint when you want richer output

---

## Install

### Download the latest release

1. Grab the latest `atst.dmg` from the [Releases page](https://github.com/itaober/atst/releases)
2. Open the DMG and drag **atst** into your `Applications` folder
3. Launch atst — a small **`atst`** label appears in your menu bar (top-right of the screen)
4. macOS will prompt for **Accessibility** permission the first time you press a hotkey — grant it in System Settings → Privacy & Security → Accessibility

> **Heads up**: because atst is a self-signed app (no Apple Developer ID yet), the first launch may show "atst can't be opened because it is from an unidentified developer". Right-click the app → **Open** → **Open anyway**, or run `xattr -d com.apple.quarantine /Applications/atst.app` once.

### Build from source

Requires **macOS 13+** and **Swift 5.9+** (Xcode 15 / Command Line Tools).

```bash
git clone https://github.com/itaober/atst.git
cd atst

# Quick dev build
swift run atst

# Build a packaged .app bundle (with icon + Info.plist + codesign)
bash Scripts/build-app.sh
open .build/atst.app

# Build a DMG installer
bash Scripts/build-dmg.sh
open .build/atst.dmg
```

---

## Usage

### Hotkeys

| Hotkey | Action |
|---|---|
| `⌥D` | Translate the currently selected text |
| `⌥S` | Screenshot a region and translate the text it contains |

Both hotkeys are reconfigurable in **Settings → Hotkeys**.

### The translation tooltip

When a translation appears, you'll see one or two sections:

- **Top — API results** (Google, Microsoft): fast and free, no API key required
- **Bottom — AI result** (if enabled): richer output with multiple meanings, IPA phonetics, and explanations for technical terms

Each row has its own copy button. The whole tooltip is **draggable from its header** if you want to move it out of the way; click outside to dismiss. Click the pin (📌) in the header to freeze it into a sticky note.

### Translator settings

Click the **`atst`** label in your menu bar to open the settings panel.

The General page has two toggles:

- ☑️ **API Translation** (on by default) — Google + Microsoft. Zero config.
- ☐ **AI Translation** (off by default) — OpenAI-compatible endpoint. Configure base URL + key + model in the AI subpage.

#### AI configuration (optional)

Inside **AI Translation** subpage:

- **Base URL** — any OpenAI-compatible endpoint, e.g. `https://api.openai.com/v1`, `http://localhost:11434/v1` (Ollama), `https://generativelanguage.googleapis.com/v1beta/openai/` (Gemini OpenAI-compat)
- **API Key** — kept locally in `~/Library/Preferences/dev.local.atst.plist`
- **Translation Model** — model name to use for selection translation (e.g. `gpt-4o-mini`, `qwen2.5:7b`)
- **Screenshot Model** — vision-capable model used when **Vision OCR** is OFF (e.g. `gpt-4o`, `claude-3.5-sonnet`)
- **Phonetic** — append IPA to single-word lookups
- **Smart Explanation** — add a dictionary-style explanation block (idioms, proper-noun definitions, etc.)
- **Translation Prompts** — fully editable system + smart-explanation prompts

#### Screenshot OCR settings

The **Screenshot** section in the General page controls how `⌥S` works:

- ☑️ **Use Vision OCR** (on by default) — recognise text on-device with macOS Vision (no AI needed!), then translate via the selected providers
- ☐ **Use Vision OCR** OFF — send the screenshot directly to your AI vision model

Add or remove recognition languages from the chip row below. Default: Simplified Chinese + English + Japanese.

---

## Features

### Translation providers

| Provider | Key required | Free | Streaming | Multi-meaning | Phonetic | Explanation |
|---|---|---|---|---|---|---|
| Google (built-in) | ❌ | ✅ | — | ❌ | ❌ | ❌ |
| Microsoft (built-in) | ❌ | ✅ | — | ❌ | ❌ | ❌ |
| OpenAI-compatible | ✅ | depends | ✅ | ✅ | ✅ | ✅ |

### Other goodies

- **Smart tooltip placement** — Web-style flip algorithm; tooltip never gets pushed off-screen or covers your selection
- **Adaptive glass surface** — native Liquid Glass on macOS 26+ with Swift 6.2+ builds; older macOS versions keep the AppKit `NSVisualEffectView` tooltip material
- **Cache stats** — see how many entries are cached and how much disk they're using, with a one-click clear button
- **Untranslatable detection** — proper nouns / brands / misspellings get a 🔘 marker and skip the cache
- **Theme** — Auto / Light / Dark, applied app-wide

---

## Requirements

- macOS **13.0** (Ventura) or later
- A handful of MB of disk for the local cache
- For AI features: any OpenAI-compatible endpoint (paid or local-LLM)

---

## Privacy

- atst is a **local app**. No telemetry, no analytics, no crash reporters.
- API providers (Google, Microsoft, your AI endpoint) receive only the text you trigger a translation for.
- Cache lives at `~/Library/Caches/dev.local.atst/translations.json`. Settings live at `~/Library/Preferences/dev.local.atst.plist`. Delete either at any time.

---

## Roadmap

Things on the radar (open an issue if you'd like to vote one up):

- [ ] Custom HTTP translation providers (template-driven; bring your own DeepL / Lingva / Libretranslate)
- [ ] Drag-to-reorder API providers
- [ ] Translation history with full-text search
- [ ] Streaming token-by-token rendering for AI providers that support it
- [ ] Apple Notarization + proper code signing (no more right-click → Open)

---

## License

Apache 2.0 — see [LICENSE](./LICENSE) for details.

## Acknowledgments

- macOS [Vision framework](https://developer.apple.com/documentation/vision) for the OCR engine
- The OpenAI Chat Completions protocol — adopted by virtually every modern LLM endpoint
- Built with [Claude Code](https://claude.com/claude-code) in collaboration with the author
