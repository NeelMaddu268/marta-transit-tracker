import Foundation

/// A navigable target from search: a place (station/stop), a route, or a
/// route's dedicated full-screen map.
enum SearchDestination: Hashable {
    case place(kind: FavoriteKind, code: String, name: String)
    case route(String)      // route key (short name)
    case routeMap(String)   // full-screen map filtered to one route
}
