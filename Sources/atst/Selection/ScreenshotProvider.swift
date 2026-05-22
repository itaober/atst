import AppKit
import Foundation

struct ScreenshotCapture {
    var imageData: Data
    /// Mouse location at the moment `screencapture -i` exited — typically
    /// the bottom-right corner of the user's drag for a "natural"
    /// left-to-right top-to-bottom selection.
    var anchorPoint: NSPoint
    /// Best-effort reverse-engineered rect of the captured region in
    /// global screen coordinates (top-left origin in our usage). May be
    /// nil if we couldn't decode the image dimensions. When non-nil, the
    /// tooltip can use it to position itself adjacent to the source
    /// instead of just floating off the mouse position.
    var recognisedRect: NSRect?
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

        let mouse = NSEvent.mouseLocation
        let rect = Self.recogniseRect(imageData: data, mouseAtRelease: mouse)
        AppLogger.log("screenshot captured bytes=\(data.count) path=\(fileURL.path) rect=\(rect.map { "\($0)" } ?? "nil")")

        return ScreenshotCapture(
            imageData: data,
            anchorPoint: mouse,
            recognisedRect: rect,
            savedPath: fileURL.path
        )
    }

    /// Reverse-engineer the screenshot region from the saved PNG's
    /// dimensions and the mouse position at release time. macOS users
    /// almost always drag from top-left to bottom-right, so the mouse at
    /// release is the rect's bottom-right corner. We pick the candidate
    /// rect (one for each corner) that fits inside the screen the mouse
    /// is on — this gracefully handles users who drag in non-standard
    /// directions without us having to track the start of the drag.
    private static func recogniseRect(imageData: Data, mouseAtRelease mouse: NSPoint) -> NSRect? {
        guard let image = NSImage(data: imageData) else { return nil }
        let size = image.size  // NSImage exposes size in points for screen-DPI PNGs
        guard size.width > 0, size.height > 0 else { return nil }

        // The screen containing the mouse — clamp candidates against this
        // screen's frame, since screenshots can only come from one screen
        // at a time with `screencapture -i`.
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let screenFrame = screen?.frame else { return nil }

        // Four candidates, one for each possible drag-end corner. Each
        // entry: (corner-the-mouse-is-at → resulting NSRect).
        let candidates: [NSRect] = [
            // Bottom-right (the natural / 99% case)
            NSRect(x: mouse.x - size.width, y: mouse.y,                  width: size.width, height: size.height),
            // Bottom-left
            NSRect(x: mouse.x,              y: mouse.y,                  width: size.width, height: size.height),
            // Top-right
            NSRect(x: mouse.x - size.width, y: mouse.y - size.height,    width: size.width, height: size.height),
            // Top-left
            NSRect(x: mouse.x,              y: mouse.y - size.height,    width: size.width, height: size.height)
        ]

        // Pick the first candidate fully inside the screen.
        for candidate in candidates where screenFrame.contains(candidate) {
            return candidate
        }
        // None fully fit (very large screenshot relative to mouse position
        // near the edge). Pick the one with the largest area inside the
        // screen as the best guess.
        return candidates.max(by: { areaInside(screenFrame, $0) < areaInside(screenFrame, $1) })
    }

    private static func areaInside(_ outer: NSRect, _ inner: NSRect) -> CGFloat {
        let overlap = outer.intersection(inner)
        return overlap.isEmpty ? 0 : overlap.width * overlap.height
    }
}
