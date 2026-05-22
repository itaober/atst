import Foundation

enum AppLogger {
    private static let logURL = URL(fileURLWithPath: "/tmp/atst.log")
    private static let rotatedURL = URL(fileURLWithPath: "/tmp/atst.old.log")
    private static let queue = DispatchQueue(label: "dev.local.atst.logger")
    /// Roll the log file once it crosses ~1 MB; the previous tail moves to
    /// `atst.old.log` so a recent session is still retrievable.
    private static let maxBytes: UInt64 = 1_000_000
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else {
            return
        }

        queue.async {
            rotateIfNeeded()
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    /// Must be called on `queue` so the size check and rotation are
    /// serialised with writes.
    private static func rotateIfNeeded() {
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
            let size = attrs[.size] as? UInt64,
            size > maxBytes
        else {
            return
        }
        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: logURL, to: rotatedURL)
    }
}
