import AppKit
import Carbon

@MainActor
final class SelectedTextProvider {
    /// Reads the current selection by simulating ⌘C and snooping the
    /// pasteboard. Assumes Accessibility is already granted —
    /// `AppDelegate.translateSelection` gates on
    /// `PermissionChecker.isAccessibilityTrusted` before invoking this,
    /// so the inner check is unnecessary here.
    func selectedText() async throws -> SelectedText {
        if let text = try await readSelectedTextUsingCopyShortcut() {
            return SelectedText(text: text, anchorRect: nil)
        }
        throw AppError.noSelectedText
    }

    private func readSelectedTextUsingCopyShortcut() async throws -> String? {
        AppLogger.log("selection: capture starting")
        let pasteboard = NSPasteboard.general
        let originalString = pasteboard.string(forType: .string)
        AppLogger.log("selection: snapshot string length=\(originalString?.count ?? -1)")

        let beforeChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        AppLogger.log("selection: pasteboard cleared (changeCount before=\(beforeChangeCount), now=\(pasteboard.changeCount))")
        postCopyShortcut()
        AppLogger.log("selection: Cmd+C posted")

        for attempt in 0..<24 {
            try await Task.sleep(nanoseconds: 50_000_000)
            let currentChange = pasteboard.changeCount
            let raw = pasteboard.string(forType: .string)
            if let text = normalized(raw) {
                AppLogger.log("selection: text captured attempt=\(attempt) length=\(text.count) changeCount=\(currentChange)")
                restoreString(originalString)
                return text
            }
            if attempt % 4 == 0 {
                AppLogger.log("selection: still waiting attempt=\(attempt) changeCount=\(currentChange) rawNil=\(raw == nil)")
            }
        }

        AppLogger.log("selection: timed out, restoring pasteboard")
        restoreString(originalString)
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
