import Foundation

/// The MARTA rail stations (name + coordinates), loaded from the bundled
/// stations.json generated from GTFS. Used as trip-plan origins/destinations.
struct Station: Identifiable, Hashable, Decodable {
    let name: String
    let lat: Double
    let lon: Double
    var id: String { name }
}

enum StationCatalog {
    static let all: [Station] = {
        guard let url = Bundle.main.url(forResource: "stations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let stations = try? JSONDecoder().decode([Station].self, from: data)
        else { return [] }
        return stations.sorted { $0.name < $1.name }
    }()

    /// Rail stations only. `all` also carries park-and-ride parent facilities
    /// (useful as trip origins); every MARTA rail station is named "… Station",
    /// so this filter keeps P&Rs out of rail-flavored UI (search, nearby).
    static let railStations: [Station] = all.filter {
        $0.name.localizedCaseInsensitiveContains("station")
    }

    static func search(_ query: String) -> [Station] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
        return all.filter { $0.name.searchMatches(query) }
    }
}
