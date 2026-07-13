import SwiftUI

/// Map marker for a single vehicle. Trains are colored by MARTA line; buses use
/// a neutral color with a late-indicator ring for rail (where delay is known).
struct VehicleMarker: View {
    let vehicle: Vehicle
    /// When on a favorited route, the marker is enlarged with a gold halo.
    var highlighted: Bool = false

    var body: some View {
        ZStack {
            if highlighted {
                Circle()
                    .fill(Color.yellow.opacity(0.35))
                    .frame(width: markerSize + 16, height: markerSize + 16)
            }
            Circle()
                .fill(markerColor)
                .frame(width: markerSize, height: markerSize)
                .overlay(
                    Circle().stroke(strokeColor, lineWidth: strokeWidth)
                )
                .shadow(radius: highlighted ? 3 : 1.5)
            Image(systemName: vehicle.mode == .bus ? "bus.fill" : "tram.fill")
                .font(.system(size: iconSize, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var markerSize: CGFloat {
        let base: CGFloat = vehicle.mode == .rail ? 22 : 18
        return highlighted ? base + 8 : base
    }

    private var iconSize: CGFloat {
        let base: CGFloat = vehicle.mode == .bus ? 9 : 10
        return highlighted ? base + 3 : base
    }

    private var strokeColor: Color {
        if highlighted { return .yellow }
        return vehicle.isLate ? .red : .white
    }

    private var strokeWidth: CGFloat {
        if highlighted { return 3 }
        return vehicle.isLate ? 2.5 : 1.5
    }

    private var markerColor: Color {
        guard vehicle.mode == .rail else { return .indigo }
        switch vehicle.route.uppercased() {
        case "RED":   return .red
        case "GOLD":  return .orange
        case "BLUE":  return .blue
        case "GREEN": return .green
        default:      return .gray
        }
    }
}

/// Shared line/route coloring for map polylines.
enum RouteStyle {
    static func lineColor(for routeKey: String) -> Color {
        switch routeKey.uppercased() {
        case "RED": return .red
        case "GOLD": return .orange
        case "BLUE": return .blue
        case "GREEN": return .green
        default: return .indigo
        }
    }
}

import CoreLocation

/// A favorited station/stop shown as a pin on the map. Tapping navigates to its
/// place detail, so it carries the favorite's kind + code.
struct MapFavoritePlace: Identifiable {
    let id: String
    let kind: FavoriteKind
    let code: String
    let coordinate: CLLocationCoordinate2D
    let systemImage: String
    let name: String
}

/// Gold star-badged marker for a favorited place on the map.
struct FavoritePlaceMarker: View {
    let systemImage: String

    var body: some View {
        ZStack {
            Circle()
                .fill(.yellow)
                .frame(width: 26, height: 26)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(radius: 2)
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.black)
        }
    }
}
