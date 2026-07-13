import Foundation

/// A multimodal trip plan from the Python service's /plan endpoint (OTP routing
/// annotated with our historical delay stats).

struct TripPlan: Decodable {
    let itineraries: [Itinerary]
}

struct Itinerary: Decodable, Identifiable {
    let durationSeconds: Int
    let walkDistanceM: Int
    let startEpoch: Int?
    let endEpoch: Int?
    let legs: [TripLeg]

    var id: String { "\(startEpoch ?? 0)-\(durationSeconds)-\(legs.count)" }

    /// Number of transfers = transit legs minus one (never negative).
    var transferCount: Int { max(0, legs.filter { $0.isTransit }.count - 1) }

    enum CodingKeys: String, CodingKey {
        case durationSeconds = "duration_seconds"
        case walkDistanceM = "walk_distance_m"
        case startEpoch = "start_epoch"
        case endEpoch = "end_epoch"
        case legs
    }
}

struct TripLeg: Decodable, Identifiable {
    let mode: String
    let durationSeconds: Int
    let from: String?
    let to: String?
    let route: String?
    let routeLongName: String?
    let startEpoch: Int?
    let historicalDelay: HistoricalDelay?

    let id = UUID()

    var isTransit: Bool {
        !["WALK", "BICYCLE", "CAR", "SCOOTER"].contains(mode.uppercased())
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case durationSeconds = "duration_seconds"
        case from, to, route
        case routeLongName = "route_long_name"
        case startEpoch = "start_epoch"
        case historicalDelay = "historical_delay"
    }
}

struct HistoricalDelay: Decodable {
    let medianSeconds: Int
    let onTimePct: Double
    let samples: Int
    let basis: String   // "route" or "route_hour"

    enum CodingKeys: String, CodingKey {
        case medianSeconds = "median_seconds"
        case onTimePct = "on_time_pct"
        case samples, basis
    }
}
