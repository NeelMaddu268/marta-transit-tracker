import Foundation
import CoreLocation

/// Bundled per-route polylines (one per direction) from GTFS shapes, decimated
/// for display. Keyed by route short name to match live vehicles.
enum RouteShapes {
    private static let raw: [String: [[[Double]]]] = {
        guard let url = Bundle.main.url(forResource: "route_shapes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let shapes = try? JSONDecoder().decode([String: [[[Double]]]].self, from: data)
        else { return [:] }
        return shapes
    }()

    /// Polylines for a route (usually two: one per direction).
    static func polylines(for routeKey: String) -> [[CLLocationCoordinate2D]] {
        (raw[routeKey] ?? []).map { poly in
            poly.compactMap { pt in
                pt.count == 2 ? CLLocationCoordinate2D(latitude: pt[0], longitude: pt[1]) : nil
            }
        }
    }

    static let railLines = ["RED", "GOLD", "BLUE", "GREEN"]
}
