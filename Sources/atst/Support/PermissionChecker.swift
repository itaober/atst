import AppKit
import ApplicationServices
import CoreGraphics

enum PermissionChecker {
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    static var isScreenRecordingTrusted: Bool {
        if #available(macOS 11.0, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }

    @discardableResult
    static func requestScreenRecording() -> Bool {
        if #available(macOS 11.0, *) {
            return CGRequestScreenCaptureAccess()
        }
        return true
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
