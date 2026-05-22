import Foundation

/// AI vision call for screenshot translation (Vision OCR OFF path).
///
/// This is the one place we still send a multimodal image payload to an
/// OpenAI-compatible endpoint. Text translation goes through the
/// `TranslationProvider` abstraction (see `OpenAIProvider`, `GoogleProvider`,
/// `MicrosoftProvider`); screenshots stay separate because:
///   - the model needs vision capability (often a different model than the
///     text one — see `screenshotModel`);
///   - the message shape is multimodal (`image_url` content part), not
///     plain text;
///   - the conventional API providers (Google / Microsoft) can't accept
///     images, so multi-provider fan-out doesn't apply;
///   - screenshots aren't cached (each capture is unique).
///
/// Renamed from `TranslationService` in P8 because the old name suggested
/// it was the central translation entrypoint, which is no longer true.
struct ScreenshotVisionService {
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
        AppLogger.log("screenshot vision model=\(model) imageBytes=\(imageData.count)")

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
