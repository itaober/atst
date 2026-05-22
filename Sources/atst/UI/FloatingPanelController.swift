import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class FloatingPanelController {
    private let viewModel: TranslatorViewModel
    private let onRefresh: (String) -> Void
    private let onOpenSettings: () -> Void

    private lazy var hostingController: NSHostingController<TranslationResultView> = makeHostingController()
    private lazy var panel: NSPanel = makePanel()
    private var pinObserver: AnyCancellable?
    private var lastTopLeft: NSPoint?
    private var spaceChangeObserver: NSObjectProtocol?
    private var outsideClickGlobalMonitor: Any?
    private var outsideClickLocalMonitor: Any?
    private var escKeyLocalMonitor: Any?
    private var lastAppliedContentSize: NSSize?

    /// Independent panels created when the user pins a translation. Each is
    /// frozen at the time of pinning and lives until its own × is clicked.
    private var noteControllers: [PinnedNoteController] = []

    init(
        viewModel: TranslatorViewModel,
        onRefresh: @escaping (String) -> Void = { _ in },
        onOpenSettings: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.onRefresh = onRefresh
        self.onOpenSettings = onOpenSettings
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.close()
            }
        }
    }

    deinit {
        if let spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceChangeObserver)
        }
    }

    func show(anchor: FloatingPanelAnchor = .mouse, activate: Bool = true) {
        ensureSized()

        let topLeft = topLeftPoint(for: anchor, size: panel.frame.size)
        lastTopLeft = topLeft

        if !panel.isVisible {
            panel.alphaValue = 0
        }
        panel.setFrameTopLeftPoint(topLeft)

        if activate {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            panel.orderFrontRegardless()
        }

        if panel.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }

        startDismissalMonitors()
        observePinState()
    }

    func close() {
        pinObserver = nil
        lastTopLeft = nil
        stopDismissalMonitors()
        viewModel.pinned = false
        panel.orderOut(nil)
    }

    // MARK: - Pin handling

    private func observePinState() {
        guard pinObserver == nil else { return }
        pinObserver = viewModel.$pinned
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] pinned in
                guard let self else { return }
                if pinned {
                    self.detachAsNote()
                }
            }
    }

    /// Snapshot the currently visible translation, spawn an independent
    /// pinned-note panel at the same screen position, then close the active
    /// tooltip so the next translation starts in a fresh one.
    private func detachAsNote() {
        guard panel.isVisible else {
            viewModel.pinned = false
            return
        }

        guard let snapshot = makePinnedSnapshot() else {
            viewModel.pinned = false
            return
        }

        let originTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        let note = PinnedNoteController(snapshot: snapshot)
        note.onUserClose = { [weak self, weak note] in
            guard let self, let note else { return }
            self.noteControllers.removeAll { $0 === note }
        }
        noteControllers.append(note)
        note.show(at: originTopLeft)

        close()
    }

    /// Capture the current dual-segment state into a `PinnedNoteSnapshot`.
    /// Returns nil when there's nothing meaningful to pin (still loading /
    /// no content / screenshot mode without items).
    private func makePinnedSnapshot() -> PinnedNoteSnapshot? {
        switch viewModel.state {
        case .text(let segments):
            guard segments.hasAnyContent else { return nil }
            // Pinned notes mirror the live tooltip's auto-expand rule for
            // untranslatable inputs: the <atst-desc> block becomes the
            // useful payload, so we should pop it open even if the user's
            // general "expand by default" preference is off.
            let aiOutput = segments.ai?.state.output
            let autoExpand = (aiOutput?.untranslatable ?? false)
                && viewModel.configuration.smartExplanationEnabled
                && (aiOutput?.hasDescription ?? false)
            let initiallyExpanded = autoExpand
                ? true
                : viewModel.configuration.smartExplanationExpandedByDefault
            return PinnedNoteSnapshot(
                sourceText: segments.source,
                apiSegments: segments.api,
                aiSegment: segments.ai,
                phoneticEnabled: viewModel.configuration.phoneticEnabled,
                smartExplanationEnabled: viewModel.configuration.smartExplanationEnabled,
                initiallyExpanded: initiallyExpanded
            )
        case .screenshotSuccess(let output, let source, let model),
             .screenshotStreaming(_, let output, let model, let source):
            guard !output.items.isEmpty else { return nil }
            // Screenshot pins reuse the dual-section data shape but with
            // only an AI segment (no API providers ever run on screenshots).
            let ai = ProviderSegment(
                id: .ai,
                displayName: model,
                modelHint: model,
                state: .success(output: output, latencyMs: nil, fromCache: false, cacheInfo: nil)
            )
            return PinnedNoteSnapshot(
                sourceText: source,
                apiSegments: [],
                aiSegment: ai,
                phoneticEnabled: viewModel.configuration.phoneticEnabled,
                smartExplanationEnabled: viewModel.configuration.smartExplanationEnabled,
                initiallyExpanded: viewModel.configuration.smartExplanationExpandedByDefault
            )
        case .idle, .screenshotLoading, .failure:
            return nil
        }
    }

    // MARK: - Dismissal monitors

    private func startDismissalMonitors() {
        stopDismissalMonitors()
        outsideClickGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        outsideClickLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window === self.panel { return event }
            if self.noteControllers.contains(where: { $0.owns(event.window) }) { return event }
            self.close()
            return event
        }
        escKeyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, event.window === self?.panel {
                self?.close()
                return nil
            }
            return event
        }
    }

    private func stopDismissalMonitors() {
        [outsideClickGlobalMonitor, outsideClickLocalMonitor, escKeyLocalMonitor].forEach {
            if let m = $0 { NSEvent.removeMonitor(m) }
        }
        outsideClickGlobalMonitor = nil
        outsideClickLocalMonitor = nil
        escKeyLocalMonitor = nil
    }

    // MARK: - Sizing

    private func ensureSized() {
        hostingController.view.layoutSubtreeIfNeeded()
        let fitting = hostingController.view.fittingSize
        guard fitting.width > 1, fitting.height > 1 else { return }
        resizePanel(to: fitting)
    }

    private func handleContentSizeChange(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        resizePanel(to: NSSize(width: size.width, height: size.height))
    }

    private func resizePanel(to newSize: NSSize) {
        guard newSize.width > 1, newSize.height > 1 else { return }
        if let last = lastAppliedContentSize,
           abs(last.width - newSize.width) < 0.25,
           abs(last.height - newSize.height) < 0.25 {
            return
        }
        lastAppliedContentSize = newSize
        panel.setContentSize(newSize)
    }

    private func makeHostingController() -> NSHostingController<TranslationResultView> {
        let view = TranslationResultView(
            viewModel: viewModel,
            onClose: { [weak self] in self?.close() },
            onContentSizeChange: { [weak self] size in
                self?.handleContentSizeChange(size)
            },
            onRefresh: { [weak self] sourceText in
                self?.onRefresh(sourceText)
            },
            onOpenSettings: { [weak self] in
                self?.close()
                self?.onOpenSettings()
            }
        )
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = []
        controller.view.wantsLayer = true
        controller.view.layer?.backgroundColor = NSColor.clear.cgColor
        return controller
    }

    private func makePanel() -> NSPanel {
        let panel = TooltipPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = Branding.appName
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.contentViewController = hostingController
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.isReleasedWhenClosed = false
        // Movable + nonactivating: the user can drag the panel via the
        // header strip (see `WindowDragHandle`) without stealing app focus
        // from whatever they were translating from. `isMovableByWindowBackground`
        // stays off so dragging the translation body doesn't kidnap text
        // selection.
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        return panel
    }

    /// Smart placement: convert the anchor to a rect, then try candidate
    /// positions (right → below → above → left) and pick the first one
    /// that fully fits the screen's visible area. Falls back to the
    /// largest-area-clamped position when none fully fit (e.g. a huge
    /// tooltip on a small external display).
    ///
    /// This replaces the previous "just offset from the anchor point and
    /// clamp" logic, which often pushed the tooltip away from the source
    /// when the source was near the screen edge.
    private func topLeftPoint(for anchor: FloatingPanelAnchor, size: NSSize) -> NSPoint {
        let anchorRect = self.anchorRect(for: anchor)
        let probe = NSPoint(x: anchorRect.midX, y: anchorRect.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(probe) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let candidates = candidatePositions(anchor: anchorRect, size: size)
        for candidate in candidates where fitsInside(topLeft: candidate, size: size, frame: visible) {
            return candidate
        }
        // Nothing fits cleanly — pick whichever candidate maximises on-screen
        // area and clamp it to keep at least an edge visible.
        let best = candidates.max(by: { onScreenArea(topLeft: $0, size: size, frame: visible) < onScreenArea(topLeft: $1, size: size, frame: visible) }) ?? candidates[0]
        return clamp(topLeft: best, size: size, frame: visible)
    }

    private func anchorRect(for anchor: FloatingPanelAnchor) -> NSRect {
        switch anchor {
        case .mouse:
            let p = NSEvent.mouseLocation
            return NSRect(x: p.x, y: p.y, width: 1, height: 1)
        case .point(let p):
            return NSRect(x: p.x, y: p.y, width: 1, height: 1)
        case .rect(let r):
            return r
        }
    }

    private func candidatePositions(anchor: NSRect, size: NSSize) -> [NSPoint] {
        let gap: CGFloat = 8
        // Position the panel's top-left such that the panel sits on each side
        // of the anchor with `gap` spacing. macOS y axis points up, so:
        //   - top-of-panel = topLeft.y
        //   - bottom-of-panel = topLeft.y - size.height
        return [
            // Right of anchor, aligned to anchor's top edge
            NSPoint(x: anchor.maxX + gap, y: anchor.maxY),
            // Below anchor, aligned to anchor's left edge
            NSPoint(x: anchor.minX,       y: anchor.minY - gap),
            // Above anchor, aligned to anchor's left edge
            NSPoint(x: anchor.minX,       y: anchor.maxY + size.height + gap),
            // Left of anchor, aligned to anchor's top edge
            NSPoint(x: anchor.minX - size.width - gap, y: anchor.maxY)
        ]
    }

    private func fitsInside(topLeft: NSPoint, size: NSSize, frame: NSRect) -> Bool {
        let panelRect = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        return frame.contains(panelRect)
    }

    private func onScreenArea(topLeft: NSPoint, size: NSSize, frame: NSRect) -> CGFloat {
        let panelRect = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        let overlap = frame.intersection(panelRect)
        return overlap.isEmpty ? 0 : overlap.width * overlap.height
    }

    private func clamp(topLeft: NSPoint, size: NSSize, frame: NSRect) -> NSPoint {
        let minX = frame.minX + 8
        let maxX = frame.maxX - size.width - 8
        let minTop = frame.minY + size.height + 8
        let maxTop = frame.maxY - 8
        let x = min(max(topLeft.x, minX), max(minX, maxX))
        let y = min(max(topLeft.y, minTop), max(minTop, maxTop))
        return NSPoint(x: x, y: y)
    }
}

