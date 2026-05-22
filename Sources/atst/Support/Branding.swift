import Foundation

/// Single source of truth for the app's brand strings. Lets us swap
/// the visible name in one place if we ever rename, and keeps the
/// dozens of stringly-typed references in code consistent.
enum Branding {
    static let appName = "atst"
    static let bundleIdentifier = "dev.local.atst"

    /// GitHub repo path used for the update-check API call and as a
    /// destination for the "open release page" deep link.
    static let githubRepoPath = "itaober/atst"

    /// Human-readable version string for display in the settings header
    /// and elsewhere.
    ///
    /// Reads `CFBundleShortVersionString` from `Info.plist`. Release
    /// builds get a real semver written by `Scripts/build-app.sh` (e.g.
    /// "0.1.3"); local `swift run` builds have no Info.plist at all and
    /// `build-app.sh` defaults to literal "dev" when no version is
    /// passed. We normalise both to a single "dev" sentinel for the UI.
    static var versionDisplay: String {
        guard let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              !raw.isEmpty,
              raw != "dev",
              raw.first?.isNumber == true else {
            return "dev"
        }
        return "v\(raw)"
    }

    /// Returns the semver portion only ("0.1.3"), or nil for dev builds.
    /// Used by the update checker to compare against GitHub tags.
    static var releaseVersion: String? {
        guard let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              !raw.isEmpty,
              raw != "dev",
              raw.first?.isNumber == true else {
            return nil
        }
        return raw
    }

    /// Release page URL for the current version (or the latest releases
    /// list when this is a dev build).
    static var currentReleaseURL: URL {
        if let v = releaseVersion {
            return URL(string: "https://github.com/\(githubRepoPath)/releases/tag/v\(v)")!
        }
        return URL(string: "https://github.com/\(githubRepoPath)/releases")!
    }
}
