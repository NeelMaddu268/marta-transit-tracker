import Foundation
import Combine

/// Orchestrates both feeds for the UI. Fetches bus + rail concurrently on a
/// timer, publishes a merged vehicle list, and can build the arrivals list for
/// a tapped vehicle. Each feed is fetched independently so one failing doesn't
/// blank out the other.
@MainActor
final class MartaService: ObservableObject {
    @Published private(set) var vehicles: [Vehicle] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date?
    @Published var errorMessage: String?

    /// How often to refresh, seconds. MARTA's feeds republish roughly every
    /// 10-15s, so polling faster than this only re-reads identical data.
    var refreshInterval: TimeInterval = 15

    private var timerTask: Task<Void, Never>?

    // Retained so we can build arrivals for a tapped vehicle without refetching.
    private var busTripUpdatesByTrip: [String: GTFSRealtime.TripUpdate] = [:]
    private var railArrivals: [RailFeed.RailArrival] = []

    // Poll-to-poll prediction movement ("trip|stop" / "train|station|dir" ->
    // seconds shifted). Rows whose prediction is churning show as "updating".
    private var lastBusPredictions: [String: Int] = [:]
    private var busShift: [String: Int] = [:]
    private var lastRailPredictions: [String: Int] = [:]
    private var railShift: [String: Int] = [:]

    /// tripId -> OccupancyStatus, from the vehicle-positions feed each poll.
    private var occupancyByTrip: [String: Int] = [:]
    /// Active MARTA service alerts (usually empty; populated during disruptions).
    @Published private(set) var serviceAlerts: [GTFSRealtime.AlertInfo] = []

    private let apiKey: String

    init(apiKey: String = MartaService.apiKeyFromBundle()) {
        self.apiKey = apiKey
        // Test hook: seed a fake service alert "route|header" for UI verification.
        // No effect on a normal launch.
        if let raw = ProcessInfo.processInfo.environment["MARTA_FAKE_ALERT"] {
            let parts = raw.components(separatedBy: "|")
            if parts.count == 2 {
                serviceAlerts = [GTFSRealtime.AlertInfo(routeIds: [parts[0]], stopIds: [],
                                                        header: parts[1], detail: nil)]
            }
        }
    }

    /// Alerts touching a route (by short name) — shown as banners.
    func alerts(forRoute routeKey: String) -> [GTFSRealtime.AlertInfo] {
        serviceAlerts.filter { $0.routeIds.contains(routeKey) }
    }

    /// Alerts touching any of a place's stop ids or its name.
    func alerts(forPlaceCodes codes: Set<String>) -> [GTFSRealtime.AlertInfo] {
        serviceAlerts.filter { !Set($0.stopIds).isDisjoint(with: codes) }
    }

    /// Live crowding for the bus serving a trip, if the feed reports it.
    func occupancy(forTrip tripId: String?) -> Int? {
        tripId.flatMap { occupancyByTrip[$0] }
    }

