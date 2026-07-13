import Foundation
import CoreLocation

/// Resolves bus stop_id -> human-readable stop name from the bundled GTFS static
/// stops.txt. Loaded lazily once; falls back to the raw id if unavailable.
final class StopCatalog {
    static let shared = StopCatalog()

    private var namesById: [String: String] = [:]
    private var coordsById: [String: (lat: Double, lon: Double)] = [:]
    /// GTFS parent_station links: bay/child stop -> facility, and the reverse.
    private var parentById: [String: String] = [:]
    private var childrenByParent: [String: [String]] = [:]
    private var loaded = false
    private let loadLock = NSLock()   // loads may race (preload vs first UI use)

    private init() {}

    func name(for stopId: String) -> String {
        loadIfNeeded()
        return namesById[stopId] ?? stopId
    }

    func coordinate(for stopId: String) -> CLLocationCoordinate2D? {
        loadIfNeeded()
        guard let c = coordsById[stopId] else { return nil }
        return CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon)
    }

    // MARK: - Facility grouping
    // Riders think in facilities ("Windward Park & Ride"), not bays; each route
    // direction boards at a specific bay. So the app groups stops by GTFS
    // parent_station (with a same-base-name fallback) and shows the bay as an
    // attribute of each departure.

    /// The code the app should treat as this stop's identity: its facility's
    /// parent id when it has one, else itself.
    func groupCode(for stopId: String) -> String {
        loadIfNeeded()
        return parentById[stopId] ?? stopId
    }

    /// All boardable stop ids behind a code: a parent expands to its bays, a
    /// leaf expands to itself + same-named siblings.
    func members(of code: String) -> [String] {
        loadIfNeeded()
        var ids = Set([code])
        if let children = childrenByParent[code] {
            ids.formUnion(children)
        }
        if let parent = parentById[code] {
            ids.insert(parent)
            ids.formUnion(childrenByParent[parent] ?? [])
        }
        // Name-based fallback for facilities without parent records.
        if let name = namesById[code] {
            let base = name.baseStopName.lowercased()
            if base != name.lowercased() || ids.count == 1 {
                for (id, n) in namesById where n.baseStopName.lowercased() == base {
                    ids.insert(id)
                }
            }
        }
        return ids.sorted()
    }

    /// Bay label for a stop within its facility ("Bay C"), nil when the stop
    /// isn't a distinct bay.
    func bayLabel(for stopId: String) -> String? {
        loadIfNeeded()
        guard let name = namesById[stopId] else { return nil }
        let base = name.baseStopName
        guard base.count < name.count else { return nil }
        let suffix = name.dropFirst(base.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -"))
        return suffix.isEmpty ? nil : suffix.capitalized
    }

    /// The stop plus its sibling bays (commute matching). Kept as the members
    /// expansion so saved commutes cover whichever bay the route boards at.
    func siblingStopIds(of stopId: String) -> [String] {
        members(of: stopId)
    }

    /// Closest stops, collapsed by facility (one row per park-and-ride/station,
    /// at its nearest member's distance).
    func nearest(to coordinate: CLLocationCoordinate2D, limit: Int = 15)
        -> [(id: String, name: String, meters: Double)] {
        loadIfNeeded()
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var best: [String: (name: String, meters: Double)] = [:]
        for (id, c) in coordsById {
            let d = here.distance(from: CLLocation(latitude: c.lat, longitude: c.lon))
            let group = parentById[id] ?? id
            let display = namesById[group] ?? namesById[id] ?? id
            if let existing = best[group], existing.meters <= d { continue }
            best[group] = (display, d)
        }
        return best
            .map { (id: $0.key, name: $0.value.name, meters: $0.value.meters) }
            .sorted { $0.meters < $1.meters }
            .prefix(limit)
            .map { $0 }
    }

    /// Case-insensitive search over stop names, collapsed by facility: matching
    /// bays fold into one row for their park-and-ride/station. Returns
    /// (code, display name) pairs, name-sorted, capped at `limit`.
    func search(_ query: String, limit: Int = 40) -> [(id: String, name: String)] {
        loadIfNeeded()
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var byGroup: [String: String] = [:]
        for (id, name) in namesById where name.searchMatches(query) {
            let group = parentById[id] ?? id
            byGroup[group] = namesById[group] ?? name
            if byGroup.count >= limit * 4 { break }   // gather then sort/trim
        }
        return byGroup
            .map { (id: $0.key, name: $0.value) }
            .sorted { $0.name < $1.name }
            .prefix(limit)
            .map { $0 }
    }

    private func loadIfNeeded() {
        loadLock.lock()
        defer { loadLock.unlock() }
        // The dictionaries are only mutated here, under the lock; afterwards
        // they're read-only, so unlocked reads by callers are safe.
        guard !loaded else { return }
        loaded = true
        guard let url = Bundle.main.url(forResource: "stops", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        // Split on any newline. NB: the GTFS file is CRLF, and Swift treats "\r\n"
        // as a single Character grapheme, so split(separator: "\n") would find no
        // separator and return the whole file as one line. isNewline handles it.
        var lines = text.split(whereSeparator: \.isNewline).makeIterator()
        guard let header = lines.next() else { return }
        let columns = parseCSVLine(String(header))
        guard let idIdx = columns.firstIndex(of: "stop_id"),
              let nameIdx = columns.firstIndex(of: "stop_name") else { return }
        let latIdx = columns.firstIndex(of: "stop_lat")
        let lonIdx = columns.firstIndex(of: "stop_lon")
        let parentIdx = columns.firstIndex(of: "parent_station")
        while let line = lines.next() {
            let fields = parseCSVLine(String(line))
            guard fields.count > max(idIdx, nameIdx) else { continue }
            let id = fields[idIdx]
            namesById[id] = fields[nameIdx]
            if let latIdx, let lonIdx, fields.count > max(latIdx, lonIdx),
               let lat = Double(fields[latIdx]), let lon = Double(fields[lonIdx]) {
                coordsById[id] = (lat, lon)
            }
            if let parentIdx, fields.count > parentIdx {
                let parent = fields[parentIdx]
                if !parent.isEmpty, parent != id {
                    parentById[id] = parent
                    childrenByParent[parent, default: []].append(id)
                }
            }
        }
    }

    /// Minimal CSV field splitter that respects double-quoted fields.
    private func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        while let ch = iterator.next() {
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        fields.append(current)
        return fields.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
