import SwiftUI

/// App-wide visual identity. One gradient, one accent, route colors everywhere —
/// the same language as the app icon and widget.
enum Theme {
    static let brandTop = Color(red: 0.32, green: 0.22, blue: 0.83)
    static let brandBottom = Color(red: 0.08, green: 0.47, blue: 0.95)

    static var brandGradient: LinearGradient {
        LinearGradient(colors: [brandTop, brandBottom],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// The route identity chip: rail lines in their MARTA colors, buses in the
/// brand indigo. Used in every list, board, and card.
struct RoutePill: View {
    let route: String
    var large = false

    var body: some View {
        Text(route)
            .font(.system(large ? .title3 : .caption, design: .rounded).weight(.heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 12 : 8)
            .padding(.vertical, large ? 6 : 3)
            .frame(minWidth: large ? 56 : 42)
            .background(
                RouteStyle.lineColor(for: route).gradient,
                in: RoundedRectangle(cornerRadius: large ? 10 : 7)
            )
    }
}

/// Orange banner for an active MARTA service alert on a route/stop page.
struct AlertBanner: View {
    let alert: GTFSRealtime.AlertInfo

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .bold))
            VStack(alignment: .leading, spacing: 3) {
                Text(alert.header)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                if let detail = alert.detail, !detail.isEmpty {
                    Text(detail).font(.caption).opacity(0.92).lineLimit(4)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 16))
        .padding(.vertical, 2)
    }
}

/// Small tinted capsule for secondary facts ("Wait at Bay C", "2 transfers").
struct InfoChip: View {
    let text: String
    var tint: Color = .blue
    var onDark = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(onDark ? AnyShapeStyle(.white.opacity(0.22))
                               : AnyShapeStyle(tint.opacity(0.15)),
                        in: Capsule())
            .foregroundStyle(onDark ? .white : tint)
    }
}