    nonisolated static func apiKeyFromBundle() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "MartaRailAPIKey") as? String) ?? ""
    }

    func start() {
        guard timerTask == nil else { return }
        timerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(nanoseconds: UInt64(self.refreshInterval * 1_000_000_000))
            }
        }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        var merged: [Vehicle] = []
        var problems: [String] = []

        // Bus
        do {
            let snapshot = try await BusFeed.fetch()
            merged.append(contentsOf: snapshot.vehicles)
            busTripUpdatesByTrip = Dictionary(
                snapshot.tripUpdates.compactMap { tu in tu.trip.tripId.map { ($0, tu) } },
                uniquingKeysWith: { first, _ in first }
            )
            // Diff predictions vs the previous poll to spot churn.
            var newPredictions: [String: Int] = [:]
            for tu in snapshot.tripUpdates {
                guard let tripId = tu.trip.tripId else { continue }
                for stu in tu.stopTimeUpdates {
                    guard let stopId = stu.stopId,
                          let t = stu.arrival?.time ?? stu.departure?.time else { continue }
                    newPredictions["\(tripId)|\(stopId)"] = t
                }
            }
            busShift = newPredictions.reduce(into: [:]) { out, kv in
                if let old = lastBusPredictions[kv.key] { out[kv.key] = kv.value - old }
            }
            lastBusPredictions = newPredictions
            occupancyByTrip = snapshot.vehicles.reduce(into: [:]) { out, v in
                if let trip = v.tripId, let occ = v.occupancy { out[trip] = occ }
            }
        } catch {
            problems.append("Bus: \(error.localizedDescription)")
        }

        // Service alerts (tiny feed; failures are non-fatal and keep last value).
        if ProcessInfo.processInfo.environment["MARTA_FAKE_ALERT"] == nil {
            if let alerts = try? await BusFeed.fetchAlerts() {
                serviceAlerts = alerts
            }
        }

        // Rail
        do {
            let arrivals = try await RailFeed.fetch(apiKey: apiKey)
            railArrivals = arrivals
            merged.append(contentsOf: RailFeed.vehicles(from: arrivals))
            var newPredictions: [String: Int] = [:]
            for a in arrivals {
                guard let train = a.trainId, !train.isEmpty, let station = a.station,
                      let t = a.predictedTime else { continue }
                newPredictions["\(train)|\(station)|\(a.direction ?? "")"] =
                    Int(t.timeIntervalSince1970)
            }
            railShift = newPredictions.reduce(into: [:]) { out, kv in
                if let old = lastRailPredictions[kv.key] { out[kv.key] = kv.value - old }
            }
            lastRailPredictions = newPredictions
        } catch {
            problems.append("Rail: \(error.localizedDescription)")
        }

        // Only replace the map if we got at least one feed; otherwise keep the
        // last good data and surface the error.
        if !merged.isEmpty {
            vehicles = merged
            lastUpdated = Date()
        }
        errorMessage = problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    /// Build the upcoming-arrivals list for a tapped vehicle.
    func arrivals(for vehicle: Vehicle) -> [Arrival] {
        switch vehicle.mode {
        case .bus:   return arrivalsForBus(vehicle)
        case .rail:  return arrivalsForRailTrain(vehicle)
        }
    }

    private func arrivalsForBus(_ vehicle: Vehicle) -> [Arrival] {
        guard let tripId = vehicle.tripId,
              let tu = busTripUpdatesByTrip[tripId] else { return [] }
        let now = Int(Date().timeIntervalSince1970)
        let upcoming = tu.stopTimeUpdates.compactMap { stu -> Arrival? in
            let t = stu.arrival?.time ?? stu.departure?.time
            guard let time = t, time >= now, let stopId = stu.stopId else { return nil }
            return Arrival(
                stopId: stopId,
                stopName: StopCatalog.shared.name(for: stopId),
                route: vehicle.route,
                destination: nil,
                direction: vehicle.direction,
                predictedTime: Date(timeIntervalSince1970: TimeInterval(time)),
                delaySeconds: stu.arrival?.delay ?? stu.departure?.delay
            )
        }
        return Array(upcoming.sorted { ($0.predictedTime ?? .distantFuture) < ($1.predictedTime ?? .distantFuture) }.prefix(6))
    }

    private func arrivalsForRailTrain(_ vehicle: Vehicle) -> [Arrival] {
        let matches = railArrivals.filter { $0.trainId == vehicle.id }
        return matches.compactMap { a -> Arrival? in
            guard let station = a.station else { return nil }
            return Arrival(
                stopId: station,
                stopName: station.capitalized,
                route: a.line ?? vehicle.route,
                destination: a.destination,
                direction: a.direction,
                predictedTime: a.predictedTime,
                delaySeconds: a.delaySeconds
            )
        }
        .sorted { ($0.predictedTime ?? .distantFuture) < ($1.predictedTime ?? .distantFuture) }
    }

    // MARK: - Favorites support

    /// Distinct rail station names currently in the feed, for the picker.
    var stationNames: [String] {
        Set(railArrivals.compactMap { $0.station }).sorted()
    }

    /// Upcoming arrivals at a favorited place, soonest first.
    func arrivals(for favorite: Favorite) -> [Arrival] {
        arrivals(kind: favorite.kind, code: favorite.code)
    }

    /// Upcoming arrivals at any station/stop (used by search + detail views).
    func arrivals(kind: FavoriteKind, code: String) -> [Arrival] {
        switch kind {
        case .railStation: return arrivalsAtStation(code)
        case .busStop:     return arrivalsAtBusStop(code)
        case .route:       return []   // routes aren't a place; handled elsewhere
        }
    }

    /// Next departures for a saved commute: arrivals of its route heading toward
    /// its destination, at the origin stop or any sibling bay (routes board at a
    /// specific bay per direction).
    func commuteDepartures(_ commute: Commute) -> [Arrival] {
        // arrivalsAtBusStop expands a code to its whole facility, so querying
        // every stored sibling code would return the same departure once per
        // code. Query each distinct facility once and dedupe by identity.
        let groups = Set(commute.allFromCodes.map { StopCatalog.shared.groupCode(for: $0) })
        var seen = Set<String>()
        return groups
            .flatMap { arrivalsAtBusStop($0) }
            .filter { $0.route == commute.routeKey && $0.destination == commute.toName }
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.predictedTime ?? .distantFuture) < ($1.predictedTime ?? .distantFuture) }
    }

    /// Distinct destinations currently served by a route (from live vehicles),
    /// for building a commute.
    func destinations(forRoute routeKey: String) -> [String] {
        Set(vehicles(onRoute: routeKey).compactMap { $0.destination }).sorted()
    }

    /// Live vehicles currently on a route/line (matched by short name), each with
    /// where it's headed (rail destination from the feed; bus headsign from the
    /// bundled route directions).
    func vehicles(onRoute routeKey: String) -> [Vehicle] {
        vehicles.filter { $0.route == routeKey }.map { v in
            guard v.mode == .bus, v.destination == nil else { return v }
            var withDest = v
            withDest.destination = RouteCatalog.headsign(forTrip: v.tripId)
            return withDest
        }
    }

    private func arrivalsAtStation(_ station: String) -> [Arrival] {
        railArrivals
            .filter { $0.station == station }
            .compactMap { a in
                Arrival(
                    stopId: station,
                    stopName: station.capitalized,
                    route: a.line ?? "?",
                    destination: a.destination,
                    direction: a.direction,
                    predictedTime: a.predictedTime,
                    delaySeconds: a.delaySeconds,
                    predictionShift: railShift["\(a.trainId ?? "")|\(station)|\(a.direction ?? "")"]
                )
            }
            .sorted { ($0.predictedTime ?? .distantFuture) < ($1.predictedTime ?? .distantFuture) }
    }

    private func arrivalsAtBusStop(_ code: String) -> [Arrival] {
        // A facility code expands to all its bays; each arrival keeps its own
        // stop id so the UI can say which bay to wait at.
        let memberIds = Set(StopCatalog.shared.members(of: code))
        let now = Int(Date().timeIntervalSince1970)
        var out: [Arrival] = []
        for tu in busTripUpdatesByTrip.values {
            for stu in tu.stopTimeUpdates where memberIds.contains(stu.stopId ?? "") {
                let t = stu.arrival?.time ?? stu.departure?.time
                guard let time = t, time >= now, let stopId = stu.stopId else { continue }
                out.append(Arrival(
                    stopId: stopId,
                    stopName: StopCatalog.shared.name(for: stopId),
                    route: tu.trip.routeId ?? "?",
                    destination: RouteCatalog.headsign(forTrip: tu.trip.tripId),
                    direction: nil,
                    predictedTime: Date(timeIntervalSince1970: TimeInterval(time)),
                    delaySeconds: stu.arrival?.delay ?? stu.departure?.delay,
                    predictionShift: busShift["\(tu.trip.tripId ?? "")|\(stopId)"],
                    tripId: tu.trip.tripId
                ))
            }
        }
        return Array(
            out.sorted { ($0.predictedTime ?? .distantFuture) < ($1.predictedTime ?? .distantFuture) }
               .prefix(12)
        )
    }
}
