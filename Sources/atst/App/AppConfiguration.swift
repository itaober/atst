import Foundation

enum AppearanceMode: String, Codable, CaseIterable, Equatable {
    case auto
    case light
    case dark
}

struct AppConfiguration: Codable, Equatable {
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
    var appearanceMode: AppearanceMode
    var cacheEnabled: Bool
    var cacheTTLDays: Int
    var cacheMaxEntries: Int
    var textHotKey: KeyboardShortcutConfig
    var screenshotHotKey: KeyboardShortcutConfig

    static let defaultConfig = AppConfiguration(
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
        screenshotHotKey: .defaultScreenshot
    )

    static let storageKey = "atst.configuration.v1"

    init(
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
        screenshotHotKey: KeyboardShortcutConfig = .defaultScreenshot
    ) {
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
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfiguration.defaultConfig

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
