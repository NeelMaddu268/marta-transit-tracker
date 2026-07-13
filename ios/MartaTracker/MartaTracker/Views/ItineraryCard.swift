import SwiftUI

/// One trip option: totals up top, then the legs as a colored timeline —
/// route-colored bars for transit, thin gray for walks. Transit legs carry the
/// historical-delay note (the delay-aware part of the planner).
struct ItineraryCard: View {
    let itinerary: Itinerary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("\(minutes) min")
                    .font(.system(.title3, design: .rounded).weight(.heavy))
                InfoChip(text: transfersText, tint: .indigo)
                if itinerary.walkDistanceM > 0 {
                    InfoChip(text: "\(itinerary.walkDistanceM) m walk", tint: .secondary)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 0) {
                let legs = itinerary.legs
                ForEach(Array(legs.enumerated()), id: \.element.id) { index, leg in
                    LegRow(leg: leg, isLast: index == legs.count - 1)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var minutes: Int { max(1, itinerary.durationSeconds / 60) }
    private var transfersText: String {
        let t = itinerary.transferCount
        return t == 0 ? "direct" : "\(t) transfer\(t == 1 ? "" : "s")"
    }
}

private struct LegRow: View {
    let leg: TripLeg
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Timeline column: dot + connector colored by the leg.
            VStack(spacing: 2) {
                Circle()
                    .fill(legColor)
                    .frame(width: 10, height: 10)
                    .padding(.top, 4)
                if !isLast {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(legColor.opacity(leg.isTransit ? 0.85 : 0.3))
                        .frame(width: leg.isTransit ? 4 : 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 12)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    if leg.isTransit, let route = leg.route, !route.isEmpty {
                        RoutePill(route: route)
                    }
                    Text(legTitle)
                        .font(.system(.subheadline, design: .rounded).weight(leg.isTransit ? .semibold : .regular))
                        .foregroundStyle(leg.isTransit ? .primary : .secondary)
                        .lineLimit(1)
                    Spacer()
                    Text("\(legMinutes)m")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let to = leg.to, leg.isTransit {
                    Text("→ \(to.localizedCapitalized)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let hd = leg.historicalDelay {
                    delayNote(hd)
                }
            }
            .padding(.bottom, isLast ? 0 : 14)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func delayNote(_ hd: HistoricalDelay) -> some View {
        let color = DelayFormat.color(hd.medianSeconds)
        let when = hd.basis == "route_hour" ? " at this hour" : ""
        return HStack(spacing: 4) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10))
            Text("Usually \(DelayFormat.label(hd.medianSeconds))\(when) · \(Int(hd.onTimePct))% on time")
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.top, 1)
    }

    private var legColor: Color {
        guard leg.isTransit else { return .secondary }
        return RouteStyle.lineColor(for: leg.route ?? "")
    }

    private var legMinutes: Int { max(1, leg.durationSeconds / 60) }

    private var legTitle: String {
        switch leg.mode.uppercased() {
        case "WALK": return "Walk to \(leg.to?.localizedCapitalized ?? "next stop")"
        case "SUBWAY", "RAIL", "TRAM": return "\(leg.routeLongName?.localizedCapitalized ?? leg.route ?? "Train") Line"
        case "BUS": return "Bus"
        default: return leg.mode.capitalized
        }
    }
}
