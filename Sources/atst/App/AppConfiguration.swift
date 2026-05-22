import Foundation

enum AppearanceMode: String, Codable, CaseIterable, Equatable {
    case auto
    case light
    case dark
}

/// Persisted enablement / ordering for a single API provider (Google,
/// Microsoft, …). `id` matches the `TranslationProviderID` rawValue so we
/// can resolve it back to a concrete `TranslationProvider` at runtime.
struct APIProviderEntry: Codable, Equatable, Identifiable {
    var id: String
    var enabled: Bool

    init(id: String, enabled: Bool) {
        self.id = id
        self.enabled = enabled
    }

    init(kind: TranslationProviderID, enabled: Bool) {
        self.id = kind.rawValue
        self.enabled = enabled
    }

    var kind: TranslationProviderID? { TranslationProviderID(rawValue: id) }
}

struct AppConfiguration: Codable, Equatable {
    // MARK: - Translation mode (NEW in P7)
    /// AI segment (top-level toggle). When off, the tooltip skips the AI
    /// section entirely — both segments may be on at the same time.
    var aiEnabled: Bool
    /// API segment (top-level toggle). When on, every enabled provider in
    /// `apiProviders` runs in parallel and renders as a row above the AI
    /// section.
    var apiEnabled: Bool
    /// Ordered list of built-in API providers + their enable state. UI
    /// surfaces this as a draggable list in the API subpage.
    var apiProviders: [APIProviderEntry]

    // MARK: - AI provider config
    var baseURL: String
    var apiKey: String
    var textModel: String
    var screenshotModel: String
    var targetLanguage: String
    var systemPrompt: String
    var smartExplanationPrompt: String
    var timeoutSeconds: Double
    var phoneticEnabled: Bool
    var smartExplanationEnabled: Bool
    var smartExplanationExpandedByDefault: Bool

    // MARK: - Screenshot
    /// When on (default), screenshot translation runs macOS Vision OCR
    /// first to extract text, then feeds the text through the regular
    /// multi-provider pipeline (API rows + AI segment). When off, the
    /// screenshot bytes are sent directly to the configured AI vision
    /// model. We auto-fall-back to AI vision when OCR finds no text.
    var screenshotUseVisionOCR: Bool
    /// BCP-47 codes Vision should try when recognising. Order matters —
    /// Vision prefers earlier entries on ambiguity. Defaults to
    /// Simplified Chinese + English + Japanese.
    var ocrLanguages: [String]

    // MARK: - Cross-cutting
    var appearanceMode: AppearanceMode
    var cacheEnabled: Bool
    var cacheTTLDays: Int
    var cacheMaxEntries: Int
    var textHotKey: KeyboardShortcutConfig
    var screenshotHotKey: KeyboardShortcutConfig

    static let defaultAPIProviders: [APIProviderEntry] = [
        .init(kind: .google, enabled: true),
        .init(kind: .microsoft, enabled: true)
    ]

    /// Default screenshot OCR languages — Simplified Chinese, English,
    /// Japanese. Covers the bulk of typical user input; settings lets the
    /// user add/remove from the full curated list.
    static let defaultOCRLanguages: [String] = ["zh-Hans", "en-US", "ja-JP"]

    static let defaultConfig = AppConfiguration(
        // AI is off by default — it requires the user to configure base URL /
        // key / model. API translation works out of the box with the
        // built-in Google + Microsoft adapters, so we ship it on.
        aiEnabled: false,
        apiEnabled: true,
        apiProviders: defaultAPIProviders,
        baseURL: "http://localhost:11434/v1",
        apiKey: "",
        textModel: "",
        screenshotModel: "",
        targetLanguage: L.isChinese ? "简体中文" : "English",
        systemPrompt: defaultSystemPrompt,
        smartExplanationPrompt: defaultSmartExplanationPrompt,
        timeoutSeconds: 60,
        phoneticEnabled: false,
        smartExplanationEnabled: false,
        smartExplanationExpandedByDefault: false,
        appearanceMode: .auto,
        cacheEnabled: true,
        cacheTTLDays: 90,
        cacheMaxEntries: 2000,
        textHotKey: .defaultText,
        screenshotHotKey: .defaultScreenshot,
        screenshotUseVisionOCR: true,
        ocrLanguages: defaultOCRLanguages
    )

