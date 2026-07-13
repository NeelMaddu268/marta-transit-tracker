import Foundation
import CoreLocation

/// Fetches MARTA rail arrivals directly from the realtime REST API (JSON).
/// The delay is provided by the feed as "T<seconds>S" (e.g. T93S = 93s late).
enum RailFeed {

    /// One raw arrival row from the rail feed.
    struct RailArrival: Decodable {
        let line: String?
        let station: String?
        let direction: String?
        let trainId: String?
        let destination: String?
        let nextArrival: String?
        let waitingTime: String?
        let waitingSeconds: String?
        let delay: String?
        let latitude: String?
        let longitude: String?

        enum CodingKeys: String, CodingKey {
            case line = "LINE"
            case station = "STATION"
            case direction = "DIRECTION"
            case trainId = "TRAIN_ID"
            case destination = "DESTINATION"
            case nextArrival = "NEXT_ARR"
            case waitingTime = "WAITING_TIME"
            case waitingSeconds = "WAITING_SECONDS"
            case delay = "DELAY"
            case latitude = "LATITUDE"
            case longitude = "LONGITUDE"
        }

        var delaySeconds: Int? { RailFeed.parseDelay(delay) }

        var coordinate: CLLocationCoordinate2D? {
            guard let latStr = latitude, let lonStr = longitude,
                  let lat = Double(latStr), let lon = Double(lonStr),
                  lat != 0, lon != 0 else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }

        /// Predicted arrival as a Date, derived from WAITING_SECONDS (robust,
        /// avoids parsing the clock-time strings and their timezone).
        var predictedTime: Date? {
            guard let w = waitingSeconds, let s = Int(w) else { return nil }
            return Date().addingTimeInterval(TimeInterval(s))
        }
    }

    /// Parse "T93S" -> 93, "T-3S" -> -3, nil otherwise.
    static func parseDelay(_ raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces),
              raw.hasPrefix("T"), raw.hasSuffix("S") else { return nil }
        let middle = raw.dropFirst().dropLast()
        return Int(middle)
    }

    /// Fetch and decode the rail feed. Throws on network / decode failure.
    static func fetch(apiKey: String, session: URLSession = .shared) async throws -> [RailArrival] {
        guard !apiKey.isEmpty else { throw FeedError.missingAPIKey }
        let urlString = "https://developerservices.itsmarta.com:18096/itsmarta"
            + "/railrealtimearrivals/developerservices/traindata?apiKey=\(apiKey)"
        guard let url = URL(string: urlString) else { throw FeedError.badURL }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FeedError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode([RailArrival].self, from: data)
    }

    /// Build one map Vehicle per distinct train that has a position. The rail
    /// feed lists a train once per upcoming station, so we keep the row with the
    /// soonest arrival as the train's "current" position.
    static func vehicles(from arrivals: [RailArrival]) -> [Vehicle] {
        var byTrain: [String: RailArrival] = [:]
        for a in arrivals {
            guard let train = a.trainId, !train.isEmpty, a.coordinate != nil else { continue }
            let key = train
            if let existing = byTrain[key],
               let existingWait = existing.waitingSeconds.flatMap(Int.init),
               let newWait = a.waitingSeconds.flatMap(Int.init),
               existingWait <= newWait {
                continue
            }
            byTrain[key] = a
        }
        return byTrain.values.compactMap { a in
            guard let coord = a.coordinate else { return nil }
            return Vehicle(
                id: a.trainId ?? UUID().uuidString,
                mode: .rail,
                route: a.line ?? "?",
                tripId: nil,
                coordinate: coord,
                direction: a.direction,
                delaySeconds: a.delaySeconds,
                destination: a.destination
            )
        }
    }
}

enum FeedError: LocalizedError {
    case missingAPIKey
    case badURL
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Missing MARTA rail API key. Add it to Secrets.xcconfig."
        case .badURL:
            return "Could not build the feed URL."
        case .badResponse(let code):
            return "Feed returned HTTP \(code)."
        }
    }
}
