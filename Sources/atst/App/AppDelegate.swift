import AppKit
import ApplicationServices
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore = SettingsStore()
    private lazy var viewModel = TranslatorViewModel(settingsStore: settingsStore)
    private lazy var panelController = FloatingPanelController(
        viewModel: viewModel,
        onRefresh: { [weak self] sourceText in
            self?.refreshTranslation(sourceText: sourceText)
        },
        onOpenSettings: { [weak self] in
            self?.statusBarController.openSettings()
        }
    )
    private lazy var statusBarController = StatusBarController(
        settingsStore: settingsStore,
        onTranslateSelection: { [weak self] in
            self?.translateSelection()
        },
        onTranslateScreenshot: { [weak self] in
            self?.translateScreenshot()
        },
        onQuit: {
            NSApp.terminate(nil)
        }
    )
    private let screenshotProvider = ScreenshotProvider()
    private let hotKeyMonitor = GlobalHotKeyMonitor()
    private var cancellables = Set<AnyCancellable>()
    private var accessibilityWatchTimer: Timer?
    private var didLogMissingPermission = false
    private var currentTranslationTask: Task<Void, Never>?
    private var currentScreenshotTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.log("atst launched pid=\(ProcessInfo.processInfo.processIdentifier) ax=\(PermissionChecker.isAccessibilityTrusted)")
        NSApp.setActivationPolicy(.accessory)
        applyAppearance(settingsStore.configuration.appearanceMode)
        configureMainMenu()
        _ = statusBarController
        configureHotKeys(settingsStore.configuration)
        ensureHotKeyMonitorRunning(prompt: true)
        startAccessibilityWatch()
        prewarmAllProviders(settingsStore.configuration)
        startPrewarmTimer()
        applyCacheSettings(settingsStore.configuration)

        settingsStore.$configuration
            .dropFirst()
            .sink { [weak self] configuration in
                self?.configureHotKeys(configuration)
                self?.ensureHotKeyMonitorRunning(prompt: false)
                self?.applyAppearance(configuration.appearanceMode)
                self?.applyCacheSettings(configuration)
                self?.prewarmAllProviders(configuration)
            }
            .store(in: &cancellables)
    }

    private func applyCacheSettings(_ configuration: AppConfiguration) {
        TranslationCache.shared.configure(
            enabled: configuration.cacheEnabled,
            ttlDays: configuration.cacheTTLDays,
            maxEntries: configuration.cacheMaxEntries
        )
    }

    /// Prewarm every enabled provider's underlying HTTP host. Each one
    /// dedupes pooled URLSession connections on its own, so calling more
    /// than we need is cheap. Disabled providers are skipped to avoid
    /// pinging hosts the user doesn't want contacted.
    private func prewarmAllProviders(_ configuration: AppConfiguration) {
        if configuration.aiEnabled {
            OpenAICompatibleClient.prewarm(configuration: configuration)
        }
        if configuration.apiEnabled {
            for kind in configuration.enabledAPIProviderKinds {
                switch kind {
                case .google:
                    GoogleProvider.prewarm()
                case .microsoft:
                    MicrosoftProvider.prewarm()
                case .ai:
                    break
                }
            }
        }
    }

    private var prewarmTimer: Timer?
    private func startPrewarmTimer() {
        prewarmTimer?.invalidate()
        // Refresh pooled connections every 4 minutes (well under most
        // server-side idle timeouts) so they stay hot.
        let timer = Timer.scheduledTimer(withTimeInterval: 240, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.prewarmAllProviders(self.settingsStore.configuration)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        prewarmTimer = timer
    }

    private func applyAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .auto:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLogger.log("atst terminating")
        accessibilityWatchTimer?.invalidate()
        accessibilityWatchTimer = nil
        prewarmTimer?.invalidate()
        prewarmTimer = nil
        currentTranslationTask?.cancel()
        currentScreenshotTask?.cancel()
        hotKeyMonitor.stop()
    }

    @objc private func translateSelection() {
        AppLogger.log("translateSelection invoked")
        currentTranslationTask?.cancel()
        currentScreenshotTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                AppLogger.log("translateSelection: reading current selection")
                let selection = try await self.viewModel.readCurrentSelection()
                try Task.checkCancellation()
                AppLogger.log("translateSelection: got selection length=\(selection.text.count)")
                self.viewModel.beginTextTranslation(source: selection.text)
                self.panelController.show(anchor: selection.anchorRect.map { .rect($0) } ?? .mouse, activate: false)
                AppLogger.log("translateSelection: panel shown, requesting translation")
                await self.viewModel.translateSelection(selection)
                try Task.checkCancellation()
                AppLogger.log("translateSelection: translation finished")
            } catch is CancellationError {
                AppLogger.log("translateSelection: cancelled by newer request")
            } catch {
                AppLogger.log("translateSelection: error \(error)")
                self.viewModel.showError(error)
                self.panelController.show(anchor: .mouse)
            }
        }
        currentTranslationTask = task
    }

    @objc private func translateScreenshot() {
        AppLogger.log("translateScreenshot invoked")
        currentTranslationTask?.cancel()
        currentScreenshotTask?.cancel()
        panelController.close()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let capture = try await self.screenshotProvider.captureInteractiveScreenshot()
                try Task.checkCancellation()
                self.viewModel.beginScreenshotTranslation()
                self.panelController.show(anchor: .point(capture.anchorPoint))
                await self.viewModel.translateScreenshot(capture)
                try Task.checkCancellation()
            } catch is CancellationError {
                AppLogger.log("translateScreenshot: cancelled by newer request")
            } catch {
                if case AppError.screenshotCancelled = error {
                    return
                }
                self.viewModel.showError(error)
                self.panelController.show(anchor: .mouse)
            }
        }
        currentScreenshotTask = task
    }

    @objc private func closePanel() {
        panelController.close()
    }

    /// Triggered when the user clicks the "cached — refresh" affordance in
    /// the tooltip header. Skips pasteboard capture (we already have the
    /// source text) and forces fresh provider calls by bypassing the cache.
    private func refreshTranslation(sourceText: String) {
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        AppLogger.log("refreshTranslation invoked length=\(trimmed.count)")
        currentTranslationTask?.cancel()
        currentScreenshotTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            let selection = SelectedText(text: sourceText, anchorRect: nil)
            self.viewModel.beginTextTranslation(source: sourceText)
            await self.viewModel.translateSelection(selection, bypassCache: true)
        }
        currentTranslationTask = task
    }

    private func configureHotKeys(_ configuration: AppConfiguration) {
        hotKeyMonitor.update(bindings: [
            GlobalHotKeyMonitor.Binding(
                id: "text",
                keyCode: configuration.textHotKey.keyCode,
                modifiers: configuration.textHotKey.modifiers
            ) { [weak self] in
                self?.translateSelection()
            },
            GlobalHotKeyMonitor.Binding(
                id: "screenshot",
                keyCode: configuration.screenshotHotKey.keyCode,
                modifiers: configuration.screenshotHotKey.modifiers
            ) { [weak self] in
                self?.translateScreenshot()
            }
        ])
    }

    private func ensureHotKeyMonitorRunning(prompt: Bool) {
        if hotKeyMonitor.start() {
            didLogMissingPermission = false
            return
        }

        if !didLogMissingPermission {
            AppLogger.log("hotkey monitor unavailable; accessibility permission required")
            didLogMissingPermission = true
        }

        if prompt {
            promptForAccessibility()
        }
    }

    private func promptForAccessibility() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func startAccessibilityWatch() {
        accessibilityWatchTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.hotKeyMonitor.reenableIfNeeded()
                if self.hotKeyMonitor.eventTap == nil {
                    self.ensureHotKeyMonitorRunning(prompt: false)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        accessibilityWatchTimer = timer
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: Branding.appName)
        appMenu.addItem(
            withTitle: L.pick("Quit \(Branding.appName)", "退出 \(Branding.appName)"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: L.pick("Cut", "剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L.pick("Copy", "复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L.pick("Paste", "粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L.pick("Select All", "全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }
}
