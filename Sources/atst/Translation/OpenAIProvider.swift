import Foundation

/// `TranslationProvider` implementation that talks to an OpenAI-compatible
/// Chat Completions endpoint with SSE streaming. Owns the prompt assembly,
/// XML protocol formatting, and per-emission parsing — everything the model
/// produces is parsed into `TranslationOutput` on every delta so the UI can
/// render partial multi-meaning / phonetic / description sections token by
/// token.
struct OpenAIProvider: TranslationProvider {
    let id: TranslationProviderID = .ai
    let configuration: AppConfiguration

    var displayName: String {
        let trimmed = configuration.textModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "AI" : trimmed
    }

    var modelHint: String? {
        let trimmed = configuration.textModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var targetLanguage: String { configuration.targetLanguage }

    func translate(text: String) -> AsyncThrowingStream<TranslationProviderEmission, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let model = configuration.textModel.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !model.isEmpty else {
                    continuation.finish(throwing: AppError.noTextModelConfigured)
                    return
                }

                let request = buildPromptRequest(for: text)
                AppLogger.log("openai prompt phonetic=\(request.includePhonetic) explanation=\(request.includeDescription) text='\(text.prefix(60))'")

                let client = OpenAICompatibleClient(configuration: configuration)
                var accumulated = ""
                do {
                    let final = try await client.stream(
                        model: model,
                        messages: [
                            .text(role: "system", content: request.systemContent),
                            .text(role: "user", content: request.userContent)
                        ],
                        onDelta: { delta in
                            accumulated += delta
                            let parsed = TranslationOutputParser.parse(accumulated)
                            continuation.yield(TranslationProviderEmission(
                                output: parsed,
                                raw: accumulated,
                                isFinal: false
                            ))
                        }
                    )
                    // The client returns the trimmed cumulative text. Run a
                    // final parse so the terminal output reflects any
                    // closing tags that arrived in the same SSE frame as
                    // [DONE].
                    let parsed = TranslationOutputParser.parse(final)
                    continuation.yield(TranslationProviderEmission(
                        output: parsed,
                        raw: final,
                        isFinal: true
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Prompt assembly (moved from TranslationService text path)

    private struct PromptRequest {
        var systemContent: String
        var userContent: String
        var includePhonetic: Bool
        var includeDescription: Bool
    }

    private func buildPromptRequest(for text: String) -> PromptRequest {
        let isLookup = OpenAIProvider.looksLikeLookupTerm(text)
        let includePhonetic = configuration.phoneticEnabled && isLookup
        let includeDescription = configuration.smartExplanationEnabled
            && (isLookup || OpenAIProvider.canEnrich(text))
        let systemContent = assembleSystemPrompt(
            includePhonetic: includePhonetic,
            includeDescription: includeDescription
        )
        let userContent = """
        请翻译下面的内容，并按系统约定的标签格式输出：

        <atst-source>
        \(text)
        </atst-source>
        """
        return PromptRequest(
            systemContent: systemContent,
            userContent: userContent,
            includePhonetic: includePhonetic,
            includeDescription: includeDescription
        )
    }

    private func assembleSystemPrompt(
        includePhonetic: Bool,
        includeDescription: Bool
    ) -> String {
        let base = configuration.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseSection = base.isEmpty ? AppConfiguration.defaultConfig.systemPrompt : base

        var sections: [String] = []
        sections.append(baseSection)
        sections.append("目标语言：\(configuration.targetLanguage)")

        var tagBlock = """
        <atst-result>
          <atst-item>{义项 1 / 句子译文}</atst-item>
          <atst-item>{义项 2，可选}</atst-item>
        </atst-result>
        """
        if includePhonetic {
            tagBlock += "\n<atst-phonetic>{IPA 音标，无把握就留空标签内部}</atst-phonetic>"
        }
        if includeDescription {
            tagBlock += "\n<atst-desc>{补充说明，遵循『智能注释规则』；没有可补充就留空标签内部}</atst-desc>"
        }

        sections.append("""
        输出协议（严格遵守，否则解析失败）：
        - 整段输出必须只包含下列 XML 风格标签，标签外不能有任何文字、解释、寒暄、代码块。
        - 标签 **必须** 闭合，内部不要嵌套其它 atst-* 标签。

        \(tagBlock)

        多义项规则：
        - 输入是英文中有**明确多义**的单词 / 短语时（例如 china = 中国 / 瓷器；present = 礼物 / 现在 / 呈现；bank = 银行 / 河岸；spring = 春天 / 弹簧 / 泉水），输出 2~4 个 `<atst-item>`，按使用频率从高到低排序。
        - 同一含义的同义表达不要拆成多个 item（例如 "短暂的；瞬息的；转瞬即逝的" 是一个 item，不是三个）。
        - 输入是句子 / 段落 / 单义词时，只输出 **1 个** `<atst-item>`。
        - `<atst-item>` 内放纯译文本，没有前后缀；用户复制的就是这一段。

        可翻译标记（`<atst-translatable>`，可选）：
        - 默认所有翻译都是"可翻译"的，**省略**这个标签即可。
        - 仅以下三种情况输出 `<atst-translatable>false</atst-translatable>`：
          (a) 没有标准翻译的**专有名词 / 品牌名 / 产品名 / 代码标识符 / 缩略词**（例如 SwiftUI、Kubernetes、iPhone、Redis）。
          (b) 输入**本身就是目标语言**，无需翻译。
          (c) 输入是**拼写错误 / 无意义字符串 / 不能识别的非标准词**（例如 `Taober`、`asdfgh`、`xxxooo`）。
        - 这种情况下 `<atst-item>` 仍然写原文本身（让用户看到结果），但客户端会跳过缓存。
        - **当 `<atst-translatable>false</atst-translatable>` 且 `<atst-desc>` 已启用时，必须在 `<atst-desc>` 中以 1–3 句简短说明原因**：
          - 专有名词 → 介绍这是什么、属于哪个领域。
          - 已是目标语言 → 直接说"输入已是目标语言（XX），无需翻译"。
          - 拼写错误 / 无意义 → 说明"未识别"，并尽量给出最接近的正确写法或最可能的猜测（如果有）。
        - 普通词、句子、习语都**有翻译**，不要打 false。
        - 值只接受 `false`（小写）。不要写 `0` / `True` / 其它形式。

        其它细节：
        - 译文保留代码片段、命令、路径、变量名、URL、错误信息等"标识符级"内容原文。
        - 输入本身就是目标语言时，原样回写到单个 `<atst-item>` 并附 `<atst-translatable>false</atst-translatable>`。
        """)

        if includePhonetic {
            sections.append("""
            <atst-phonetic> 规则：
            - 仅当输入是英文单词 / 短语 / 缩略词，且你确信音标时填写。
            - 使用国际音标 IPA，外面包一对斜杠，例如 `/ɪˈfemərəl/`。
            - 不确定 / 不适用（中文 / 句子 / 专有名词无标准发音）时，标签内部留空。
            """)
        }

        if includeDescription {
            let userExplanation = configuration.smartExplanationPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let explanation = userExplanation.isEmpty
                ? AppConfiguration.defaultConfig.smartExplanationPrompt
                : userExplanation
            sections.append("""
            <atst-desc> 内的"智能注释"规则：
            \(explanation)

            <atst-desc> 内部可用 Markdown（粗体、`-` 列表、段落），但不要再包 ``` 代码块。
            """)
        }

        sections.append("""
        示例 1（句子，单义项）：
        输入："Hello, world."
        输出：
        <atst-result>
          <atst-item>你好，世界。</atst-item>
        </atst-result>
        """)

        if includePhonetic || includeDescription {
            sections.append(buildExampleSection(
                includePhonetic: includePhonetic,
                includeDescription: includeDescription
            ))
        }

        return sections.joined(separator: "\n\n")
    }

    private func buildExampleSection(
        includePhonetic: Bool,
        includeDescription: Bool
    ) -> String {
        var examples: [String] = []

        if includePhonetic && includeDescription {
            examples.append("""
            示例 2（普通词 + 音标 + 解释，单义项）：
            输入："ephemeral"
            输出：
            <atst-result>
              <atst-item>短暂的；瞬息的</atst-item>
            </atst-result>
            <atst-phonetic>/ɪˈfemərəl/</atst-phonetic>
            <atst-desc>**ephemeral** /ɪˈfemərəl/

            - **adj.**：持续时间很短的；转瞬即逝的
              - Beauty is ephemeral. — 美是短暂的。
            - **adj.**（生物）：寿命很短的
              - ephemeral insects — 朝生暮死的昆虫</atst-desc>
            """)
            examples.append("""
            示例 3（多义词）：
            输入："china"
            输出：
            <atst-result>
              <atst-item>中国</atst-item>
              <atst-item>瓷器</atst-item>
            </atst-result>
            <atst-phonetic>/ˈtʃaɪnə/</atst-phonetic>
            <atst-desc>**china** /ˈtʃaɪnə/

            - **n.**：中国（大写时常作 China，泛指国家）
              - I'm going to China next month. — 我下个月去中国。
            - **n.**：瓷器；瓷土
              - a set of fine china — 一套精美的瓷器</atst-desc>
            """)
            examples.append("""
            示例 4（专有名词，无翻译）：
            输入："SwiftUI"
            输出：
            <atst-result>
              <atst-item>SwiftUI</atst-item>
            </atst-result>
            <atst-phonetic></atst-phonetic>
            <atst-desc>**💡 解释**

            SwiftUI 是 Apple 于 2019 年 WWDC 推出的声明式 UI 框架，使用 Swift 语言以数据驱动的描述式语法构建用户界面。它统一了 iOS、macOS、watchOS、tvOS、visionOS 五个平台的开发方式。</atst-desc>
            <atst-translatable>false</atst-translatable>
            """)
            examples.append("""
            示例 5（拼写错误 / 未识别）：
            输入："Taober"
            输出：
            <atst-result>
              <atst-item>Taober</atst-item>
            </atst-result>
            <atst-phonetic></atst-phonetic>
            <atst-desc>**未识别**

            该字符串不是一个标准英文词，也不像常见的专有名词。可能是 **Taobao（淘宝）** 的拼写错误？请确认拼写。</atst-desc>
            <atst-translatable>false</atst-translatable>
            """)
        } else if includePhonetic {
            examples.append("""
            示例 2（仅音标，单义项）：
            输入："ephemeral"
            输出：
            <atst-result>
              <atst-item>短暂的；瞬息的</atst-item>
            </atst-result>
            <atst-phonetic>/ɪˈfemərəl/</atst-phonetic>
            """)
            examples.append("""
            示例 3（仅音标，多义词）：
            输入："china"
            输出：
            <atst-result>
              <atst-item>中国</atst-item>
              <atst-item>瓷器</atst-item>
            </atst-result>
            <atst-phonetic>/ˈtʃaɪnə/</atst-phonetic>
            """)
        } else if includeDescription {
            examples.append("""
            示例 2（句子 + 习语注释）：
            输入："Rome wasn't built in a day."
            输出：
            <atst-result>
              <atst-item>罗马不是一天建成的。</atst-item>
            </atst-result>
            <atst-desc>**📖 含义**：成就大事需要时间和坚持，不能急于求成。出处：英文谚语。</atst-desc>
            """)
            examples.append("""
            示例 3（多义词 + 解释）：
            输入："bank"
            输出：
            <atst-result>
              <atst-item>银行</atst-item>
              <atst-item>河岸</atst-item>
            </atst-result>
            <atst-desc>**bank**

            - **n.**：金融机构，银行
              - I work at a bank. — 我在银行工作。
            - **n.**：河岸；堤岸
              - We sat on the bank of the river. — 我们坐在河岸上。</atst-desc>
            """)
            examples.append("""
            示例 4（拼写错误 / 未识别）：
            输入："Taober"
            输出：
            <atst-result>
              <atst-item>Taober</atst-item>
            </atst-result>
            <atst-desc>**未识别**：不是标准英文词，也不像常见专有名词。可能是 **Taobao（淘宝）** 的拼写错误。</atst-desc>
            <atst-translatable>false</atst-translatable>
            """)
        }

        return examples.joined(separator: "\n\n")
    }

    // MARK: - Lookup heuristics
    //
    // Used by OpenAIProvider itself and by TranslatorViewModel's decisions
    // (e.g. cache filtering). Kept here so OpenAI-specific knowledge stays in
    // one place — non-AI providers don't need these heuristics.

    static func looksLikeLookupTerm(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 40 else { return false }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard (1...3).contains(words.count) else { return false }
        let allowed = CharacterSet.letters.union(CharacterSet(charactersIn: "-'"))
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) || $0 == " " }
    }

    static func canEnrich(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 800
    }
}
