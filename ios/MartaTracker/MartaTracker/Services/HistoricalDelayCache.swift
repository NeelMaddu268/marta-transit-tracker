import Foundation

/// Session cache of "how late does this route usually run at this hour", from
/// the collector's historical stats. Powers the "usually +X min at this hour"
/// context chips. Absent silently when the collector service is unreachable.
@MainActor
final class HistoricalDelayCache: ObservableObject {
    /// route key -> hour (0-23) -> (median delay seconds, samples)
    @Published private(set) var byRoute: [String: [Int: (median: Int, n: Int)]] = [:]
    private var inFlight: Set<String> = []

    /// Typical delay for a route at the current hour; only when meaningful
    /// (>= 2 min median, >= 20 samples). Triggers a background fetch on miss.
    func typicalDelayNow(route: String) -> Int? {
        let hour = Calendar.current.component(.hour, from: Date())
        if let entry = byRoute[route]?[hour] {
            return (entry.n >= 20 && entry.median >= 120) ? entry.median : nil
        }
        fetchIfNeeded(route: route)
        return nil
    }

    private func fetchIfNeeded(route: String) {
        guard byRoute[route] == nil, !inFlight.contains(route) else { return }
        inFlight.insert(route)
        Task {
            defer { inFlight.remove(route) }
            let isRail = RouteShapes.railLines.contains(route)
            guard let groups = try? await HistoryService.delayStats(
                source: isRail ? .rail : .bus, groupBy: "hour", route: route, minN: 10)
            else {
                byRoute[route] = [:]   // negative-cache: don't re-hit a dead service
                return
            }
            var hours: [Int: (Int, Int)] = [:]
            for g in groups {
                if let h = Int(g.group) { hours[h] = (g.medianDelay, g.n) }
            }
            byRoute[route] = hours
        }
    }
}
