import SwiftUI
import CoreLocation

/// "Near me": the closest stations and bus stops to your location, each opening
/// its live departures.
struct NearbySheet: View {
    @StateObject private var location = LocationService()

    private struct NearbyItem: Identifiable {
        let kind: FavoriteKind
        let code: String
        let name: String
        let meters: Double
        var id: String { "\(kind.rawValue):\(code)" }
    }

    var body: some View {
        NavigationStack {
            Group {
                if location.denied {
                    ContentUnavailableView(
                        "Location is off",
                        systemImage: "location.slash",
                        description: Text("Allow location access in Settings to see nearby stops.")
                    )
                } else if let loc = location.location {
                    list(around: loc.coordinate)
                } else {
                    ProgressView("Finding you…")
                }
            }
            .navigationTitle("Near Me")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SearchDestination.self) { dest in
                if case let .place(kind, code, name) = dest {
                    PlaceDetailView(kind: kind, code: code, name: name)
                }
            }
        }
        .onAppear { location.requestFix() }
    }

    private func list(around coord: CLLocationCoordinate2D) -> some View {
        List(items(around: coord)) { item in
            NavigationLink(value: SearchDestination.place(
                kind: item.kind, code: item.code, name: item.name)) {
                HStack(spacing: 12) {
                    Image(systemName: item.kind.systemImage)
                        .foregroundStyle(item.kind == .railStation ? .blue : .indigo)
                        .frame(width: 24)
                    Text(item.name).lineLimit(1)
                    Spacer()
                    Text(distanceText(item.meters))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .listStyle(.plain)
    }

    private func items(around coord: CLLocationCoordinate2D) -> [NearbyItem] {
        let here = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        var out: [NearbyItem] = StopCatalog.shared.nearest(to: coord, limit: 15).map {
            NearbyItem(kind: .busStop, code: $0.id, name: $0.name, meters: $0.meters)
        }
        for s in StationCatalog.railStations {
            let d = here.distance(from: CLLocation(latitude: s.lat, longitude: s.lon))
            if d < 2500 {   // stations only when genuinely walkable
                out.append(NearbyItem(kind: .railStation, code: s.name, name: s.name, meters: d))
            }
        }
        return out.sorted { $0.meters < $1.meters }
    }

    private func distanceText(_ meters: Double) -> String {
        if meters < 160 {
            return "\(Int((meters * 3.28084 / 10).rounded()) * 10) ft"
        }
        return String(format: "%.1f mi", meters / 1609.34)
    }
}
