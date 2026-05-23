import Foundation

/// Background "is a newer release available on GitHub?" probe.
///
/// Hits the public Releases API once on app launch (and on demand when
/// the user opens settings if the cached result is stale). The result is
/// surfaced through `@Published latest` so the settings header can
/// render either the current version or a small "new version available"
/// hint depending on outcome.
///
/// Privacy / cost:
///   - One HTTP GET to api.github.com per check, no auth, no body.
///   - No user data leaves the machine.
///   - GitHub's unauthenticated rate limit (60/hr per IP) is far more
///     than we'll ever hit.
@MainActor
final class UpdateChecker: ObservableObject {
    /// Snapshot of the most recent GitHub release fetch. `nil` until the
    /// first successful call.
    @Published private(set) var latest: ReleaseInfo?

    struct ReleaseInfo: Equatable {
        let version: String      // e.g. "0.1.4" (no leading "v")
        let tagName: String      // e.g. "v0.1.4" (raw from GitHub)
        let publishedAt: Date?
        let htmlURL: URL
    }

    /// Skip a network round-trip if we successfully checked within this
    /// window. Keeps app launch + repeated settings-open cheap.
    private let cacheTTL: TimeInterval = 4 * 60 * 60  // 4 hours
    private var lastCheckedAt: Date?

    private let session = URLSession.shared
    private lazy var apiURL = URL(string: "https://api.github.com/repos/\(Branding.githubRepoPath)/releases/latest")!

    /// Fire-and-forget. Caller doesn't await; UI listens to `@Published latest`.
    /// Respects the cache TTL — calling this on every settings-open is cheap.
    func checkInBackground() {
        if let last = lastCheckedAt,
           Date().timeIntervalSince(last) < cacheTTL,
           latest != nil {
            return
        }
        Task { [weak self] in await self?.performCheck() }
    }

    /// Whether the latest release is newer than the running build.
    /// `false` for dev builds (we can't reliably compare "dev" to
    /// anything) and when the API call hasn't completed yet.
    var hasUpdate: Bool {
        guard let local = Branding.releaseVersion,
              let latest else { return false }
        return Self.isNewer(latest.version, than: local)
    }

    private func performCheck() async {
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                AppLogger.log("update check: invalid response")
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                AppLogger.log("update check: HTTP \(http.statusCode)")
                return
            }

            let json = try JSONSerialization.jsonObject(with: data, options: [])
            guard let dict = json as? [String: Any],
                  let tagName = dict["tag_name"] as? String,
                  let urlString = dict["html_url"] as? String,
                  let url = URL(string: urlString) else {
                AppLogger.log("update check: unexpected response shape")
                return
            }
            let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let publishedAt = (dict["published_at"] as? String).flatMap(Self.isoFormatter.date(from:))

            latest = ReleaseInfo(
                version: version,
                tagName: tagName,
                publishedAt: publishedAt,
                htmlURL: url
            )
            lastCheckedAt = Date()
            AppLogger.log("update check: latest=\(version) local=\(Branding.releaseVersion ?? "dev") hasUpdate=\(hasUpdate)")
        } catch {
            AppLogger.log("update check failed: \(error)")
        }
    }

    /// Lexicographic semver comparison good enough for our purposes —
    /// breaks each version into its `.`-separated numeric components and
    /// compares element by element. `"0.2.0"` is newer than `"0.1.9"`,
    /// `"1.0.0"` is newer than `"0.99.0"`, etc. Falls back to string
    /// compare if either side has non-numeric pieces.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let localParts = local.split(separator: ".").compactMap { Int($0) }
        // Defensive: if either parse failed (e.g. "1.0.0-beta"), fall
        // back to a simple string compare. Reliable enough for our
        // numeric-only releases.
        guard remoteParts.count == remote.split(separator: ".").count,
              localParts.count == local.split(separator: ".").count else {
            return remote > local
        }
        let pad = max(remoteParts.count, localParts.count)
        let r = remoteParts + Array(repeating: 0, count: pad - remoteParts.count)
        let l = localParts  + Array(repeating: 0, count: pad - localParts.count)
        for (a, b) in zip(r, l) where a != b { return a > b }
        return false  // equal
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
