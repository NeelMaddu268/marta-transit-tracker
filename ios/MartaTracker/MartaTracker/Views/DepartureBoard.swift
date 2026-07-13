import SwiftUI

/// Arrivals at a place, grouped like a departure board:
/// "140 → North Springs Stn   8 min (then 23, 38 min)".
struct DepartureGroup: Identifiable {
    let route: String
    let destination: String?
    let bay: String?                 // where to wait, e.g. "Bay C" (facilities)
    let arrivals: [Arrival]          // soonest first

    var id: String { "\(route)|\(destination ?? "")" }

    /// Group + sort a flat arrivals list. Groups ordered by their soonest arrival.
    /// Each route+direction boards at a consistent bay, so the group's bay is
    /// taken from its next arrival.
    static func group(_ arrivals: [Arrival]) -> [DepartureGroup] {
        let byKey = Dictionary(grouping: arrivals) { "\($0.route)|\($0.destination ?? $0.direction ?? "")" }
        return byKey.values
            .map { group -> DepartureGroup in
                let sorted = group.sorted {
                    ($0.predictedTime ?? .distantFuture) < ($1.predictedTime ?? .distantFuture)
                }
                return DepartureGroup(route: sorted[0].route,
                                      destination: sorted[0].destination ?? sorted[0].direction,
                                      bay: StopCatalog.shared.bayLabel(for: sorted[0].stopId),
                                      arrivals: sorted)
            }
            .sorted {
                ($0.arrivals.first?.predictedTime ?? .distantFuture)
                    < ($1.arrivals.first?.predictedTime ?? .distantFuture)
            }
    }
}

/// One departure-board row: route chip + destination, live countdown, delay,
/// and the following times ("then 23, 38 min").
struct DepartureBoardRow: View {
    let group: DepartureGroup
    var occupancy: Int? = nil      // crowding of the next bus, when reported
    var typicalDelay: Int? = nil   // historical route lateness at this hour

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RoutePill(route: group.route)
            VStack(alignment: .leading, spacing: 4) {
                Text(group.destination ?? "Arrivals")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let bay = group.bay {
                        InfoChip(text: "Wait at \(bay)")
                    }
                    OccupancyBadge(raw: occupancy)
                    if let typical = typicalDelay {
                        InfoChip(text: "usually +\(typical / 60)m this hour", tint: .orange)
                    }
                    if group.arrivals.count > 1 {
                        Text("then \(laterTimesText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                if let next = group.arrivals.first {
                    TickingETA(time: next.predictedTime, approximate: true)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundStyle(RouteStyle.lineColor(for: group.route))
                    HStack(spacing: 4) {
                        if next.isVolatile {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.orange)
                                .symbolEffect(.pulse)
                                .accessibilityLabel("prediction updating")
                        }
                        DelayBadge(delaySeconds: next.delaySeconds, compact: true)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var laterTimesText: String {
        group.arrivals.dropFirst().prefix(3)
            .compactMap { a -> String? in
                guard let eta = a.etaSeconds, eta > 0 else { return nil }
                return "\(eta / 60)"
            }
            .joined(separator: ", ") + " min"
    }
}

/// A live countdown to a time: re-renders every second. ">= 2 min" shows whole
/// minutes; under 2 min shows m:ss; under 30s shows "Now". Far-out predictions
/// (which are schedule-anchored estimates) get a "~" prefix.
struct TickingETA: View {
    let time: Date?
    var approximate = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(label(now: context.date))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
        }
    }

    private func label(now: Date) -> String {
        guard let time else { return "—" }
        let eta = Int(time.timeIntervalSince(now))
        if eta <= 30 { return "Now" }
        if eta < 120 { return String(format: "%d:%02d", eta / 60, eta % 60) }
        // Floor, don't round: "14:40 away" shows 14 min. Overstating time and
        // making someone miss a bus is worse than understating it.
        let prefix = approximate && ETAConfidence.isApproximate(horizonMinutes: eta / 60) ? "~" : ""
        return "\(prefix)\(eta / 60) min"
    }
}
