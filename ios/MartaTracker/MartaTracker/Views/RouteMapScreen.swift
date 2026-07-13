import SwiftUI
import MapKit

/// Full-screen map filtered to a single route: its path drawn, only its
/// vehicles shown (live-updating), camera framed to the route.
struct RouteMapScreen: View {
    @EnvironmentObject private var service: MartaService
    let routeKey: String

    @State private var camera: MapCameraPosition
    @State private var selected: Vehicle?

    init(routeKey: String) {
        self.routeKey = routeKey
        let coords = RouteShapes.polylines(for: routeKey).flatMap { $0 }
        _camera = State(initialValue: .region(Self.fittingRegion(coords)))
    }

    private var vehicles: [Vehicle] { service.vehicles(onRoute: routeKey) }

    var body: some View {
        let vehicles = vehicles
        Map(position: $camera) {
            ForEach(Array(RouteShapes.polylines(for: routeKey).enumerated()), id: \.offset) { _, poly in
                MapPolyline(coordinates: poly)
                    .stroke(RouteStyle.lineColor(for: routeKey).opacity(0.75),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            ForEach(vehicles) { vehicle in
                Annotation(vehicle.destination.map { "to \($0)" } ?? vehicle.route,
                           coordinate: vehicle.coordinate) {
                    VehicleMarker(vehicle: vehicle, highlighted: true)
                        .onTapGesture { selected = vehicle }
                }
            }
        }
        .mapControls { MapCompass() }
        .overlay(alignment: .top) {
            Text(statusText(count: vehicles.count))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, 6)
        }
        .navigationTitle(RouteCatalog.info(for: routeKey)?.displayName ?? "Route \(routeKey)")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selected) { vehicle in
            ArrivalsSheet(vehicle: vehicle, arrivals: service.arrivals(for: vehicle))
                .presentationDetents([.medium, .large])
        }
    }

    private func statusText(count: Int) -> String {
        count == 0 ? "No vehicles on this route right now"
                   : "\(count) vehicle\(count == 1 ? "" : "s") live on this route"
    }

    /// Region that frames the route with a little breathing room; falls back to
    /// metro Atlanta when no shape is bundled.
    static func fittingRegion(_ coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let first = coords.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 33.755, longitude: -84.390),
                span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3))
        }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                           longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(0.02, (maxLat - minLat) * 1.35),
                                   longitudeDelta: max(0.02, (maxLon - minLon) * 1.35)))
    }
}