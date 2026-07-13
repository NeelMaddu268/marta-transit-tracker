import Foundation
import CoreLocation

enum TransitMode: String {
    case bus
    case rail
}

/// A single vehicle/train position for the live map.
struct Vehicle: Identifiable {
    let id: String            // vehicle id (bus) or train id (rail); may be synthetic
    let mode: TransitMode
    let route: String         // bus route_id / rail LINE
    let tripId: String?       // bus only
    let coordinate: CLLocationCoordinate2D
    let direction: String?
    let delaySeconds: Int?    // + late, - early, nil unknown
    var occupancy: Int? = nil        // GTFS OccupancyStatus raw value (bus)
    var destination: String? = nil   // rail: from feed; bus: filled from RouteCatalog

    var isLate: Bool { (delaySeconds ?? 0) > 60 }
}
