import Foundation

/// A MARTA route/line, keyed by short name (what live vehicles report).
struct RouteInfo: Identifiable, Decodable, Hashable {
    let key: String      // short name: "140", "RED", "ATLSC" — matches vehicle.route
    let short: String
    let long: String
    let type: Int        // GTFS route_type: 0 tram, 1 subway, 3 bus

    var id: String { key }
    var isRail: Bool { type == 0 || type == 1 }

    var displayName: String {
        if isRail { return "\(short.capitalized) Line" }
        return long.isEmpty ? "Route \(short)" : "Route \(short) · \(long)"
    }

    var shortLabel: String { isRail ? short.capitalized : short }
}

/// Route metadata bundled from GTFS: the route list (for search) and each route's
/// per-direction headsign (so bus vehicles can show where they're going).
enum RouteCatalog {
    static let all: [RouteInfo] = {
        guard let url = Bundle.main.url(forResource: "routes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let routes = try? JSONDecoder().decode([RouteInfo].self, from: data)
        else { return [] }
        return routes
    }()

    /// trip_id -> headsign. Loaded lazily (large file) so it isn't parsed unless a
    /// route/vehicle view needs a bus destination. NB: MARTA's realtime feed sets
    /// direction_id to values that don't match static (0/1), so we join on trip_id
    /// (which is reliable) rather than direction.
    static let tripHeadsigns: [String: String] = {
        guard let url = Bundle.main.url(forResource: "trip_headsigns", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }()

    static func info(for key: String) -> RouteInfo? {
        all.first { $0.key == key }
    }

    static func search(_ query: String) -> [RouteInfo] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
        return all.filter { $0.short.searchMatches(query) || $0.long.searchMatches(query) }
    }

    /// Where a bus on this trip is headed, from the static schedule.
    static func headsign(forTrip tripId: String?) -> String? {
        guard let tripId else { return nil }
        return tripHeadsigns[tripId]
    }
}
