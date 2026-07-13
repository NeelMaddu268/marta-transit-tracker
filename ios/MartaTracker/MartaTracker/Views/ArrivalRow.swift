import SwiftUI

/// Shared row showing one predicted arrival: stop/destination on the left,
/// ETA + delay badge on the right. Used by both the map sheet and favorites.
struct ArrivalRow: View {
    let arrival: Arrival
    /// When true (favorites list), lead with the route badge since rows mix routes.
    var showRoute: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            if showRoute {
                RoutePill(route: arrival.route)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text((arrival.stopName ?? arrival.stopId).localizedCapitalized)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .lineLimit(1)
                if let dest = arrival.destination, !dest.isEmpty {
                    Text("to \(dest)").font(.caption).foregroundStyle(.secondary)
                } else if let dir = arrival.direction, !dir.isEmpty {
                    Text("Direction \(dir)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                TickingETA(time: arrival.predictedTime)
                    .font(.system(.callout, design: .rounded).weight(.bold))
                DelayBadge(delaySeconds: arrival.delaySeconds, compact: true)
            }
        }
        .padding(.vertical, 2)
    }
}
