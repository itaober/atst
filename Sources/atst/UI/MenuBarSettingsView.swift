import AppKit
import SwiftUI

private enum SettingsRoute: Hashable {
    case aiPage
    case apiPage
    case translationPrompts
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
    @State private var saveDebounceTask: Task<Void, Never>?
    @State private var routeStack: [SettingsRoute] = []

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
                    SettingsGeneralPage(
                        draft: $draft,
                        cache: cache,
                        stats: stats,
                        save: save,
                        debouncedSave: debouncedSave,
                        openAIPage: { routeStack.append(.aiPage) },
                        openAPIPage: { routeStack.append(.apiPage) }
                    )
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
            .help(L.pick(
                "Reset every setting except the AI endpoint, key and models",
                "恢复全部默认设置；保留 AI 接口地址、Key 和模型"
            ))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private static let lastSavedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

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

    /// Everything back to defaults except the AI endpoint (URL, key, models)
    /// — re-typing those is the one thing a reset must never cost the user.
    private func resetToDefaults() {
        var defaults = AppConfiguration.defaultConfig
        defaults.baseURL = draft.baseURL
        defaults.apiKey = draft.apiKey
        defaults.textModel = draft.textModel
        defaults.screenshotModel = draft.screenshotModel
        draft = defaults
        save()
    }
}
