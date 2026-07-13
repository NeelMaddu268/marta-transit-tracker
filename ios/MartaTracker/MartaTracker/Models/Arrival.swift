import Foundation

/// A predicted arrival at a stop/station, shown when the user taps a vehicle.
struct Arrival: Identifiable {
    let stopId: String        // bus stop_id / rail station name
    let stopName: String?     // resolved bus stop name, if available
    let route: String
    let destination: String?
    let direction: String?
    let predictedTime: Date?
    let delaySeconds: Int?
    /// How much this prediction moved since the previous poll (seconds; nil
    /// unknown). Large shifts mean the feed is actively re-estimating.
    var predictionShift: Int? = nil
    /// The serving trip (bus), for joining occupancy/vehicle info.
    var tripId: String? = nil

    var isVolatile: Bool {
        predictionShift.map { abs($0) > ETAConfidence.volatileShiftSeconds } ?? false
    }

    /// Stable identity across refreshes: the same logical arrival keeps its id,
    /// so SwiftUI rows (and their ticking countdowns) don't churn every poll.
    var id: String {
        let t = predictedTime.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
        return "\(stopId)|\(route)|\(destination ?? direction ?? "")|\(t)"
    }

    /// Seconds until arrival from now (nil if no predicted time).
    var etaSeconds: Int? {
        guard let t = predictedTime else { return nil }
        return Int(t.timeIntervalSinceNow)
    }
}