enum FloatingPanelAnchor {
    case mouse
    case point(NSPoint)
    case rect(NSRect)
}

/// The expand / collapse animation is owned entirely by SwiftUI. AppKit just
/// follows instantly with a top-left anchor — no AppKit animation clock to
/// fight against. Result: one driver, smooth drawer feel.
private final class TooltipPanel: NSPanel {
    override func setContentSize(_ newSize: NSSize) {
        let currentFrame = frame
        let topLeftY = currentFrame.maxY
        let newFrame = NSRect(
            x: currentFrame.minX,
            y: topLeftY - newSize.height,
            width: newSize.width,
            height: newSize.height
        )
        if newFrame == currentFrame { return }
        setFrame(newFrame, display: true, animate: false)
    }
}

// MARK: - Pinned note window

@MainActor
private final class PinnedNoteController {
    private let snapshot: PinnedNoteSnapshot
    private let panel: NSPanel
    private let hostingController: NSHostingController<PinnedNoteView>

    var onUserClose: (() -> Void)?

    init(snapshot: PinnedNoteSnapshot) {
        self.snapshot = snapshot
        var dismissAction: () -> Void = {}
        let view = PinnedNoteView(snapshot: snapshot) {
            dismissAction()
        }
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize, .intrinsicContentSize]
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        self.hostingController = host

        let panel = TooltipPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "\(Branding.appName) note"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.contentViewController = host
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.isReleasedWhenClosed = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        self.panel = panel

        dismissAction = { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.onUserClose?()
        }
    }

    func owns(_ window: NSWindow?) -> Bool { window === panel }

    func show(at topLeft: NSPoint) {
        hostingController.view.layoutSubtreeIfNeeded()
        let fitting = hostingController.view.fittingSize
        let size = (fitting.width > 1 && fitting.height > 1) ? fitting : panel.frame.size
        let frame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }
}
