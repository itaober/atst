import AppKit
import ApplicationServices
import Combine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore = SettingsStore()
    private let updateChecker = UpdateChecker()
    private lazy var viewModel = TranslatorViewModel(settingsStore: settingsStore)
    private lazy var panelController: FloatingPanelController = FloatingPanelController(
        viewModel: viewModel,
        onRefresh: { [weak self] sourceText in
            self?.translateText(sourceText, bypassCache: true)
        },
        onOpenSettings: { [weak self] in
            self?.statusBarController.openSettings()
        },
        onSubmitInput: { [weak self] text in
            self?.translateText(text, bypassCache: false)
        }
    )
    private lazy var statusBarController: StatusBarController = StatusBarController(
        settingsStore: settingsStore,
        updateChecker: updateChecker,
        onOpenInput: { [weak self] in
            self?.panelController.showInput(anchor: .mouse)
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
        L.override = settingsStore.configuration.uiLanguage
        applyAppearance(settingsStore.configuration.appearanceMode)
        configureMainMenu()
        _ = statusBarController
        configureHotKeys(settingsStore.configuration)
        hotKeyMonitor.onEscape = { [weak self] in
            self?.panelController.closeIfVisible() ?? false
        }
        hotKeyMonitor.onModifierDown = { [weak self] in
            self?.prewarmOnModifier()
        }
        ensureHotKeyMonitorRunning()
        promptForAccessibilityIfNeeded()
        startAccessibilityWatch()
        AppLogger.log("permissions snapshot ax=\(PermissionChecker.isAccessibilityTrusted) screen=\(PermissionChecker.isScreenRecordingTrusted)")
        prewarmAllProviders(settingsStore.configuration)
        applyCacheSettings(settingsStore.configuration)
        applyLaunchAtLogin(settingsStore.configuration.launchAtLogin)
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
                self?.applyLaunchAtLogin(configuration.launchAtLogin)
                self?.prewarmAllProviders(configuration)
            }
            .store(in: &cancellables)
    }

    /// Sync the login-item registration with the setting. Idempotent: only
    /// touches SMAppService when the desired state differs from the current
    /// one, so every unrelated settings save doesn't hit the service.
    private func applyLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        let registered = service.status == .enabled || service.status == .requiresApproval
        guard enabled != registered else { return }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            AppLogger.log("launch at login \(enabled ? "registered" : "unregistered") status=\(service.status.rawValue)")
        } catch {
            // Expected for `swift run` builds (no bundle to register).
            AppLogger.log("launch at login \(enabled ? "register" : "unregister") failed: \(error)")
        }
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
        lastPrewarmAt = Date()
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

    private var lastPrewarmAt: Date = .distantPast

    /// Pressing the hotkey's modifier is the last moment before a
    /// translation, so warm the pooled connections right there. Throttled
    /// because ⌥ is also just a typing key; two minutes stays under typical
    /// server idle timeouts. Replaces a permanent 4-minute timer that kept
    /// pinging Google / Microsoft / the AI endpoint while the Mac sat idle.
    private func prewarmOnModifier() {
        guard Date().timeIntervalSince(lastPrewarmAt) > 120 else { return }
        prewarmAllProviders(settingsStore.configuration)
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
                TranslationStats.shared.recordTranslation()
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
                if case AppError.noSelectedText = error {
                    // Nothing selected — offer the manual editor instead
                    // of a dead-end error.
                    self.panelController.showInput(anchor: .mouse)
                    return
                }
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
                TranslationStats.shared.recordTranslation()
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

    /// Translate text we already hold — the header refresh (bypassing the
    /// cache) and the manual-entry editor. The panel is already on screen
    /// in both cases, so no pasteboard capture and no repositioning.
    private func translateText(_ text: String, bypassCache: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        AppLogger.log("translateText invoked length=\(trimmed.count) bypassCache=\(bypassCache)")
        currentTranslationTask?.cancel()
        currentScreenshotTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            TranslationStats.shared.recordTranslation()
            let selection = SelectedText(text: trimmed, anchorRect: nil)
            self.viewModel.beginTextTranslation(source: trimmed)
            await self.viewModel.translateSelection(selection, bypassCache: bypassCache)
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

    /// The hotkey tap can't start without Accessibility, so a fresh install
    /// would otherwise ignore ⌥D in complete silence. Prompt once per app
    /// version: ad-hoc signatures change on every build and macOS drops the
    /// grant with them, so an upgrade needs the nudge again while a user
    /// who declined isn't nagged on every launch. Settings opens alongside
    /// so the permission rows are in view.
    private func promptForAccessibilityIfNeeded() {
        guard !PermissionChecker.isAccessibilityTrusted else { return }
        let key = "atst.accessibilityPromptedVersion"
        let version = Branding.versionDisplay
        guard UserDefaults.standard.string(forKey: key) != version else { return }
        UserDefaults.standard.set(version, forKey: key)
        AppLogger.log("accessibility missing on launch, prompting (version=\(version))")
        PermissionChecker.requestAccessibility()
        statusBarController.openSettings()
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
