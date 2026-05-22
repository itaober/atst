import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var configuration: AppConfiguration
    @Published private(set) var lastSavedAt: Date?

    private static let lastSavedAtKey = "atst.configuration.lastSavedAt"

    init(configuration: AppConfiguration = .load()) {
        self.configuration = configuration
        self.lastSavedAt = Self.loadLastSavedAt()
    }

    func save(_ configuration: AppConfiguration) throws {
        let data = try JSONEncoder().encode(configuration.persistedCopy())
        UserDefaults.standard.set(data, forKey: AppConfiguration.storageKey)
        self.configuration = configuration
        let now = Date()
        UserDefaults.standard.set(now, forKey: Self.lastSavedAtKey)
        lastSavedAt = now
    }

    func reload() {
        configuration = .load()
        lastSavedAt = Self.loadLastSavedAt()
    }

    private static func loadLastSavedAt() -> Date? {
        UserDefaults.standard.object(forKey: lastSavedAtKey) as? Date
    }
}
