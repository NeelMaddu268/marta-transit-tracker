import Foundation

enum FavoriteKind: String, Codable {
    case railStation
    case busStop
    case route

    var systemImage: String {
        switch self {
        case .railStation: return "tram.fill"
        case .busStop:     return "bus.fill"
        case .route:       return "signpost.right.fill"
        }
    }

    var isPlace: Bool { self == .railStation || self == .busStop }
}

/// A saved place the user wants upcoming arrivals for.
struct Favorite: Identifiable, Codable, Hashable {
    let kind: FavoriteKind
    let code: String     // rail: STATION name; bus: stop_id
    let name: String     // display name

    /// Stable identity across kinds (a station name can't collide with a stop id).
    var id: String { "\(kind.rawValue):\(code)" }

    var systemImage: String { kind.systemImage }
}
