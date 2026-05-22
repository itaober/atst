import AppKit
import Foundation

struct ScreenshotCapture {
    var imageData: Data
    var anchorPoint: NSPoint
    /// Path the capture was saved to (for diagnostics). Always
    /// `/tmp/atst-last-screenshot.png` so the user can inspect what was
    /// actually sent to the model.
    var savedPath: String
}

@MainActor
final class ScreenshotProvider {
    /// Stable diagnostic path — overwritten on every capture so the user can
    /// always `open /tmp/atst-last-screenshot.png` to verify what the model
    /// just received.
    static let lastScreenshotPath = "/tmp/atst-last-screenshot.png"

    func captureInteractiveScreenshot() async throws -> ScreenshotCapture {
        let fileURL = URL(fileURLWithPath: Self.lastScreenshotPath)
        try? FileManager.default.removeItem(at: fileURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i: interactive  -r: don't add window shadow  -x: silent  -t png
        process.arguments = ["-i", "-r", "-x", "-t", "png", fileURL.path]

        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: AppError.screenshotCancelled)
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: AppError.screenshotFailed(error.localizedDescription))
            }
        }

        guard
            FileManager.default.fileExists(atPath: fileURL.path),
            let data = try? Data(contentsOf: fileURL),
            !data.isEmpty
        else {
            throw AppError.screenshotCancelled
        }

        AppLogger.log("screenshot captured bytes=\(data.count) path=\(fileURL.path)")

        return ScreenshotCapture(
            imageData: data,
            anchorPoint: NSEvent.mouseLocation,
            savedPath: fileURL.path
        )
    }
}
