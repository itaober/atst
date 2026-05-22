import Foundation

/// Single source of truth for the app's brand strings. Lets us swap
/// the visible name in one place if we ever rename, and keeps the
/// dozens of stringly-typed references in code consistent.
enum Branding {
    static let appName = "atst"
    static let bundleIdentifier = "dev.local.atst"
}