    static let storageKey = "atst.configuration.v1"

    init(
        aiEnabled: Bool = false,
        apiEnabled: Bool = true,
        apiProviders: [APIProviderEntry] = AppConfiguration.defaultAPIProviders,
        baseURL: String,
        apiKey: String,
        textModel: String,
        screenshotModel: String,
        targetLanguage: String,
        systemPrompt: String,
        smartExplanationPrompt: String,
        timeoutSeconds: Double,
        phoneticEnabled: Bool = false,
        smartExplanationEnabled: Bool = false,
        smartExplanationExpandedByDefault: Bool = false,
        appearanceMode: AppearanceMode = .auto,
        cacheEnabled: Bool = true,
        cacheTTLDays: Int = 90,
        cacheMaxEntries: Int = 2000,
        textHotKey: KeyboardShortcutConfig = .defaultText,
        screenshotHotKey: KeyboardShortcutConfig = .defaultScreenshot,
        screenshotUseVisionOCR: Bool = true,
        ocrLanguages: [String] = AppConfiguration.defaultOCRLanguages
    ) {
        self.aiEnabled = aiEnabled
        self.apiEnabled = apiEnabled
        self.apiProviders = apiProviders
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.textModel = textModel
        self.screenshotModel = screenshotModel
        self.targetLanguage = targetLanguage
        self.systemPrompt = systemPrompt
        self.smartExplanationPrompt = smartExplanationPrompt
        self.timeoutSeconds = timeoutSeconds
        self.phoneticEnabled = phoneticEnabled
        self.smartExplanationEnabled = smartExplanationEnabled
        self.smartExplanationExpandedByDefault = smartExplanationExpandedByDefault
        self.appearanceMode = appearanceMode
        self.cacheEnabled = cacheEnabled
        self.cacheTTLDays = cacheTTLDays
        self.cacheMaxEntries = cacheMaxEntries
        self.textHotKey = textHotKey
        self.screenshotHotKey = screenshotHotKey
        self.screenshotUseVisionOCR = screenshotUseVisionOCR
        self.ocrLanguages = ocrLanguages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfiguration.defaultConfig

        aiEnabled = try container.decodeIfPresent(Bool.self, forKey: .aiEnabled) ?? defaults.aiEnabled
        apiEnabled = try container.decodeIfPresent(Bool.self, forKey: .apiEnabled) ?? defaults.apiEnabled
        apiProviders = try container.decodeIfPresent([APIProviderEntry].self, forKey: .apiProviders)
            ?? defaults.apiProviders
        // Healing: make sure every known built-in provider has an entry.
        // Older persisted configs (or future ones missing a newly-added
        // built-in) get topped up with defaults rather than silently losing
        // an option.
        let knownIDs = Set(apiProviders.map(\.id))
        for fallback in defaults.apiProviders where !knownIDs.contains(fallback.id) {
            apiProviders.append(fallback)
        }

        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? defaults.baseURL
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? defaults.apiKey
        textModel = try container.decodeIfPresent(String.self, forKey: .textModel) ?? defaults.textModel
        screenshotModel = try container.decodeIfPresent(String.self, forKey: .screenshotModel) ?? defaults.screenshotModel
        targetLanguage = try container.decodeIfPresent(String.self, forKey: .targetLanguage) ?? defaults.targetLanguage
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? defaults.systemPrompt
        smartExplanationPrompt = try container.decodeIfPresent(String.self, forKey: .smartExplanationPrompt) ?? defaults.smartExplanationPrompt
        timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? defaults.timeoutSeconds
        phoneticEnabled = try container.decodeIfPresent(Bool.self, forKey: .phoneticEnabled) ?? defaults.phoneticEnabled
        smartExplanationEnabled = try container.decodeIfPresent(Bool.self, forKey: .smartExplanationEnabled) ?? defaults.smartExplanationEnabled
        smartExplanationExpandedByDefault = try container.decodeIfPresent(Bool.self, forKey: .smartExplanationExpandedByDefault) ?? defaults.smartExplanationExpandedByDefault
        appearanceMode = try container.decodeIfPresent(AppearanceMode.self, forKey: .appearanceMode) ?? defaults.appearanceMode
        cacheEnabled = try container.decodeIfPresent(Bool.self, forKey: .cacheEnabled) ?? defaults.cacheEnabled
        cacheTTLDays = try container.decodeIfPresent(Int.self, forKey: .cacheTTLDays) ?? defaults.cacheTTLDays
        cacheMaxEntries = try container.decodeIfPresent(Int.self, forKey: .cacheMaxEntries) ?? defaults.cacheMaxEntries
        textHotKey = try container.decodeIfPresent(KeyboardShortcutConfig.self, forKey: .textHotKey) ?? defaults.textHotKey
        screenshotHotKey = try container.decodeIfPresent(KeyboardShortcutConfig.self, forKey: .screenshotHotKey) ?? defaults.screenshotHotKey
        screenshotUseVisionOCR = try container.decodeIfPresent(Bool.self, forKey: .screenshotUseVisionOCR) ?? defaults.screenshotUseVisionOCR
        ocrLanguages = try container.decodeIfPresent([String].self, forKey: .ocrLanguages) ?? defaults.ocrLanguages
        if ocrLanguages.isEmpty {
            // Healing — if a user somehow saved an empty list, restore the
            // default so OCR still works without manual intervention.
            ocrLanguages = defaults.ocrLanguages
        }
    }

