import Foundation

/// Client for the local Python collector service (Phase 3 historical stats).
/// Unlike the live feeds, this talks to our own service; it may be offline, so
/// callers should handle `HistoryError.unreachable` gracefully.
enum HistoryService {

    /// UserDefaults key for the in-app override of the service URL (Settings).
    static let overrideKey = "serviceBaseURL"

    static var baseURL: URL {
        // In-app Settings override wins; falls back to the build-time plist value.
        if let raw = UserDefaults.standard.string(forKey: overrideKey),
           !raw.trimmingCharacters(in: .whitespaces).isEmpty,
           let url = URL(string: raw) {
            return url
        }
        let raw = (Bundle.main.object(forInfoDictionaryKey: "MartaServiceBaseURL") as? String)
            ?? "http://127.0.0.1:8000"
        return URL(string: raw) ?? URL(string: "http://127.0.0.1:8000")!
    }

    /// The plist default, for showing in Settings.
    static var bundledBaseURL: String {
        (Bundle.main.object(forInfoDictionaryKey: "MartaServiceBaseURL") as? String)
            ?? "http://127.0.0.1:8000"
    }

    /// Quick /health probe for the Settings connection test.
    static func healthCheck(session: URLSession = .shared) async throws -> (observations: Int, secondsAgo: Int?) {
        let data = try await get(baseURL.appendingPathComponent("health"), session: session)
        struct Health: Decodable {
            let total_observations: Int
            let seconds_since_latest: Int?
        }
        guard let health = try? JSONDecoder().decode(Health.self, from: data) else {
            throw HistoryError.decoding
        }
        return (health.total_observations, health.seconds_since_latest)
    }

    /// Historical delay stats grouped by route / hour / dow, optionally scoped to
    /// one route. `minN` drops groups with too few samples to be meaningful.
    static func delayStats(
        source: TransitMode,
        groupBy: String,
        route: String? = nil,
        minN: Int = 1,
        session: URLSession = .shared
    ) async throws -> [DelayGroup] {
        var comps = URLComponents(url: baseURL.appendingPathComponent("stats/delay"),
                                  resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "source", value: source.rawValue),
            URLQueryItem(name: "group_by", value: groupBy),
            URLQueryItem(name: "min_n", value: String(minN)),
        ]
        if let route { items.append(URLQueryItem(name: "route", value: route)) }
        comps.queryItems = items

        let data = try await get(comps.url!, session: session)
        do {
            return try JSONDecoder().decode(DelayStatsResponse.self, from: data).groups
        } catch {
            throw HistoryError.decoding
        }
    }

    /// Multimodal trip plan (OTP routing + our delay annotations) between two
    /// coordinates. `date`/`time` are agency-local (YYYY-MM-DD / HH:MM:SS); omit
    /// for "now".
    static func plan(
        fromLat: Double, fromLon: Double, toLat: Double, toLon: Double,
        date: String? = nil, time: String? = nil,
        session: URLSession = .shared
    ) async throws -> [Itinerary] {
        var comps = URLComponents(url: baseURL.appendingPathComponent("plan"),
                                  resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "from_lat", value: String(fromLat)),
            URLQueryItem(name: "from_lon", value: String(fromLon)),
            URLQueryItem(name: "to_lat", value: String(toLat)),
            URLQueryItem(name: "to_lon", value: String(toLon)),
        ]
        if let date { items.append(URLQueryItem(name: "date", value: date)) }
        if let time { items.append(URLQueryItem(name: "time", value: time)) }
        comps.queryItems = items

        let data = try await get(comps.url!, session: session)
        do {
            return try JSONDecoder().decode(TripPlan.self, from: data).itineraries
        } catch {
            throw HistoryError.decoding
        }
    }

    private static func get(_ url: URL, session: URLSession) async throws -> Data {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { throw HistoryError.unreachable }
            guard (200..<300).contains(http.statusCode) else {
                // Surface FastAPI's {"detail": "..."} message when present.
                let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["detail"]
                throw HistoryError.server(detail ?? "HTTP \(http.statusCode)")
            }
            return data
        } catch let e as HistoryError {
            throw e
        } catch {
            // Connection refused / timeout / no route to host -> service is down.
            throw HistoryError.unreachable
        }
    }
}

enum HistoryError: LocalizedError {
    case unreachable
    case server(String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .unreachable:
            return "Can't reach the collector service. Make sure it's running "
                 + "(python -m collector.api)."
        case .server(let message):
            return message
        case .decoding:
            return "Couldn't read the response from the collector service."
        }
    }
}
