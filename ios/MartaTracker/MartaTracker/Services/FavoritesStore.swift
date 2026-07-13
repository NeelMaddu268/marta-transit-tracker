import Foundation
import Combine

/// Persists the user's favorite stops/stations in UserDefaults.
@MainActor
final class FavoritesStore: ObservableObject {
    @Published private(set) var favorites: [Favorite] = []

    private let key = "favorites.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        migrateBayFavoritesIfNeeded()
        seedFromEnvironmentIfNeeded()
    }

    /// One-time upgrade: bay-level bus-stop favorites become their facility
    /// (e.g. "… - BAY D" -> "Windward Park & Ride"), deduped.
    private func migrateBayFavoritesIfNeeded() {
        var changed = false
        var seen = Set<String>()
        var upgraded: [Favorite] = []
        for fav in favorites {
            var out = fav
            if fav.kind == .busStop {
                let group = StopCatalog.shared.groupCode(for: fav.code)
                if group != fav.code {
                    out = Favorite(kind: .busStop, code: group,
                                   name: StopCatalog.shared.name(for: group))
                    changed = true
                }
            }
            if seen.insert(out.id).inserted {
                upgraded.append(out)
            } else {
                changed = true   // duplicate bays collapsed into one facility
            }
        }
        if changed {
            favorites = upgraded
            save()
        }
    }

    /// Test hook: seed rail-station favorites from a semicolon-separated env var
    /// (in-memory, not persisted). No effect on a normal launch.
    private func seedFromEnvironmentIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        for station in (env["MARTA_SEED_FAVORITES"] ?? "").split(separator: ";") {
            let name = String(station)
            let fav = Favorite(kind: .railStation, code: name, name: name.capitalized)
            if !favorites.contains(fav) { favorites.append(fav) }
        }
        for route in (env["MARTA_SEED_FAV_ROUTES"] ?? "").split(separator: ";") {
            let key = String(route)
            let name = RouteCatalog.info(for: key)?.displayName ?? "Route \(key)"
            let fav = Favorite(kind: .route, code: key, name: name)
            if !favorites.contains(fav) { favorites.append(fav) }
        }
    }

    func contains(_ favorite: Favorite) -> Bool {
        favorites.contains(favorite)
    }

    func isFavorited(code: String, kind: FavoriteKind) -> Bool {
        favorites.contains { $0.code == code && $0.kind == kind }
    }

    func add(_ favorite: Favorite) {
        guard !favorites.contains(favorite) else { return }
        favorites.append(favorite)
        save()
    }

    func remove(_ favorite: Favorite) {
        favorites.removeAll { $0 == favorite }
        save()
    }

    func toggle(_ favorite: Favorite) {
        if favorites.contains(favorite) {
            remove(favorite)
        } else {
            add(favorite)
        }
    }

    func remove(atOffsets offsets: IndexSet) {
        favorites.remove(atOffsets: offsets)
        save()
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        favorites.move(fromOffsets: offsets, toOffset: destination)
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Favorite].self, from: data) else { return }
        favorites = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(favorites) {
            defaults.set(data, forKey: key)
        }
    }
}