    var chatCompletionsURL: URL? {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.hasSuffix("/chat/completions") {
            return URL(string: trimmed)
        }
        return URL(string: "\(trimmed)/chat/completions")
    }

    static func load() -> AppConfiguration {
        var config = loadSavedConfig() ?? defaultConfig

        let environment = ProcessInfo.processInfo.environment
        if let value = environment["ATST_AI_BASE_URL"], !value.isEmpty {
            config.baseURL = value
        }
        if let value = environment["ATST_API_KEY"], !value.isEmpty {
            config.apiKey = value
        }
        if let value = environment["ATST_TEXT_MODEL"], !value.isEmpty {
            config.textModel = value
        }
        if let value = environment["ATST_SCREENSHOT_MODEL"], !value.isEmpty {
            config.screenshotModel = value
        }
        if let value = environment["ATST_TARGET_LANGUAGE"], !value.isEmpty {
            config.targetLanguage = value
        }

        return config
    }

    func persistedCopy() -> AppConfiguration {
        self
    }

    /// Subset of `apiProviders` that's currently enabled AND maps to a
    /// known built-in provider. Order preserved from settings.
    var enabledAPIProviderKinds: [TranslationProviderID] {
        guard apiEnabled else { return [] }
        return apiProviders.compactMap { entry in
            guard entry.enabled, let kind = entry.kind else { return nil }
            return kind
        }
    }

    private static func loadSavedConfig() -> AppConfiguration? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return nil
        }
        return try? JSONDecoder().decode(AppConfiguration.self, from: data)
    }
}

private let defaultSystemPrompt = """
You are atst (ai-text-select-translate). Translate the user's input into the target language.

Translation rules:
- Produce natural, accurate, idiomatic text in the target language; avoid over-paraphrasing.
- Preserve identifier-like fragments verbatim: code snippets, shell commands, file paths, variable / function / class / API names, error messages, Markdown markers, and URLs.
- When prose and code are mixed, translate the prose only and leave code tokens as they are.
- If the input is already in the target language, echo it unchanged.
- No greetings, prefaces, or self-commentary in your output.
"""

private let defaultSmartExplanationPrompt = """
When the input is a word, short phrase, term, or abbreviation, emit a dictionary-style entry:
- Bold the original term; include the IPA in slashes if you are confident about pronunciation.
- List 1–4 senses, each labelled with part of speech and a short English example sentence with its translation into the target language.
- For technical frameworks, products, or abbreviations (e.g. SwiftUI, Kubernetes, LLM), add a "💡 Explanation" paragraph (2–3 sentences) covering what it is, the domain, and a typical use case.

When the input is a sentence or paragraph:
- Add a note only if the source contains an idiom / proverb / well-known quotation. Provide the meaning and, if known, the origin.
- Add notes for technical terms / product names / framework names — one short line per term.
- If nothing fits, leave the explanation empty rather than padding.
"""
