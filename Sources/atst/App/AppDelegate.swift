import AppKit
import ApplicationServices
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore = SettingsStore()
    private let updateChecker = UpdateChecker()
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
        updateChecker: updateChecker,
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
        L.override = settingsStore.configuration.uiLanguage
        applyAppearance(settingsStore.configuration.appearanceMode)
        configureMainMenu()
        _ = statusBarController
        configureHotKeys(settingsStore.configuration)
        // Don't prompt for Accessibility at launch — the perm rows in the
        // settings panel are the canonical surface for grant/manage, and
        // unsolicited startup dialogs are noisy. We just try to bring up
        // the tap; if it fails, log and let the user discover the
        // missing perm via settings.
        ensureHotKeyMonitorRunning()
        startAccessibilityWatch()
        AppLogger.log("permissions snapshot ax=\(PermissionChecker.isAccessibilityTrusted) screen=\(PermissionChecker.isScreenRecordingTrusted)")
        prewarmAllProviders(settingsStore.configuration)
        startPrewarmTimer()
        applyCacheSettings(settingsStore.configuration)
        // Fire-and-forget update probe. The checker rate-limits itself
        // (4-hour TTL), so calling on every launch is cheap.
        updateChecker.checkInBackground()

        settingsStore.$configuration
            .dropFirst()
            .sink { [weak self] configuration in
                L.override = configuration.uiLanguage
                self?.configureHotKeys(configuration)
                self?.ensureHotKeyMonitorRunning()
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
    /// pinging hosts the user doesn't want contacted. Also pre-warms
    /// Vision OCR's model load when the user has the OCR mode on, so the
    /// first screenshot translation doesn't pay the ~200ms cold-start.
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
        if configuration.screenshotUseVisionOCR {
            VisionOCRService.prewarm()
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

    private func translateSelection() {
        AppLogger.log("translateSelection invoked")
        currentTranslationTask?.cancel()
        currentScreenshotTask?.cancel()
        // Lazy permission check: the user just expressed intent to use a
        // feature, this is the right moment to ensure its prerequisites.
        // Accessibility is needed because SelectedTextProvider's pasteboard
        // fallback simulates ⌘C. (Input Monitoring isn't checked here —
        // if this code is running via the hotkey, IM must already be
        // granted, otherwise the keyDown wouldn't have reached us.)
        guard PermissionChecker.isAccessibilityTrusted else {
            AppLogger.log("translateSelection: accessibility not granted, surfacing error")
            viewModel.showError(AppError.accessibilityPermissionRequired)
            panelController.show(anchor: .mouse)
            return
        }
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

    /// Screenshot translation has three possible flows:
    ///
    ///   1. **Vision OCR ON (default)**: capture → on-device OCR → text →
    ///      multi-provider text translation. Same UI as selection translation.
    ///   2. **Vision OCR ON + no text recognised**: auto-fall-back to AI
    ///      vision so the user still gets a translation. Requires AI to be
    ///      enabled AND `screenshotModel` configured.
    ///   3. **Vision OCR OFF**: capture → AI vision directly. Requires AI
    ///      to be enabled AND `screenshotModel` configured.
    ///
    /// When AI is disabled and OCR can't help, we surface a clear error
    /// instead of letting the underlying request fail with a generic
    /// "model not configured" message.
    private func translateScreenshot() {
        AppLogger.log("translateScreenshot invoked")
        currentTranslationTask?.cancel()
        currentScreenshotTask?.cancel()
        panelController.close()
        // Lazy permission check: screencapture -i requires Screen Recording
        // on macOS 10.15+. Without it the subprocess silently produces an
        // empty file. Catch ahead of time and surface a clean prompt.
        guard PermissionChecker.isScreenRecordingTrusted else {
            AppLogger.log("translateScreenshot: screen recording not granted, surfacing error")
            viewModel.showError(AppError.screenRecordingPermissionRequired)
            panelController.show(anchor: .mouse)
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let capture = try await self.screenshotProvider.captureInteractiveScreenshot()
                try Task.checkCancellation()
                let config = self.settingsStore.configuration
                if config.screenshotUseVisionOCR {
                    await self.runOCRThenTranslate(capture: capture)
                } else {
                    await self.runAIVisionTranslate(capture: capture)
                }
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

    /// OCR mode — try local Vision recognition first; on empty result fall
    /// back to AI vision when it's available, otherwise show a friendly
    /// "no text + no AI" error. Tooltip shows a transitional "recognising…"
    /// state while OCR runs, then switches into the regular dual-segment
    /// text translation UI once text is in hand.
    private func runOCRThenTranslate(capture: ScreenshotCapture) async {
        let config = settingsStore.configuration
        viewModel.beginScreenshotOCR()
        panelController.show(anchor: screenshotAnchor(for: capture))

        let text: String
        do {
            text = try await VisionOCRService.recognize(
                imageData: capture.imageData,
                languages: config.ocrLanguages
            )
        } catch {
            AppLogger.log("ocr failed, attempting AI vision fallback: \(error)")
            // OCR threw (e.g. Vision framework error) — try AI vision if
            // configured, otherwise tell the user why nothing happened.
            if Task.isCancelled { return }
            if isAIVisionAvailable(config: config) {
                await runAIVisionTranslate(capture: capture, alreadyShowing: true)
            } else {
                viewModel.showError(AppError.noScreenshotText)
            }
            return
        }

        // OCR call returned. The detached Task inside VisionOCRService
        // doesn't honour outer cancellation, so re-check here before we
        // mutate any state — a newer screenshot may already have replaced
        // ours and we don't want stale text leaking through.
        if Task.isCancelled {
            AppLogger.log("ocr completed but task cancelled, discarding result")
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Require at least 2 chars so a stray punctuation pick doesn't
        // masquerade as a successful recognition.
        if trimmed.count < 2 {
            AppLogger.log("ocr returned no usable text (\(trimmed.count) chars)")
            if isAIVisionAvailable(config: config) {
                AppLogger.log("falling back to AI vision")
                await runAIVisionTranslate(capture: capture, alreadyShowing: true)
            } else {
                AppLogger.log("AI vision unavailable, surfacing no-text error")
                viewModel.showError(AppError.noScreenshotText)
            }
            return
        }

        AppLogger.log("ocr recognized \(trimmed.count) chars, routing to text translation pipeline")
        let selection = SelectedText(text: trimmed, anchorRect: nil)
        viewModel.beginTextTranslation(source: trimmed)
        await viewModel.translateSelection(selection)
    }

    /// AI vision path — only run when AI is enabled AND a screenshot
    /// model is configured. The check is duplicated from
    /// `isAIVisionAvailable` so the error message can be specific (and so
    /// we don't make the user squint at a generic 'model not configured'
    /// trace when the real intent was "AI is off").
    private func runAIVisionTranslate(capture: ScreenshotCapture, alreadyShowing: Bool = false) async {
        let config = settingsStore.configuration
        guard isAIVisionAvailable(config: config) else {
            AppLogger.log("AI vision unavailable (aiEnabled=\(config.aiEnabled), model='\(config.screenshotModel)')")
            if !alreadyShowing {
                panelController.show(anchor: screenshotAnchor(for: capture))
            }
            viewModel.showError(config.aiEnabled
                ? AppError.noScreenshotModelConfigured
                : AppError.aiDisabledForVision)
            return
        }
        viewModel.beginScreenshotTranslation()
        if !alreadyShowing {
            panelController.show(anchor: screenshotAnchor(for: capture))
        }
        await viewModel.translateScreenshot(capture)
    }

    /// Prefer the reverse-engineered screenshot rect (which lets the
    /// floating panel pick a side that doesn't cover the source) and fall
    /// back to the raw mouse-release point when rect detection failed.
    private func screenshotAnchor(for capture: ScreenshotCapture) -> FloatingPanelAnchor {
        if let rect = capture.recognisedRect {
            return .rect(rect)
        }
        return .point(capture.anchorPoint)
    }

    private func isAIVisionAvailable(config: AppConfiguration) -> Bool {
        guard config.aiEnabled else { return false }
        let model = config.screenshotModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return !model.isEmpty
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

    /// Attempt to bring up the global hotkey tap. Silent — if it fails
    /// (most commonly because Accessibility is not granted), we log once
    /// and return. The user discovers the issue through the permissions
    /// section of the settings panel, which is the canonical place to
    /// manage grants.
    private func ensureHotKeyMonitorRunning() {
        if hotKeyMonitor.start() {
            didLogMissingPermission = false
            return
        }

        if !didLogMissingPermission {
            AppLogger.log("hotkey monitor unavailable; accessibility permission required")
            didLogMissingPermission = true
        }
    }

    private func startAccessibilityWatch() {
        accessibilityWatchTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.hotKeyMonitor.reenableIfNeeded()
                if self.hotKeyMonitor.eventTap == nil {
                    self.ensureHotKeyMonitorRunning()
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
