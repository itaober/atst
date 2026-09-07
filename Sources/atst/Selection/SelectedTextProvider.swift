import AppKit
import ApplicationServices
import Carbon

@MainActor
final class SelectedTextProvider {
    /// Reads the current selection: the Accessibility API first (instant,
    /// leaves the pasteboard alone), then simulated ⌘C + pasteboard
    /// snooping. Assumes Accessibility is already granted —
    /// `AppDelegate.translateSelection` gates on
    /// `PermissionChecker.isAccessibilityTrusted` before invoking this.
    func selectedText() async throws -> SelectedText {
        if let text = readSelectedTextViaAccessibility() {
            AppLogger.log("selection: AX path length=\(text.count)")
            return SelectedText(text: text, anchorRect: nil)
        }
        if let text = try await readSelectedTextUsingCopyShortcut() {
            return SelectedText(text: text, anchorRect: nil)
        }
        throw AppError.noSelectedText
    }

    /// Ask the frontmost app's focused element for its selection. Many
    /// Chromium / Electron apps answer with nothing even when text is
    /// selected, so an empty result only means "fall back to ⌘C" — it is
    /// never evidence that nothing is selected.
    private func readSelectedTextViaAccessibility() -> String? {
        var focused: CFTypeRef?
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return nil }
        let element = focused as! AXUIElement
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success else {
            return nil
        }
        return normalized(value as? String)
    }

    private func readSelectedTextUsingCopyShortcut() async throws -> String? {
        AppLogger.log("selection: capture starting")
        let pasteboard = NSPasteboard.general
        let originalString = pasteboard.string(forType: .string)
        AppLogger.log("selection: snapshot string length=\(originalString?.count ?? -1)")

        // Guarantee the user's clipboard is restored regardless of how this
        // function exits — success, timeout, or `Task.sleep` throwing
        // `CancellationError` because the user re-triggered the hotkey
        // mid-flight. Without this guard a cancelled invocation would leak
        // an empty (or partially-overwritten-by-Cmd+C) pasteboard.
        defer { restoreString(originalString) }

        let beforeChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        AppLogger.log("selection: pasteboard cleared (changeCount before=\(beforeChangeCount), now=\(pasteboard.changeCount))")
        postCopyShortcut()
        AppLogger.log("selection: Cmd+C posted")

        // 600 ms cap. Apps that do respond to ⌘C land within ~100–300 ms
        // even when slow (Electron); the rest of the wait was only ever
        // paid in the no-selection case, where it delays the input box.
        for attempt in 0..<12 {
            try await Task.sleep(nanoseconds: 50_000_000)
            let currentChange = pasteboard.changeCount
            let raw = pasteboard.string(forType: .string)
            if let text = normalized(raw) {
                AppLogger.log("selection: text captured attempt=\(attempt) length=\(text.count) changeCount=\(currentChange)")
                return text
            }
            if attempt % 4 == 0 {
                AppLogger.log("selection: still waiting attempt=\(attempt) changeCount=\(currentChange) rawNil=\(raw == nil)")
            }
        }

        AppLogger.log("selection: timed out, restoring pasteboard")
        return nil
    }

    private func restoreString(_ string: String?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let string {
            pasteboard.setString(string, forType: .string)
        }
    }

    private func postCopyShortcut() {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false) else {
            AppLogger.log("selection: failed to create Cmd+C events")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func normalized(_ text: String?) -> String? {
        guard let text else {
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct SelectedText {
    var text: String
    var anchorRect: NSRect?
}
