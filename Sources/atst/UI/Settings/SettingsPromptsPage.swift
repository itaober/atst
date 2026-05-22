import SwiftUI

/// Second page of the menu-bar settings panel — two large text editors
/// holding the system prompt and smart-explanation prompt that get fed to
/// the AI on every translation.
struct SettingsPromptsPage: View {
    @Binding var draft: AppConfiguration
    var save: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                editor(
                    title: L.pick("System Prompt", "系统提示词"),
                    subtitle: L.pick(
                        "Base rules for every translation. The model must wrap its answer in <atst-result> tags.",
                        "所有翻译请求的基础规则。模型必须用 <atst-result> 标签包裹译文。"
                    ),
                    text: $draft.systemPrompt,
                    defaultText: AppConfiguration.defaultConfig.systemPrompt
                )
                editor(
                    title: L.pick("Smart Explanation Prompt", "智能注释提示词"),
                    subtitle: L.pick(
                        "Extra rules used when smart explanation is on. Content goes into the <atst-desc> tag.",
                        "开启智能注释时附加的额外规则；模型把内容写进 <atst-desc> 标签。"
                    ),
                    text: $draft.smartExplanationPrompt,
                    defaultText: AppConfiguration.defaultConfig.smartExplanationPrompt
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(maxHeight: 500)
    }

    private func editor(
        title: String,
        subtitle: String,
        text: Binding<String>,
        defaultText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Button(L.pick("Restore default", "恢复默认")) {
                    text.wrappedValue = defaultText
                    save()
                }
                .controlSize(.mini)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 170)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .onChange(of: text.wrappedValue) { _ in
                    save()
                }
        }
    }
}
