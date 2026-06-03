import AppKit
import Carbon
import Charts
import SwiftUI

private enum SettingsRoute: Hashable {
    case aiPage
    case apiPage
    case translationPrompts
}

private enum ShortcutTarget: Equatable {
    case text
    case screenshot
}

/// Top-level settings shell. The root page is now the "General" / common
/// configuration page (target language, hotkeys, cache, stats, permissions,
/// appearance) plus nav rows into the AI and API subpages. Each subpage is
/// rendered inline by route-switching the body — keeps the panel's NSPanel
/// the same width across navigation.
struct MenuBarSettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var updateChecker: UpdateChecker
    @ObservedObject var cache: TranslationCache = .shared
    @ObservedObject var stats: TranslationStats = .shared
    var onQuit: () -> Void

    @State private var draft: AppConfiguration
    @State private var saveError: String?
    @State private var accessibilityTrusted = PermissionChecker.isAccessibilityTrusted
    @State private var screenRecordingTrusted = PermissionChecker.isScreenRecordingTrusted
    /// `IsSecureEventInputEnabled()` — when another app puts the system
    /// into Secure Keyboard Entry mode, our hotkeys silently break even
    /// though all three TCC perms are granted. Polling this lets the
    /// settings UI surface a warning so the user knows where to look.
    @State private var secureInputActive = IsSecureEventInputEnabled()
    @State private var recordingTarget: ShortcutTarget?
    @State private var shortcutMonitor: Any?
    @State private var permissionPollTask: Task<Void, Never>?
    @State private var saveDebounceTask: Task<Void, Never>?
    @State private var routeStack: [SettingsRoute] = []
    /// Bound to whichever day in the sparkline the cursor is over via
    /// `chartXSelection`. nil = no hover, hides the inline annotation.
    @State private var sparklineSelectedDate: Date?

    private let panelWidth: CGFloat = 360

    init(
        settingsStore: SettingsStore,
        updateChecker: UpdateChecker,
        onQuit: @escaping () -> Void
    ) {
        self.settingsStore = settingsStore
        self.updateChecker = updateChecker
        self.onQuit = onQuit
        _draft = State(initialValue: settingsStore.configuration)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch currentRoute {
                case .none:
                    rootPage
                case .aiPage:
                    SettingsAIPage(
                        draft: $draft,
                        save: save,
                        debouncedSave: debouncedSave,
                        openPromptsPage: { routeStack.append(.translationPrompts) }
                    )
                case .apiPage:
                    SettingsAPIPage(draft: $draft, save: save)
                case .translationPrompts:
                    SettingsPromptsPage(draft: $draft, save: save)
                }
            }
            Divider()
            footer
        }
        .frame(width: panelWidth)
        // Match the live tooltip + pinned notes: native Liquid Glass on
        // macOS 26+ with Swift 6.2+, falling back to the AppKit `.menu`
        // material on older systems. Border `.none` because the panel's
        // NSPanel chrome already provides shadow + rounded edges via the
        // host view layer (StatusBarController.makePanel).
        .modifier(AdaptiveGlassSurface(
            cornerRadius: 14,
            fallbackMaterial: .menu,
            border: .none
        ))
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

    private var currentRoute: SettingsRoute? { routeStack.last }

    // MARK: - Header / Footer

    private var header: some View {
        HStack(spacing: 8) {
            if !routeStack.isEmpty {
                Button {
                    _ = routeStack.popLast()
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

            // Title with version suffix. On the root page the version is
            // a clickable link to the current release page (so users can
            // jump to the release notes for what they're running). On
            // sub-pages, the title becomes the page name and the version
            // affix is suppressed to avoid header clutter.
            if routeStack.isEmpty {
                rootTitleLabel
            } else {
                Text(headerTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            Spacer()

            if routeStack.isEmpty, updateChecker.hasUpdate, let latest = updateChecker.latest {
                updateAvailableBadge(latest)
            }

            if routeStack.isEmpty {
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

    /// Root-page title: "atst" name + clickable version tag. The tag
    /// opens the matching release page; for dev builds it links to the
    /// releases index instead. Kept as a Button (vs raw Text + Link) so
    /// the hit target is a single rectangle and there's a visible
    /// hover state.
    private var rootTitleLabel: some View {
        Button {
            NSWorkspace.shared.open(Branding.currentReleaseURL)
        } label: {
            // `.firstTextBaseline` makes the two labels sit on a shared
            // typographic baseline — the bottom of "atst" lines up with
            // the bottom of "v0.1.4". Default `.center` HStack alignment
            // floats the smaller version label vertically centered next
            // to the bigger app name, which looks lopsided.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Branding.appName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(Branding.versionDisplay)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L.pick(
            "Open release page for \(Branding.versionDisplay)",
            "打开 \(Branding.versionDisplay) 的 release 页面"
        ))
    }

    /// "Update available" pill rendered when GitHub reports a newer
    /// release than what's running. Tapping opens the new release's
    /// download page directly (not the running version's page).
    private func updateAvailableBadge(_ latest: UpdateChecker.ReleaseInfo) -> some View {
        Button {
            NSWorkspace.shared.open(latest.htmlURL)
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 5, height: 5)
                Text(L.pick("Update \(latest.tagName)", "新版 \(latest.tagName)"))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.orange)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.orange.opacity(0.12))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.3), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(L.pick("Download \(latest.tagName) from GitHub", "前往 GitHub 下载 \(latest.tagName)"))
    }

    private var headerTitle: String {
        switch currentRoute {
        case .none: return Branding.appName
        case .aiPage: return L.pick("AI Translation", "AI 翻译")
        case .apiPage: return L.pick("API Translation", "API 翻译")
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
            Button(L.pick("Reset", "恢复默认")) {
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

    // MARK: - Root (general) page

    private var rootPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                permissionsSection
                generalSection
                translatorNavSection
                hotkeysSection
                screenshotSection
                cacheSection
                statsSection
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(maxHeight: 540)
    }

    // MARK: - Screenshot section

    /// Screenshot-specific config: Vision OCR toggle + the recognition
    /// language set used when OCR mode is on. Sits between the hotkeys
    /// section and the cache section because it's a screenshot-flow
    /// concern but unrelated to either translation provider.
    private var screenshotSection: some View {
        SettingsSection(title: L.pick("Screenshot", "截图")) {
            SettingsToggleRow(
                title: L.pick("Use Vision OCR", "使用 Vision OCR"),
                subtitle: L.pick(
                    "Recognise text locally, then translate. Falls back to AI vision when no text is found.",
                    "先在本地识别文字，再进行翻译。识别不到文字时使用 AI 视觉。"
                ),
                isOn: $draft.screenshotUseVisionOCR,
                onChange: save
            )
            Divider().padding(.horizontal, 10)
            ocrLanguagesRow
                .opacity(draft.screenshotUseVisionOCR ? 1 : 0.4)
                .disabled(!draft.screenshotUseVisionOCR)
        }
    }

    /// Recognition-language picker. Selected languages render as removable
    /// chips inline; a trailing "+" button opens a menu with whatever
    /// languages aren't yet selected. Tap order = recognition priority,
    /// so the chip list doubles as a priority list.
    private var ocrLanguagesRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L.pick("Recognition languages", "识别语言"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(L.pick(
                        "Tried in order. Add the languages you often capture.",
                        "按顺序识别。添加你常截到的语言。"
                    ))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
            }
            languageChipsRow
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var languageChipsRow: some View {
        FlowLayoutWrapping(spacing: 4, runSpacing: 4) {
            ForEach(draft.ocrLanguages, id: \.self) { code in
                LanguageChip(
                    name: displayName(for: code),
                    onRemove: draft.ocrLanguages.count > 1
                        ? { removeOCRLanguage(code) }
                        : nil  // refuse to remove the last one
                )
            }
            addLanguageMenu
        }
    }

    private var addLanguageMenu: some View {
        let unselected = VisionOCRService.supportedLanguages
            .filter { !draft.ocrLanguages.contains($0.code) }
        return Menu {
            if unselected.isEmpty {
                Text(L.pick("All supported languages added", "已添加所有支持的语言"))
            } else {
                ForEach(unselected) { language in
                    Button(language.displayName) {
                        draft.ocrLanguages.append(language.code)
                        save()
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                Text(L.pick("Add", "添加"))
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(unselected.isEmpty)
        .opacity(unselected.isEmpty ? 0.4 : 1)
    }

    private func displayName(for code: String) -> String {
        VisionOCRService.supportedLanguages.first(where: { $0.code == code })?.displayName ?? code
    }

    private func removeOCRLanguage(_ code: String) {
        draft.ocrLanguages.removeAll { $0 == code }
        if draft.ocrLanguages.isEmpty {
            // Should be unreachable thanks to the chip's onRemove gate, but
            // belt-and-braces: never let the user end up with zero
            // recognition languages because Vision wouldn't recognise
            // anything at all.
            draft.ocrLanguages = AppConfiguration.defaultOCRLanguages
        }
        save()
    }

    /// AI/API entry rows shown on the General page. Each row carries its
    /// enable toggle inline (so the user can flip a segment on/off without
    /// drilling in) plus a chevron to push the detail subpage.
    ///
    /// Order matches the live tooltip layout — API rows render above the
    /// AI section there, so we mirror that order here. Cheap visual
    /// continuity between settings and runtime.
    private var translatorNavSection: some View {
        SettingsSection(title: L.pick("Translators", "翻译方式")) {
            translatorNavRow(
                title: L.pick("API Translation", "API 翻译"),
                subtitle: apiSubtitle,
                isOn: $draft.apiEnabled,
                onTap: { routeStack.append(.apiPage) }
            )
            Divider().padding(.horizontal, 10)
            translatorNavRow(
                title: L.pick("AI Translation", "AI 翻译"),
                subtitle: aiSubtitle,
                isOn: $draft.aiEnabled,
                onTap: { routeStack.append(.aiPage) }
            )
        }
    }

    private var aiSubtitle: String {
        let trimmed = draft.textModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return L.pick("Model not configured", "尚未配置模型")
        }
        return trimmed
    }

    private var apiSubtitle: String {
        let enabled = draft.apiProviders.filter(\.enabled).compactMap { entry -> String? in
            switch entry.kind {
            case .google: return "Google"
            case .microsoft: return "Microsoft"
            case .ai, .none: return nil
            }
        }
        if enabled.isEmpty {
            return L.pick("No translators enabled", "未启用任何翻译源")
        }
        return enabled.joined(separator: " · ")
    }

    private func translatorNavRow(
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        onTap: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .onChange(of: isOn.wrappedValue) { _ in save() }
            Button(action: onTap) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    // MARK: - Cache section

    private var cacheSection: some View {
        SettingsSection(title: L.pick("Cache", "缓存")) {
            SettingsToggleRow(
                title: L.pick("Enable cache", "开启缓存"),
                subtitle: L.pick(
                    "Save translations locally. Repeat lookups skip the network.",
                    "本地保存翻译结果，相同查询直接复用。"
                ),
                isOn: $draft.cacheEnabled,
                onChange: save
            )
            Divider().padding(.horizontal, 10)
            cacheNumberRow(
                title: L.pick("Days to keep", "保留天数"),
                subtitle: L.pick(
                    "Older entries are discarded automatically.",
                    "超过天数的条目会自动清除。"
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
                    "Once reached, the least recently used entries are removed.",
                    "达到上限后，按最久未用清除。"
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

    private var statsSection: some View {
        SettingsSection(title: L.pick("Stats", "统计")) {
            HStack(spacing: 12) {
                statBlock(label: L.pick("AI", "AI"), value: "\(cache.aiCount)")
                Divider().frame(height: 28)
                statBlock(label: L.pick("API", "API"), value: "\(cache.apiCount)")
                Divider().frame(height: 28)
                cacheSizeStatBlock
                Spacer(minLength: 6)
                statsSparkline
                Spacer(minLength: 6)
                Button(L.pick("Clear", "清空")) {
                    cache.clear()
                    stats.clear()
                }
                .controlSize(.small)
                .fixedSize()
                .disabled(cache.aiCount == 0 && cache.apiCount == 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    /// 14-day sparkline with two stacked series:
    ///   - Total: every user-triggered translation (incl. cache hits)
    ///   - New:   only cache misses (fresh provider calls)
    ///
    /// Uses macOS 14's `chartXSelection` for native hover that tracks
    /// the cursor x-position. The selected day's annotation (date +
    /// both counts) is anchored to a `RuleMark` so the tooltip arrow
    /// follows the mouse. Hidden axes since at 70pt wide the visual is
    /// a glance-able shape, not a precise reading.
    private var statsSparkline: some View {
        // Touch revision so this view re-evaluates whenever stats change.
        _ = stats.revision
        let series = stats.dailyCounts(days: 14)
        let maxValue = max(1, series.map(\.total).max() ?? 1)
        let selectedEntry = sparklineSelectedDate.flatMap { date in
            series.min(by: {
                abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
            })
        }

        return Chart {
            ForEach(series, id: \.date) { day in
                LineMark(
                    x: .value("Day", day.date),
                    y: .value("Count", day.total),
                    series: .value("Kind", "total")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            ForEach(series, id: \.date) { day in
                LineMark(
                    x: .value("Day", day.date),
                    y: .value("Count", day.new),
                    series: .value("Kind", "new")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Color.orange)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [2, 2]))
            }
            if let entry = selectedEntry {
                RuleMark(x: .value("Selected", entry.date))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(
                        position: .top,
                        alignment: .center,
                        spacing: 4,
                        overflowResolution: .init(x: .disabled, y: .disabled)
                    ) {
                        sparklineHoverContent(for: entry)
                            .padding(10)
                            .padding(.bottom, 5) // room for the downward arrow tip
                            .background(.regularMaterial, in: PopoverCardShape())
                            .overlay(
                                PopoverCardShape()
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                            )
                            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                    }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...maxValue)
        .chartXSelection(value: $sparklineSelectedDate)
        .frame(width: 70, height: 22)
    }

    private func sparklineHoverContent(for entry: TranslationStats.DailyEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.hoverDateFormatter.string(from: entry.date))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                hoverStat(
                    color: .accentColor,
                    label: L.pick("Total", "总次数"),
                    value: entry.total
                )
                Divider().frame(height: 32)
                hoverStat(
                    color: .orange,
                    label: L.pick("New", "新词"),
                    value: entry.new
                )
            }
        }
    }

    private func hoverStat(color: Color, label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(value)")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let hoverDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: L.isChinese ? "zh_CN" : "en_US")
        f.dateFormat = L.isChinese ? "M月d日 EEEE" : "MMM d, EEEE"
        return f
    }()

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

    /// Cache size variant of `statBlock` — splits the byte-formatted
    /// string ("214 KB") into number + unit and renders them on a
    /// shared baseline with a smaller unit font. This stops "214 KB"
    /// from wrapping when the stats row is tight, and matches the
    /// visual rhythm of weather / activity widgets that pair a big
    /// number with a small unit.
    private var cacheSizeStatBlock: some View {
        let formatted = Self.byteFormatter.string(fromByteCount: Int64(cache.totalBytes))
        let parts = formatted.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let number = parts.first.map(String.init) ?? formatted
        let unit = parts.count > 1 ? String(parts[1]) : ""
        return VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(number)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Text(L.pick("Cache", "缓存"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .fixedSize()
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        // `.memory` uses 1024-based thresholds (1 KB at 1024 bytes,
        // 1 MB at 1024 KB), matching Activity Monitor and developer
        // intuition. `.file` would use 1000-based steps like Finder
        // — fine for storage but feels wrong for an in-process cache.
        f.countStyle = .memory
        f.allowedUnits = [.useKB, .useMB]
        return f
    }()

    // MARK: - Other sections (Permissions / General / Hotkeys)

    private var permissionsSection: some View {
        // Three permissions, each gating a specific capability. Order is
        // chosen so the most user-visible feature (hotkeys) sits in the
        // middle — both other rows make less sense without it.
        VStack(alignment: .leading, spacing: 8) {
            if secureInputActive {
                secureInputWarning
            }
            permissionsSectionInner
        }
    }

    /// Banner shown when some other app on the system has enabled macOS's
    /// `SecureEventInput` — most often 1Password during autofill, Terminal
    /// with "Secure Keyboard Entry" checked, or a focused password field.
    /// When secure input is active **every** CGEventTap stops receiving
    /// keyDown events globally, so atst's hotkeys silently break even
    /// though every TCC perm is granted. The warning saves the user from
    /// chasing a non-existent permission bug.
    private var secureInputWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(L.pick(
                    "Hotkeys blocked by another app",
                    "快捷键被其他 App 拦截"
                ))
                .font(.system(size: 12, weight: .semibold))
                Text(L.pick(
                    "macOS Secure Keyboard Entry is active. Common culprits: 1Password autofill, Terminal, or a focused password field.",
                    "macOS 安全键盘输入被占用。常见来源：1Password 自动填充、Terminal、密码输入框。"
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }

    private var permissionsSectionInner: some View {
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
            // Every row shares the same horizontal layout — label (+
            // optional subtitle) on the left, control pinned to the right
            // edge — so the section has a consistent visual rhythm rather
            // than mixing "label above" and "label beside" patterns.
            targetLanguageRow
            Divider().padding(.horizontal, 10)
            timeoutRow
            Divider().padding(.horizontal, 10)
            uiLanguageRow
            Divider().padding(.horizontal, 10)
            appearanceRow
            Divider().padding(.horizontal, 10)
            pinnedNoteFollowsRow
        }
    }

    /// Width applied to every right-aligned control in the General
    /// section (target-language popup, segmented pickers). Picking a single
    /// value gives the section a vertical guideline that the eye can
    /// follow down the right edge. 170pt comfortably fits the longest
    /// preset label ("繁體中文") at .small picker size with breathing room.
    private let generalControlWidth: CGFloat = 170

    /// Target language picker. Native SwiftUI `Picker` so the chevron /
    /// hover background / focus ring come from AppKit. Saved free-form
    /// values not in the preset list get prepended above a divider so
    /// historical configs keep their selection visible.
    private var targetLanguageRow: some View {
        HStack(spacing: 10) {
            Text(L.pick("Target Language", "目标语言"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            // Wrap the Picker in a fixed-width right-aligned container.
            // `.menu`-style Pickers don't stretch to fill `.frame(width:)`
            // — the popup button hugs its longest option label — so a
            // bare `.frame(width: 170)` would render the button at the
            // *leading* edge, leaving the right edge short of the
            // segmented controls below it. Wrapping in an HStack with a
            // leading Spacer and an outer fixed-width container pins the
            // button's right edge to the same x as the other rows.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Picker("", selection: $draft.targetLanguage) {
                    if isCustomTargetLanguage {
                        Text(draft.targetLanguage).tag(draft.targetLanguage)
                        Divider()
                    }
                    ForEach(TargetLanguagePreset.all, id: \.self) { preset in
                        Text(preset).tag(preset)
                    }
                }
                .labelsHidden()
                // .small (not .mini): the target language is the most-changed
                // value in this section, so its text ("简体中文" etc.) should
                // be as readable as the row label next to it.
                .controlSize(.small)
                .fixedSize()
                .onChange(of: draft.targetLanguage) { _ in
                    save()
                }
            }
            .frame(width: generalControlWidth, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var isCustomTargetLanguage: Bool {
        !draft.targetLanguage.isEmpty
            && !TargetLanguagePreset.all.contains(draft.targetLanguage)
    }

    /// Inline numeric timeout. The text field sits inside a fixed-width
    /// container aligned to the same right edge as the other General
    /// controls; the "秒 / s" unit sits to its right, breaking the rigid
    /// alignment slightly but staying readable.
    private var timeoutRow: some View {
        HStack(spacing: 10) {
            Text(L.pick("Timeout", "超时"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
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
            .frame(width: generalControlWidth, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var uiLanguageRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(L.pick("Interface Language", "界面语言"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Text(L.pick("Auto follows the system", "自动跟随系统"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            // Same right-aligned container as targetLanguageRow:
            // `.pickerStyle(.segmented).frame(width:)` doesn't force the
            // control to expand to the requested width — it hugs its
            // segment-content widths instead, so a row with longer
            // labels (e.g. "English") would render visibly wider than a
            // row with shorter labels (e.g. "浅色"). Wrapping in a
            // Spacer + fixed-width trailing container pins the right
            // edge of every General-section control to the same x.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Picker("", selection: $draft.uiLanguage) {
                    Text(L.pick("Auto", "自动")).tag(UILanguage.auto)
                    Text("English").tag(UILanguage.english)
                    Text("中文").tag(UILanguage.chinese)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
                .onChange(of: draft.uiLanguage) { _ in
                    save()
                }
            }
            .frame(width: generalControlWidth, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var hotkeysSection: some View {
        SettingsSection(title: L.pick("Hotkeys", "快捷键")) {
            shortcutRow(L.pick("Selection translation", "划词翻译"), shortcut: $draft.textHotKey, target: .text)
            shortcutRow(L.pick("Screenshot translation", "截图翻译"), shortcut: $draft.screenshotHotKey, target: .screenshot)
        }
    }

    private var appearanceRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(L.pick("Appearance", "外观"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Text(L.pick("Auto follows the system", "自动跟随系统"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            // Same right-aligned container as uiLanguageRow — segmented
            // pickers hug their segment-content widths, so different
            // labels per row produce different physical widths unless
            // pinned to a trailing-aligned fixed-width parent.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Picker("", selection: $draft.appearanceMode) {
                    Text(L.pick("Auto", "自动")).tag(AppearanceMode.auto)
                    Text(L.pick("Light", "浅色")).tag(AppearanceMode.light)
                    Text(L.pick("Dark", "深色")).tag(AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
                .onChange(of: draft.appearanceMode) { _ in
                    save()
                }
            }
            .frame(width: generalControlWidth, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var pinnedNoteFollowsRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(L.pick("Notes on all desktops", "便签跨桌面显示"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Text(L.pick(
                    "Keep pinned notes visible after switching Space",
                    "切换桌面后便签依然可见"
                ))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Toggle("", isOn: $draft.pinnedNoteFollowsAcrossSpaces)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: draft.pinnedNoteFollowsAcrossSpaces) { _ in
                        save()
                    }
            }
            .frame(width: generalControlWidth, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: - Hotkey recording

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
        secureInputActive = IsSecureEventInputEnabled()
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
        draft.aiEnabled = defaults.aiEnabled
        draft.apiEnabled = defaults.apiEnabled
        draft.apiProviders = defaults.apiProviders
        draft.screenshotUseVisionOCR = defaults.screenshotUseVisionOCR
        draft.ocrLanguages = defaults.ocrLanguages
        draft.uiLanguage = defaults.uiLanguage
        draft.targetLanguage = defaults.targetLanguage
        draft.timeoutSeconds = defaults.timeoutSeconds
        save()
    }
}

/// Curated list of common translation targets. Aims to cover the languages
/// atst's typical users (CN / EN-centric developers) are most likely to
/// translate into; the underlying provider accepts any of these strings.
/// For API providers (Google / Microsoft) `LanguageCode.bcp47` maps each
/// display string to the right BCP-47 code under the hood.
enum TargetLanguagePreset {
    static let all: [String] = [
        "简体中文",
        "繁體中文",
        "English",
        "日本語",
        "한국어",
        "Français",
        "Deutsch",
        "Español",
        "Italiano",
        "Português",
        "Русский"
    ]
}

// MARK: - Language chip + flow layout

/// Small removable pill used to display selected OCR languages. Reads as a
/// chip / tag — recognisable from countless modern settings UIs. The ×
/// button only renders when `onRemove` is set, so callers can disable
/// removal (e.g. for the last remaining language to keep OCR functional).
/// Popover-styled card with a downward-pointing arrow at the bottom-
/// center. Used as the background for the sparkline's hover annotation
/// so the tooltip visually resembles a native popover (material
/// background + arrow indicator + drop shadow) while staying inside
/// SwiftUI Charts' annotation system — meaning it follows the cursor
/// natively via `chartXSelection`.
private struct PopoverCardShape: Shape {
    var cornerRadius: CGFloat = 8
    var arrowWidth: CGFloat = 10
    var arrowHeight: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        let bodyHeight = rect.height - arrowHeight
        let bodyRect = CGRect(x: 0, y: 0, width: rect.width, height: bodyHeight)

        var path = Path(roundedRect: bodyRect, cornerRadius: cornerRadius)

        // Append the downward arrow at the bottom-center.
        let centerX = rect.midX
        path.move(to: CGPoint(x: centerX - arrowWidth / 2, y: bodyHeight))
        path.addLine(to: CGPoint(x: centerX, y: rect.maxY))
        path.addLine(to: CGPoint(x: centerX + arrowWidth / 2, y: bodyHeight))
        path.closeSubpath()

        return path
    }
}

private struct LanguageChip: View {
    let name: String
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help(L.pick("Remove", "移除"))
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, onRemove == nil ? 7 : 4)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }
}

/// Lightweight flow layout (wrap-to-next-line) used by the OCR language
/// chips row. Built on SwiftUI's native `Layout` protocol — available on
/// our deployment target so the implementation stays short.
private struct FlowLayoutWrapping: Layout {
    var spacing: CGFloat = 4
    var runSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                y += rowHeight + runSpacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, x)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : totalWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Two passes: row-break the children first so we know each row's
        // max height, then place each child vertically centered within
        // its row. Single-pass placement (place top-aligned as we go)
        // was visibly wrong for heterogeneous rows — the OCR chip with
        // an embedded × hit-target sits 2pt taller than the "+ 添加"
        // menu pill, so they ended up top-aligned but center-misaligned.
        var rows: [[Int]] = [[]]
        var rowHeights: [CGFloat] = [0]
        var x: CGFloat = 0
        for (idx, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.width, x > 0 {
                rows.append([])
                rowHeights.append(0)
                x = 0
            }
            rows[rows.count - 1].append(idx)
            rowHeights[rowHeights.count - 1] = max(rowHeights[rowHeights.count - 1], size.height)
            x += size.width + spacing
        }

        var y: CGFloat = bounds.minY
        for (rowIdx, row) in rows.enumerated() {
            let rowHeight = rowHeights[rowIdx]
            var rowX: CGFloat = bounds.minX
            for idx in row {
                let subview = subviews[idx]
                let size = subview.sizeThatFits(.unspecified)
                let dy = (rowHeight - size.height) / 2
                subview.place(at: CGPoint(x: rowX, y: y + dy), proposal: ProposedViewSize(size))
                rowX += size.width + spacing
            }
            y += rowHeight + runSpacing
        }
    }
}
