import Foundation

/// A saved commute: "take <route> from <origin stop> toward <destination>."
/// e.g. Windward P&R → 140 → North Springs Stn. Surfaced at the top of the
/// route's detail view.
struct Commute: Identifiable, Codable, Hashable {
    let routeKey: String        // "140"
    let fromCode: String        // origin stop_id the user picked
    let fromName: String        // origin display name
    let toName: String          // destination headsign, e.g. "North Springs Stn"
    /// All boardable stop ids at the origin, including sibling bays of the same
    /// park-and-ride/station (e.g. Windward Bay B/C/D). MARTA routes board at a
    /// specific bay per direction, so matching only the picked bay can silently
    /// miss every departure. Nil on legacy saves; resolved by migration.
    var fromCodes: [String]? = nil

    var allFromCodes: [String] { fromCodes ?? [fromCode] }

    var id: String { "\(routeKey)|\(fromCode)|\(toName)" }

    var title: String { "\(fromName) → \(toName)" }

    /// GTFS names are OFTEN ALL-CAPS; display them in title case.
    var displayFrom: String { fromName.localizedCapitalized }
    var displayTitle: String { "\(displayFrom) → \(toName)" }
}
