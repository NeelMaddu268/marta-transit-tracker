import SwiftUI

/// Rider-facing crowding label for a GTFS OccupancyStatus raw value.
enum Occupancy {
    /// (label, SF symbol, color) — nil when unknown/unpopulated.
    static func describe(_ raw: Int?) -> (label: String, symbol: String, color: Color)? {
        switch raw {
        case 0, 1: return ("Seats available", "person", .green)
        case 2:    return ("Few seats", "person.2", .orange)
        case 3:    return ("Standing room", "person.2.fill", .orange)
        case 4, 5: return ("Full", "person.3.fill", .red)
        case 6:    return ("Not boarding", "nosign", .red)
        default:   return nil
        }
    }
}

/// Small crowding chip shown wherever a specific bus is referenced.
struct OccupancyBadge: View {
    let raw: Int?
    var onDark = false

    var body: some View {
        if let d = Occupancy.describe(raw) {
            HStack(spacing: 3) {
                Image(systemName: d.symbol).font(.system(size: 9, weight: .bold))
                Text(d.label).font(.caption2.weight(.bold))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(onDark ? AnyShapeStyle(.white.opacity(0.22))
                               : AnyShapeStyle(d.color.opacity(0.15)),
                        in: Capsule())
            .foregroundStyle(onDark ? .white : d.color)
        }
    }
}
