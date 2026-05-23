import AppKit
import ApplicationServices
import CoreGraphics

/// Centralises every TCC permission probe / request / "open Settings"
/// jump the rest of the app needs. atst depends on two TCC permissions,
/// each gating a specific feature:
///
///   1. **Accessibility** — selection translation. The `⌘C` keystroke
///      simulation used by `SelectedTextProvider` requires it. Most
///      Chromium / Electron apps don't expose selection via AX API, so
///      pasteboard fallback is the load-bearing path. Also gates the
///      creation of the CGEventTap used by `GlobalHotKeyMonitor`.
///   2. **Screen Recording** — screenshot translation. `screencapture -i`
///      requires it on macOS 10.15+.
///
/// Note: a third TCC class, Input Monitoring, theoretically gates keyboard
/// event delivery to CGEventTaps. In practice, on macOS 13–26 atst's
/// session-level tap has never been blocked by missing Input Monitoring
/// in any observed environment — Accessibility alone is enough. We don't
/// surface Input Monitoring in settings to avoid asking for a perm we
/// can't prove is required. If a real "tap up but no events flowing"
/// case is later traced to IM rather than Secure Keyboard Entry, this
/// is the file to revisit.
enum PermissionChecker {
    // MARK: - Accessibility

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Screen Recording

    static var isScreenRecordingTrusted: Bool {
        if #available(macOS 11.0, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
