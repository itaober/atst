import Foundation

enum AppError: LocalizedError {
    case accessibilityPermissionRequired
    case noSelectedText
    case invalidAIBaseURL(String)
    case noTextModelConfigured
    case noScreenshotModelConfigured
    case aiRequestFailed(String)
    case aiUnavailable(String)
    case emptyTranslation
    case noScreenshotText
    case visionModelLikelyUnsupported(String)
    case screenRecordingPermissionRequired
    case screenshotCancelled
    case screenshotFailed(String)
    /// User has Vision OCR disabled AND AI translation disabled, so there's
    /// no path to translate a screenshot. Surfaced when the user fires the
    /// screenshot hotkey in this configuration; the recovery suggestion
    /// tells them which switch to flip.
    case aiDisabledForVision

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            return L.pick("Accessibility permission required", "需要辅助功能权限")
        case .noSelectedText:
            return L.pick("No selected text", "没有取到选中的文本")
        case .invalidAIBaseURL(let url):
            return L.pick("Invalid AI Base URL: \(url)", "AI Base URL 无效：\(url)")
        case .noTextModelConfigured:
            return L.pick("Translation model not configured", "还没有配置划词翻译模型")
        case .noScreenshotModelConfigured:
            return L.pick("Screenshot model not configured", "还没有配置截图翻译模型")
        case .aiUnavailable:
            return L.pick("Can't reach AI service", "AI 服务无法连接")
        case .aiRequestFailed:
            return L.pick("AI request failed", "AI 请求失败")
        case .emptyTranslation:
            return L.pick("Model returned no translation", "模型没有返回翻译结果")
        case .noScreenshotText:
            return L.pick("No readable text found in screenshot", "截图里没有识别到文字")
        case .visionModelLikelyUnsupported:
            return L.pick(
                "Screenshot model likely doesn't support vision",
                "截图模型可能不支持图像识别"
            )
        case .screenRecordingPermissionRequired:
            return L.pick("Screen recording permission required", "需要屏幕录制权限")
        case .screenshotCancelled:
            return L.pick("Screenshot cancelled", "已取消截图")
        case .screenshotFailed:
            return L.pick("Screenshot failed", "截图失败")
        case .aiDisabledForVision:
            return L.pick(
                "Can't translate screenshot — both AI and Vision OCR are off",
                "无法翻译截图——AI 翻译和 Vision OCR 都已关闭"
            )
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .accessibilityPermissionRequired:
            return L.pick(
                "Allow atst under System Settings → Privacy & Security → Accessibility, then try again.",
                "请在系统设置 → 隐私与安全性 → 辅助功能中允许 atst，然后再试一次。"
            )
        case .noSelectedText:
            return L.pick(
                "Select some copyable text first, then press the hotkey.",
                "请先在当前应用里选中一段可复制的文本，再按快捷键。"
            )
        case .invalidAIBaseURL:
            return L.pick(
                "Check the Base URL in Settings. atst uses OpenAI-compatible Chat Completions.",
                "请在设置中检查 Base URL。当前版本使用 OpenAI-compatible Chat Completions。"
            )
        case .noTextModelConfigured:
            return L.pick(
                "Open Settings and fill in the Translation Model field.",
                "请打开设置，填写『翻译模型』。"
            )
        case .noScreenshotModelConfigured:
            return L.pick(
                "Open Settings and fill in a vision-capable model under Screenshot Model.",
                "请打开设置，填写支持图片输入的『截图模型』。"
            )
        case .aiUnavailable(let detail):
            return L.pick(
                "Make sure the Base URL is reachable; check the API key if needed. Detail: \(detail)",
                "请确认 Base URL 可访问，必要时检查 API Key。详情：\(detail)"
            )
        case .aiRequestFailed(let detail):
            return detail
        case .emptyTranslation:
            return L.pick(
                "Try a different model, or shorten the input and retry.",
                "可以换一个模型，或缩短要翻译的文本后重试。"
            )
        case .noScreenshotText:
            return L.pick(
                "Vision OCR didn't find text and AI vision isn't available. Open /tmp/atst-last-screenshot.png to inspect the capture, add languages in Settings → Screenshot, or enable AI with a vision model.",
                "Vision OCR 未识别到文字，且 AI 视觉不可用。可打开 /tmp/atst-last-screenshot.png 查看截图，到 设置 → 截图 增加识别语言，或启用 AI 翻译并配置支持图像的模型。"
            )
        case .visionModelLikelyUnsupported(let model):
            return L.pick(
                "\(model) returned nothing — it likely doesn't accept image input. Pick a vision model (e.g. gpt-4o, claude-3.5-sonnet, qwen-vl) under Settings → Screenshot Model.",
                "\(model) 没返回任何内容，多半不支持图像输入。请在设置里把『截图模型』换成支持视觉的模型（例如 gpt-4o、claude-3.5-sonnet、qwen-vl）。"
            )
        case .screenRecordingPermissionRequired:
            return L.pick(
                "Allow atst under System Settings → Privacy & Security → Screen Recording, then try screenshot translation again.",
                "请在系统设置 → 隐私与安全性 → 屏幕录制中允许 atst，然后重新尝试截图翻译。"
            )
        case .screenshotCancelled:
            return nil
        case .screenshotFailed(let detail):
            return detail
        case .aiDisabledForVision:
            return L.pick(
                "Enable Vision OCR in Settings → Screenshot (uses Google / Microsoft), or enable AI translation with a vision-capable screenshot model.",
                "请在 设置 → 截图 中启用 Vision OCR（走 Google / Microsoft），或启用 AI 翻译并配置支持图像的截图模型。"
            )
        }
    }
}
