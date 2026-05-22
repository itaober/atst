import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let settingsStore: SettingsStore
    private let onTranslateSelection: () -> Void
    private let onTranslateScreenshot: () -> Void
    private let onQuit: () -> Void

    private var panel: NSPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?

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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            // Plain "atst" text in the menu bar — matches our minimalist
            // tooltip feel and avoids guessing an icon.
            button.title = Branding.appName
            button.image = nil
            button.imagePosition = .noImage
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            button.target = self
            button.action = #selector(toggle)
            button.toolTip = Branding.appName
        }
    }

    @objc private func toggle() {
        if let panel, panel.isVisible {
            close()
        } else {
            open()
        }
    }

    /// Public entry point — used by the floating tooltip's "Open Settings"
    /// empty-state CTA so the user can flip a translator on without hunting
    /// for the menu bar.
    func openSettings() {
        if let panel, panel.isVisible { return }
        open()
    }

    private func open() {
        let panel = panel ?? makePanel()
        self.panel = panel

        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }
        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = buttonWindow.convertToScreen(buttonRectInWindow)
        let panelSize = panel.frame.size
        let screen = NSScreen.screens.first(where: { $0.frame.contains(buttonRectOnScreen.origin) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero

        var origin = NSPoint(
            x: buttonRectOnScreen.midX - panelSize.width / 2,
            y: buttonRectOnScreen.minY - panelSize.height - 6
        )
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - panelSize.width - 8))
        origin.y = max(visible.minY + 8, origin.y)

        panel.setFrameOrigin(origin)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startOutsideClickMonitoring()
    }

    private func close() {
        stopOutsideClickMonitoring()
        panel?.orderOut(nil)
    }

    private func startOutsideClickMonitoring() {
        stopOutsideClickMonitoring()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel {
                self.close()
            }
            return event
        }
    }

    private func stopOutsideClickMonitoring() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func makePanel() -> NSPanel {
        let content = MenuBarSettingsView(
            settingsStore: settingsStore,
            onTranslateSelection: { [weak self] in
                self?.close()
                self?.onTranslateSelection()
            },
            onTranslateScreenshot: { [weak self] in
                self?.close()
                self?.onTranslateScreenshot()
            },
            onQuit: onQuit
        )
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize, .intrinsicContentSize]
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = SettingsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 540),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.contentViewController = host
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 14
        panel.contentView?.layer?.cornerCurve = .continuous
        panel.contentView?.layer?.masksToBounds = true
        panel.isReleasedWhenClosed = false
        return panel
    }

}

/// Borderless / nonactivating panels don't accept first responder by default,
/// which makes text fields and toggles inside look dimmed and uneditable.
/// Overriding `canBecomeKey` to true lets controls receive focus while we
/// keep the panel out of the app activation list (no dock/app-menu takeover).
private final class SettingsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
