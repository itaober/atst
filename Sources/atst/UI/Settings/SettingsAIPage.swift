import SwiftUI

/// "AI translation" subpage. All AI-only configuration lives here: provider
/// endpoint, key, models, phonetic / smart-explanation toggles, prompt
/// editors (one level deeper).
struct SettingsAIPage: View {
    @Binding var draft: AppConfiguration
    var save: () -> Void
    var debouncedSave: () -> Void
    var openPromptsPage: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statusSection
                modelSection
                promptsSection
                phoneticSection
                smartExplanationSection
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(maxHeight: 500)
    }

    private var statusSection: some View {
        SettingsSection(title: L.pick("Status", "状态")) {
            SettingsToggleRow(
                title: L.pick("Enable AI translation", "启用 AI 翻译"),
                subtitle: L.pick(
                    "Sends the selection to your OpenAI-compatible endpoint.",
                    "把选区文本发送到你配置的 OpenAI 兼容接口。"
                ),
                isOn: $draft.aiEnabled,
                onChange: save
            )
        }
    }

    private var modelSection: some View {
        SettingsSection(title: L.pick("Endpoint", "接口")) {
            SettingsTextRow(
                title: "Base URL",
                text: $draft.baseURL,
                placeholder: "http://localhost:11434/v1",
                onChange: debouncedSave
            )
            SettingsSecureRow(
                title: L.pick("API Key (stored locally)", "API Key（本地保存）"),
                text: $draft.apiKey,
                placeholder: L.pick("Optional", "可留空"),
                onChange: debouncedSave
            )
            SettingsTextRow(
                title: L.pick("Translation Model", "翻译模型"),
                text: $draft.textModel,
                placeholder: "text model",
                onChange: debouncedSave
            )
            SettingsTextRow(
                title: L.pick("Screenshot Model", "截图模型"),
                text: $draft.screenshotModel,
                placeholder: "vision model",
                onChange: debouncedSave
            )
        }
    }

    private var promptsSection: some View {
        SettingsSection(title: L.pick("Prompts", "提示词")) {
            SettingsNavRow(
                title: L.pick("Translation Prompts", "翻译提示词"),
                subtitle: L.pick(
                    "System prompt and smart-explanation prompt",
                    "系统提示词与智能注释提示词"
                ),
                action: openPromptsPage
            )
        }
    }

    private var phoneticSection: some View {
        SettingsSection(title: L.pick("Phonetic", "音标")) {
            SettingsToggleRow(
                title: L.pick("Enable phonetic", "启用音标"),
                subtitle: L.pick(
                    "Append IPA to word translations; tap to play",
                    "单词翻译追加 IPA，点击朗读原文"
                ),
                isOn: $draft.phoneticEnabled,
                onChange: save
            )
        }
    }

    private var smartExplanationSection: some View {
        SettingsSection(title: L.pick("Smart Explanation", "智能注释")) {
            SettingsToggleRow(
                title: L.pick("Enable smart explanation", "启用智能注释"),
                subtitle: L.pick(
                    "Dictionary entry for words; idiom / term notes for sentences",
                    "单词给词典释义；句子识别习语 / 术语"
                ),
                isOn: $draft.smartExplanationEnabled,
                onChange: save
            )
            Divider().padding(.horizontal, 10)
            SettingsToggleRow(
                title: L.pick("Expand by default", "释义默认展开"),
                subtitle: L.pick(
                    "Open the explanation when the tooltip first appears",
                    "弹层出现时直接展开智能注释"
                ),
                isOn: $draft.smartExplanationExpandedByDefault,
                onChange: save
            )
            .opacity(draft.smartExplanationEnabled ? 1 : 0.4)
            .disabled(!draft.smartExplanationEnabled)
        }
    }
}
