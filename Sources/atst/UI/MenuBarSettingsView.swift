import SwiftUI

private enum SettingsRoute: Hashable {
    case translationPrompts
}

private enum ShortcutTarget: Equatable {
    case text
    case screenshot
}

struct MenuBarSettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var cache: TranslationCache = .shared
    var onTranslateSelection: () -> Void
    var onTranslateScreenshot: () -> Void
    var onQuit: () -> Void

    @State private var draft: AppConfiguration
    @State private var saveError: String?
    @State private var accessibilityTrusted = PermissionChecker.isAccessibilityTrusted
    @State private var screenRecordingTrusted = PermissionChecker.isScreenRecordingTrusted
    @State private var recordingTarget: ShortcutTarget?
    @State private var shortcutMonitor: Any?
    @State private var permissionPollTask: Task<Void, Never>?
    @State private var saveDebounceTask: Task<Void, Never>?
    @State private var route: SettingsRoute? = nil

    private let panelWidth: CGFloat = 340

    init(
        settingsStore: SettingsStore,
        onTranslateSelection: @escaping () -> Void,
        onTranslateScreenshot: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.settingsStore = settingsStore
        self.onTranslateSelection = onTranslateSelection
        self.onTranslateScreenshot = onTranslateScreenshot
        self.onQuit = onQuit
        _draft = State(initialValue: settingsStore.configuration)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if route == .translationPrompts {
                    SettingsPromptsPage(draft: $draft, save: save)
                } else {
                    rootPage
                }
            }
            Divider()
            footer
        }
        .frame(width: panelWidth)
        .background(.regularMaterial)
        .onReceive(settingsStore.$configuration) { configuration in
            draft = configuration
        }
        .onAppear {
            refreshPermissionStatus()
            startPermissionPolling()
        }
        .onDisappear {
            stopRecordingShortcut()
            permissionPollTask?.cancel()
            permissionPollTask = nil
        }
    }

    // MARK: - Header / Footer

    private var header: some View {
        HStack(spacing: 10) {
            if route != nil {
                Button {
                    route = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(L.pick("Back", "返回"))
            }

            Text(headerTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            if route == nil {
                Button(action: onQuit) {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(L.pick("Quit \(Branding.appName)", "退出 \(Branding.appName)"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var headerTitle: String {
        switch route {
        case .none: return Branding.appName
        case .translationPrompts: return L.pick("Translation Prompts", "翻译提示词")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let saveError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text(saveError)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if let lastSavedAt = settingsStore.lastSavedAt {
                Text(L.pick(
                    "Last saved \(Self.lastSavedFormatter.string(from: lastSavedAt))",
                    "最后保存于 \(Self.lastSavedFormatter.string(from: lastSavedAt))"
                ))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            } else {
                Text(L.pick("Not saved yet", "尚未保存"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(L.pick("Reset", "默认")) {
                resetToDefaults()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private static let lastSavedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    // MARK: - Root page

    private var rootPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                permissionsSection
                generalSection
                aiTranslationSection
                hotkeysSection
                phoneticSection
                smartExplanationSection
                cacheSection
                statsSection
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(maxHeight: 500)
    }

    // MARK: - Cache

    private var cacheSection: some View {
        SettingsSection(title: L.pick("Cache", "缓存")) {
            SettingsToggleRow(
                title: L.pick("Enable cache", "开启缓存"),
                subtitle: L.pick(
                    "Save successful translations locally; identical lookups skip the AI call.",
                    "本地保存翻译结果；下次相同查询不再请求 AI。"
                ),
                isOn: $draft.cacheEnabled,
                onChange: save
            )
            Divider().padding(.horizontal, 10)
            cacheNumberRow(
                title: L.pick("TTL (days)", "缓存天数"),
                subtitle: L.pick(
                    "Entries older than this are treated as misses and pruned.",
                    "超过这个天数的条目当作未命中并自动删除。"
                ),
                value: $draft.cacheTTLDays,
                range: 1...365
            )
            .opacity(draft.cacheEnabled ? 1 : 0.4)
            .disabled(!draft.cacheEnabled)
            Divider().padding(.horizontal, 10)
            cacheNumberRow(
                title: L.pick("Max entries", "缓存上限"),
                subtitle: L.pick(
                    "Hard cap; least-recently-used entries evict when exceeded.",
                    "硬性上限；超过时按最久未用淘汰。"
                ),
                value: $draft.cacheMaxEntries,
                range: 100...50000
            )
            .opacity(draft.cacheEnabled ? 1 : 0.4)
            .disabled(!draft.cacheEnabled)
        }
    }

    private func cacheNumberRow(
        title: String,
        subtitle: String,
        value: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .onChange(of: value.wrappedValue) { newValue in
                    let clamped = min(max(newValue, range.lowerBound), range.upperBound)
                    if clamped != newValue { value.wrappedValue = clamped }
                    debouncedSave()
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: - Stats

    private var statsSection: some View {
        SettingsSection(title: L.pick("Stats", "统计")) {
            HStack(spacing: 12) {
                statBlock(label: L.pick("AI", "AI"), value: "\(cache.aiCount)")
                Divider().frame(height: 28)
                statBlock(label: L.pick("API", "API"), value: "\(cache.apiCount)")
                Divider().frame(height: 28)
                statBlock(label: L.pick("Cache", "缓存"), value: Self.byteFormatter.string(fromByteCount: Int64(cache.totalBytes)))
                Spacer()
                Button(L.pick("Clear", "清空")) {
                    cache.clear()
                }
                .controlSize(.small)
                .disabled(cache.aiCount == 0 && cache.apiCount == 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private func statBlock(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB]
        return f
    }()

    // MARK: - Sections

    private var permissionsSection: some View {
        SettingsSection(title: L.pick("Permissions", "权限")) {
            SettingsPermissionRow(
                title: L.pick("Selection translation", "划词翻译"),
                requirement: L.pick("Accessibility", "辅助功能"),
                granted: accessibilityTrusted,
                refresh: refreshPermissionStatus,
                openSettings: PermissionChecker.openAccessibilitySettings
            )
            Divider().padding(.horizontal, 10)
            SettingsPermissionRow(
                title: L.pick("Screenshot translation", "截图翻译"),
                requirement: L.pick("Screen recording", "屏幕录制"),
                granted: screenRecordingTrusted,
                refresh: refreshPermissionStatus,
                openSettings: PermissionChecker.openScreenRecordingSettings
            )
        }
    }

    private var generalSection: some View {
        SettingsSection(title: L.pick("General", "通用")) {
            HStack(spacing: 10) {
                SettingsTextRow(
                    title: L.pick("Target Language", "目标语言"),
                    text: $draft.targetLanguage,
                    placeholder: L.pick("English", "简体中文"),
                    onChange: debouncedSave
                )
                SettingsNumberRow(
                    title: L.pick("Timeout", "超时"),
                    value: $draft.timeoutSeconds,
                    unit: L.pick("s", "秒"),
                    onChange: debouncedSave
                )
                .frame(width: 96)
            }
            Divider().padding(.horizontal, 10)
            appearanceRow
        }
    }

    private var aiTranslationSection: some View {
        SettingsSection(title: L.pick("AI Translation", "AI 翻译")) {
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
            SettingsNavRow(
                title: L.pick("Translation Prompts", "翻译提示词"),
                subtitle: L.pick(
                    "System prompt and smart-explanation prompt",
                    "系统提示词与智能注释提示词"
                )
            ) {
                route = .translationPrompts
            }
        }
    }

    private var hotkeysSection: some View {
        SettingsSection(title: L.pick("Hotkeys", "快捷键")) {
            shortcutRow(L.pick("Selection translation", "划词翻译"), shortcut: $draft.textHotKey, target: .text)
            shortcutRow(L.pick("Screenshot translation", "截图翻译"), shortcut: $draft.screenshotHotKey, target: .screenshot)
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

    private var appearanceRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(L.pick("Appearance", "外观"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Text(L.pick("Follows the system unless overridden", "默认跟随系统外观"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Picker("", selection: $draft.appearanceMode) {
                Text(L.pick("Auto", "自动")).tag(AppearanceMode.auto)
                Text(L.pick("Light", "浅色")).tag(AppearanceMode.light)
                Text(L.pick("Dark", "深色")).tag(AppearanceMode.dark)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: 150)
            .onChange(of: draft.appearanceMode) { _ in
                save()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: - Hotkey recording
    //
    // The shortcut row is more tightly coupled to view-local state
    // (`recordingTarget`, NSEvent monitor lifetime, draft mutation) than
    // the other rows, so it stays inline rather than getting extracted to
    // SettingsComponents.

    private func shortcutRow(
        _ title: String,
        shortcut: Binding<KeyboardShortcutConfig>,
        target: ShortcutTarget
    ) -> some View {
        let isRecording = recordingTarget == target
        return Button {
            if isRecording {
                stopRecordingShortcut()
            } else {
                beginRecordingShortcut(target)
            }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(isRecording
                         ? L.pick("Press a new combo, Esc to cancel", "按下新组合键，Esc 取消")
                         : shortcut.wrappedValue.displayName)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(isRecording ? Color.accentColor : .secondary)
                }
                Spacer()
                Image(systemName: isRecording ? "record.circle" : "pencil")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isRecording ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func beginRecordingShortcut(_ target: ShortcutTarget) {
        recordingTarget = target
        stopShortcutMonitorOnly()
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 53 = Escape: cancel recording without saving.
            if event.keyCode == 53 {
                self.recordingTarget = nil
                self.stopShortcutMonitorOnly()
                return nil
            }
            guard let recordingTarget = self.recordingTarget,
                  let shortcut = KeyboardShortcutConfig(event: event) else {
                return event
            }
            switch recordingTarget {
            case .text:
                draft.textHotKey = shortcut
            case .screenshot:
                draft.screenshotHotKey = shortcut
            }
            self.recordingTarget = nil
            self.stopShortcutMonitorOnly()
            save()
            return nil
        }
    }

    private func stopRecordingShortcut() {
        recordingTarget = nil
        stopShortcutMonitorOnly()
    }

    private func stopShortcutMonitorOnly() {
        if let shortcutMonitor {
            NSEvent.removeMonitor(shortcutMonitor)
            self.shortcutMonitor = nil
        }
    }

    // MARK: - Permission polling

    private func refreshPermissionStatus() {
        accessibilityTrusted = PermissionChecker.isAccessibilityTrusted
        screenRecordingTrusted = PermissionChecker.isScreenRecordingTrusted
    }

    private func startPermissionPolling() {
        permissionPollTask?.cancel()
        permissionPollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                refreshPermissionStatus()
            }
        }
    }

    // MARK: - Save (auto)

    private func save() {
        do {
            try settingsStore.save(draft)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func debouncedSave() {
        saveDebounceTask?.cancel()
        saveDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled {
                save()
            }
        }
    }

    private func resetToDefaults() {
        let defaults = AppConfiguration.defaultConfig
        draft.systemPrompt = defaults.systemPrompt
        draft.smartExplanationPrompt = defaults.smartExplanationPrompt
        draft.textHotKey = .defaultText
        draft.screenshotHotKey = .defaultScreenshot
        save()
    }
}
