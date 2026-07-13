import SwiftUI

/// Shown when a vehicle is tapped: its route, delay (rail), and upcoming stops
/// with ETAs.
struct ArrivalsSheet: View {
    let vehicle: Vehicle
    let arrivals: [Arrival]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                }
                if arrivals.isEmpty {
                    Section {
                        Text(vehicle.mode == .bus
                             ? "No upcoming stops reported for this bus right now."
                             : "No upcoming stations reported for this train right now.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section(vehicle.mode == .bus ? "Next stops" : "Upcoming stations") {
                        ForEach(arrivals) { arrival in
                            ArrivalRow(arrival: arrival)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var title: String {
        vehicle.mode == .bus ? "Route \(vehicle.route)" : "\(vehicle.route.capitalized) Line"
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Label(vehicle.mode == .bus ? "Bus \(vehicle.id)" : "Train \(vehicle.id)",
                      systemImage: vehicle.mode == .bus ? "bus.fill" : "tram.fill")
                    .font(.headline)
                if let dir = vehicle.direction, !dir.isEmpty {
                    Text("Direction \(dir)").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                DelayBadge(delaySeconds: vehicle.delaySeconds)
                OccupancyBadge(raw: vehicle.occupancy)
            }
        }
    }
}

/// Colored delay pill: green early/on-time, orange/red late.
struct DelayBadge: View {
    let delaySeconds: Int?
    var compact: Bool = false

    var body: some View {
        if let d = delaySeconds {
            Text(text(for: d))
                .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                .padding(.horizontal, compact ? 6 : 8)
                .padding(.vertical, compact ? 2 : 4)
                .background(color(for: d).opacity(0.18), in: Capsule())
                .foregroundStyle(color(for: d))
        } else if !compact {
            Text("No schedule")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func text(for d: Int) -> String {
        if d <= 60 && d >= -60 { return "On time" }
        let minutes = abs(d) / 60
        let unit = minutes == 0 ? "\(abs(d))s" : "\(minutes) min"
        return d > 0 ? "\(unit) late" : "\(unit) early"
    }

    private func color(for d: Int) -> Color {
        if d > 300 { return .red }
        if d > 60 { return .orange }
        return .green
    }
}
