import Foundation
import Combine

/// Persists saved commutes in the App Group's UserDefaults so the home-screen
/// widget can read them too.
@MainActor
final class CommuteStore: ObservableObject {
    @Published private(set) var commutes: [Commute] = []

    static let key = "commutes.v1"
    private let key = CommuteStore.key
    private let defaults: UserDefaults

    /// Resolves a stop id to itself + sibling bays. Injected by the app
    /// (StopCatalog-backed); nil in the widget extension, which only reads
    /// already-migrated data.
    static var siblingResolver: ((String) -> [String])?

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        migrateFromStandardIfNeeded()
        load()
        migrateSiblingBaysIfNeeded()
        seedFromEnvironmentIfNeeded()
    }

    /// Legacy commutes matched only the exact bay the user picked, which misses
    /// departures when the route boards at a sibling bay. Resolve once and
    /// persist (also generalize the display name: "… - BAY D" -> facility name).
    private func migrateSiblingBaysIfNeeded() {
        guard let resolve = CommuteStore.siblingResolver,
              commutes.contains(where: { $0.fromCodes == nil }) else { return }
        commutes = commutes.map { c in
            guard c.fromCodes == nil else { return c }
            var upgraded = Commute(routeKey: c.routeKey, fromCode: c.fromCode,
                                   fromName: c.fromName.baseStopName,
                                   toName: c.toName)
            upgraded.fromCodes = resolve(c.fromCode)
            return upgraded
        }
        save()
    }

    /// Commutes used to live in UserDefaults.standard; move them into the shared
    /// container once so existing saves keep working with the widget.
    private func migrateFromStandardIfNeeded() {
        guard defaults !== UserDefaults.standard,
              defaults.data(forKey: key) == nil,
              let legacy = UserDefaults.standard.data(forKey: key) else { return }
        defaults.set(legacy, forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Test hooks: seed a commute from "routeKey|fromCode|fromName|toName"
    /// (persisted only when MARTA_SEED_PERSIST=1), or remove one by fromCode.
    /// No effect on a normal launch.
    private func seedFromEnvironmentIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        if let removeCode = env["MARTA_REMOVE_COMMUTE"] {
            let before = commutes.count
            commutes.removeAll { $0.fromCode == removeCode }
            if commutes.count != before { save() }
        }
        guard let raw = env["MARTA_SEED_COMMUTE"] else { return }
        let f = raw.components(separatedBy: "|")
        guard f.count == 4 else { return }
        let c = Commute(routeKey: f[0], fromCode: f[1], fromName: f[2], toName: f[3])
        if !commutes.contains(c) {
            commutes.append(c)
            if env["MARTA_SEED_PERSIST"] == "1" { save() }
        }
    }

    func commutes(forRoute routeKey: String) -> [Commute] {
        commutes.filter { $0.routeKey == routeKey }
    }

    func add(_ commute: Commute) {
        guard !commutes.contains(commute) else { return }
        commutes.append(commute)
        save()
    }

    func remove(_ commute: Commute) {
        commutes.removeAll { $0 == commute }
        save()
    }

    func remove(atOffsets offsets: IndexSet) {
        commutes.remove(atOffsets: offsets)
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Commute].self, from: data) else { return }
        commutes = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(commutes) {
            defaults.set(data, forKey: key)
        }
    }
}
