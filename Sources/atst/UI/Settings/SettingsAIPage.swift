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
            timeoutRow
        }
    }

    /// Only the AI request honours this; Google / Microsoft use a fixed
    /// 15 s, which is why the row lives here and not in General.
    private var timeoutRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(L.pick("Timeout", "超时"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Text(L.pick("Idle limit per AI request", "单次 AI 请求的空闲等待上限"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            TextField("10", value: $draft.timeoutSeconds, format: .number)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .multilineTextAlignment(.trailing)
                .frame(width: 60)
                .onChange(of: draft.timeoutSeconds) { _ in debouncedSave() }
            Text(L.pick("s", "秒"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
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
