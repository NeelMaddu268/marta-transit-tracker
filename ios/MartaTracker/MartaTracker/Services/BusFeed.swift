import Foundation

/// Fetches MARTA bus GTFS-Realtime feeds (protobuf, no key) and decodes them
/// with the dependency-free GTFSRealtime decoder.
///
/// The RT feed does not carry a delay for buses (it would require joining the
/// static schedule, which is too large to bundle), so Phase 1 shows bus
/// positions and predicted arrival times without a delay figure. Bus delay/
/// history arrives in Phase 3 via the Python service.
enum BusFeed {

    static let vehiclePositionsURL = URL(string:
        "https://gtfs-rt.itsmarta.com/TMGTFSRealTimeWebService/vehicle/vehiclepositions.pb")!
    static let tripUpdatesURL = URL(string:
        "https://gtfs-rt.itsmarta.com/TMGTFSRealTimeWebService/tripupdate/tripupdates.pb")!
    static let alertsURL = URL(string:
        "https://gtfs-rt.itsmarta.com/TMGTFSRealTimeWebService/alert/alerts.pb")!

    /// Service alerts (usually an empty feed; populated during disruptions).
    static func fetchAlerts(session: URLSession = .shared) async throws -> [GTFSRealtime.AlertInfo] {
        GTFSRealtime.alerts(from: try await data(from: alertsURL, session: session))
    }

    struct Snapshot {
        let vehicles: [Vehicle]
        let tripUpdates: [GTFSRealtime.TripUpdate]
    }

    static func fetch(session: URLSession = .shared) async throws -> Snapshot {
        async let vehiclesData = data(from: vehiclePositionsURL, session: session)
        async let tripsData = data(from: tripUpdatesURL, session: session)
        let (vData, tData) = try await (vehiclesData, tripsData)
        return Snapshot(
            vehicles: GTFSRealtime.vehicles(from: vData),
            tripUpdates: GTFSRealtime.tripUpdates(from: tData)
        )
    }

    private static func data(from url: URL, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FeedError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }
}
