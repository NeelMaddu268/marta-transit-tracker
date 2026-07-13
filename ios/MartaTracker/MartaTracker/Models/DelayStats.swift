import Foundation

/// Per-group historical delay stats from the Python service's /stats/delay.
/// `group` is a route id, station, hour, or day-of-week depending on the query;
/// the API returns it as a string or int, so decode flexibly.
struct DelayGroup: Decodable, Identifiable {
    let group: String
    let n: Int
    let avgDelay: Double
    let medianDelay: Int
    let p90Delay: Int
    let minDelay: Int
    let maxDelay: Int
    let onTimePct: Double
    let latePct: Double
    let earlyPct: Double

    var id: String { group }

    enum CodingKeys: String, CodingKey {
        case group, n
        case avgDelay = "avg_delay"
        case medianDelay = "median_delay"
        case p90Delay = "p90_delay"
        case minDelay = "min_delay"
        case maxDelay = "max_delay"
        case onTimePct = "on_time_pct"
        case latePct = "late_pct"
        case earlyPct = "early_pct"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .group) {
            group = s
        } else {
            group = String(try c.decode(Int.self, forKey: .group))
        }
        n = try c.decode(Int.self, forKey: .n)
        avgDelay = try c.decode(Double.self, forKey: .avgDelay)
        medianDelay = try c.decode(Int.self, forKey: .medianDelay)
        p90Delay = try c.decode(Int.self, forKey: .p90Delay)
        minDelay = try c.decode(Int.self, forKey: .minDelay)
        maxDelay = try c.decode(Int.self, forKey: .maxDelay)
        onTimePct = try c.decode(Double.self, forKey: .onTimePct)
        latePct = try c.decode(Double.self, forKey: .latePct)
        earlyPct = try c.decode(Double.self, forKey: .earlyPct)
    }
}

struct DelayStatsResponse: Decodable {
    let groupBy: String
    let groups: [DelayGroup]

    enum CodingKeys: String, CodingKey {
        case groupBy = "group_by"
        case groups
    }
}
