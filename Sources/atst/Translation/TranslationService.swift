import Foundation

/// AI-only screenshot translation. Text translation moved to the new
/// `TranslationProvider` abstraction (see `OpenAIProvider`,
/// `GoogleProvider`, `MicrosoftProvider`). Screenshots stay in their own
/// path because they only ever go to a vision-capable AI model — there is
/// no API counterpart, no multi-provider fan-out, no cache.
struct TranslationService {
    var configuration: AppConfiguration

    func streamTranslateScreenshot(
        _ imageData: Data,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let model = configuration.screenshotModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw AppError.noScreenshotModelConfigured
        }

        let base64Image = imageData.base64EncodedString()
        let systemContent = screenshotSystemPrompt()
        let userPrompt = screenshotUserPrompt()
        AppLogger.log("screenshot translation model=\(model) imageBytes=\(imageData.count)")

        let client = OpenAICompatibleClient(configuration: configuration)
        return try await client.stream(
            model: model,
            messages: [
                .text(role: "system", content: systemContent),
                .parts(
                    role: "user",
                    parts: [
                        .text(userPrompt),
                        .imageURL("data:image/png;base64,\(base64Image)")
                    ]
                )
            ],
            onDelta: onDelta
        )
    }

    private func screenshotSystemPrompt() -> String {
        let base = configuration.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseSection = base.isEmpty ? AppConfiguration.defaultConfig.systemPrompt : base
        return """
        \(baseSection)

        目标语言：\(configuration.targetLanguage)

        本次任务是截图翻译。请识别截图里所有文字，把非目标语言的部分翻译成目标语言；目标语言部分保留原文。
        - 标识符 / 变量名 / 路径 / URL / 命令保留原文。
        - 截图里完全没有文字时返回空字符串。

        输出协议：
        <atst-result>
          <atst-item>{最终结果，混排翻译后的文字和保留的原文}</atst-item>
        </atst-result>

        其他内容（描述、寒暄、解释处理过程）一律不要输出，标签外不能有任何文字。
        """
    }

    private func screenshotUserPrompt() -> String {
        "请识别截图中的文字并按 <atst-result> 标签格式输出翻译。"
    }
}
