import XCTest
import CoreLocation
@testable import MartaTracker

// MARK: - Tiny protobuf encoder (tests only)
// Builds wire-format bytes so decoder tests are deterministic and need no network.

private struct ProtoEncoder {
    var bytes: [UInt8] = []

    mutating func varint(_ v: UInt64) {
        var v = v
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while v != 0
    }

    mutating func tag(_ field: Int, _ wire: Int) { varint(UInt64(field << 3 | wire)) }

    mutating func varintField(_ field: Int, _ v: UInt64) {
        tag(field, 0); varint(v)
    }

    mutating func stringField(_ field: Int, _ s: String) {
        tag(field, 2)
        let utf8 = Array(s.utf8)
        varint(UInt64(utf8.count))
        bytes.append(contentsOf: utf8)
    }

    mutating func messageField(_ field: Int, _ inner: ProtoEncoder) {
        tag(field, 2)
        varint(UInt64(inner.bytes.count))
        bytes.append(contentsOf: inner.bytes)
    }

    mutating func floatField(_ field: Int, _ f: Float) {
        tag(field, 5)
        let bits = f.bitPattern
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8((bits >> shift) & 0xFF))
        }
    }

    var data: Data { Data(bytes) }
}

// MARK: - ProtobufReader

final class ProtobufReaderTests: XCTestCase {
    func testVarintDecoding() {
        // field 1, varint 1 / field 2, varint 300 (multi-byte)
        var reader = ProtobufReader([0x08, 0x01, 0x10, 0xAC, 0x02])
        let f1 = reader.nextField()
        XCTAssertEqual(f1?.number, 1)
        XCTAssertEqual(f1?.intValue, 1)
        let f2 = reader.nextField()
        XCTAssertEqual(f2?.number, 2)
        XCTAssertEqual(f2?.intValue, 300)
        XCTAssertNil(reader.nextField())
    }

    func testLengthDelimitedAndFloat() {
        var enc = ProtoEncoder()
        enc.stringField(1, "hello")
        enc.floatField(2, 33.75)
        var reader = ProtobufReader(enc.data)
        XCTAssertEqual(reader.nextField()?.stringValue, "hello")
        let f = reader.nextField()
        XCTAssertEqual(f?.floatValue ?? 0, 33.75, accuracy: 0.0001)
    }

    func testTruncatedInputStopsCleanly() {
        // length-delimited claiming 100 bytes with only 2 present
        var reader = ProtobufReader([0x0A, 100, 0x01, 0x02])
        XCTAssertNil(reader.nextField())
    }
}

// MARK: - GTFS-RT decoding (handcrafted bytes)

final class GTFSRealtimeDecodeTests: XCTestCase {
    private func makeTripUpdateFeed() -> Data {
        var trip = ProtoEncoder()
        trip.stringField(1, "T1")        // trip_id
        trip.stringField(5, "99")        // route_id

        var arrival = ProtoEncoder()
        arrival.varintField(2, 1_780_000_300)   // time

        var stu = ProtoEncoder()
        stu.varintField(1, 5)            // stop_sequence
        stu.messageField(2, arrival)     // arrival
        stu.stringField(4, "S1")         // stop_id

        var tripUpdate = ProtoEncoder()
        tripUpdate.messageField(1, trip)
        tripUpdate.messageField(2, stu)

        var entity = ProtoEncoder()
        entity.stringField(1, "e1")
        entity.messageField(3, tripUpdate)

        var feed = ProtoEncoder()
        feed.messageField(2, entity)     // FeedMessage.entity
        return feed.data
    }

    func testTripUpdateDecoding() {
        let updates = GTFSRealtime.tripUpdates(from: makeTripUpdateFeed())
        XCTAssertEqual(updates.count, 1)
        let tu = updates[0]
        XCTAssertEqual(tu.trip.tripId, "T1")
        XCTAssertEqual(tu.trip.routeId, "99")
        XCTAssertEqual(tu.stopTimeUpdates.count, 1)
        XCTAssertEqual(tu.stopTimeUpdates[0].stopId, "S1")
        XCTAssertEqual(tu.stopTimeUpdates[0].stopSequence, 5)
        XCTAssertEqual(tu.stopTimeUpdates[0].arrival?.time, 1_780_000_300)
    }

    func testVehicleDecoding() {
        var trip = ProtoEncoder()
        trip.stringField(1, "T9")
        trip.stringField(5, "140")

        var position = ProtoEncoder()
        position.floatField(1, 34.0861)
        position.floatField(2, -84.2604)

        var descriptor = ProtoEncoder()
        descriptor.stringField(1, "BUS1")

        var vehicle = ProtoEncoder()
        vehicle.messageField(1, trip)
        vehicle.messageField(2, position)
        vehicle.messageField(8, descriptor)
        vehicle.varintField(9, 3)   // occupancy: STANDING_ROOM_ONLY

        var entity = ProtoEncoder()
        entity.stringField(1, "v1")
        entity.messageField(4, vehicle)

        var feed = ProtoEncoder()
        feed.messageField(2, entity)

        let vehicles = GTFSRealtime.vehicles(from: feed.data)
        XCTAssertEqual(vehicles.count, 1)
        XCTAssertEqual(vehicles[0].id, "BUS1")
        XCTAssertEqual(vehicles[0].route, "140")
        XCTAssertEqual(vehicles[0].coordinate.latitude, 34.0861, accuracy: 0.0001)
        XCTAssertEqual(vehicles[0].coordinate.longitude, -84.2604, accuracy: 0.0001)
        XCTAssertEqual(vehicles[0].occupancy, 3)
        XCTAssertEqual(Occupancy.describe(3)?.label, "Standing room")
        XCTAssertNil(Occupancy.describe(nil))
    }

    func testAlertDecoding() {
        var text = ProtoEncoder()
        text.stringField(1, "Route 140 detour via Webb Rd")
        var translated = ProtoEncoder()
        translated.messageField(1, text)

        var selector = ProtoEncoder()
        selector.stringField(2, "140")     // route_id
        selector.stringField(5, "500347")  // stop_id

        var alert = ProtoEncoder()
        alert.messageField(5, selector)    // informed_entity
        alert.messageField(10, translated) // header_text

        var entity = ProtoEncoder()
        entity.stringField(1, "a1")
        entity.messageField(5, alert)

        var feed = ProtoEncoder()
        feed.messageField(2, entity)

        let alerts = GTFSRealtime.alerts(from: feed.data)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].header, "Route 140 detour via Webb Rd")
        XCTAssertEqual(alerts[0].routeIds, ["140"])
        XCTAssertEqual(alerts[0].stopIds, ["500347"])
    }

    func testEmptyAlertFeedYieldsNoAlerts() {
        // MARTA's live alerts feed is often just a header — must parse to [].
        var feed = ProtoEncoder()
        feed.stringField(1, "")   // arbitrary header-ish field
        XCTAssertTrue(GTFSRealtime.alerts(from: feed.data).isEmpty)
    }
}

// MARK: - GTFS-RT decoding (real frozen fixture)
// Ground truth from the reference Python parser at capture time.

final class GTFSRealtimeFixtureTests: XCTestCase {
    func testRealFeedFixtureMatchesReferenceParser() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self)
            .url(forResource: "vehiclepositions", withExtension: "pb"))
        let data = try Data(contentsOf: url)
        let vehicles = GTFSRealtime.vehicles(from: data)
        XCTAssertEqual(vehicles.count, 197)
        let first = try XCTUnwrap(vehicles.first)
        XCTAssertEqual(first.id, "2301")
        XCTAssertEqual(first.tripId, "11065664")
        XCTAssertEqual(first.route, "116")
        XCTAssertEqual(first.coordinate.latitude, 33.70624923706055, accuracy: 1e-9)
        XCTAssertEqual(first.coordinate.longitude, -84.11399841308594, accuracy: 1e-9)
    }
}

// MARK: - Search normalization

final class TextSearchTests: XCTestCase {
    func testAmpersandEqualsAnd() {
        XCTAssertTrue("WINDWARD PARK & RIDE".searchMatches("windward park and ride"))
        XCTAssertTrue("WINDWARD PARK & RIDE - BAY B".searchMatches("windward park & ride"))
        XCTAssertFalse("FIVE POINTS STATION".searchMatches("windward"))
    }

    func testPunctuationAndCase() {
        XCTAssertTrue("N MAIN ST @ WINDWARD PKWY W".searchMatches("windward pkwy"))
        XCTAssertTrue("Hamilton E. Holmes".searchMatches("hamilton e holmes"))
    }

    func testBaseStopName() {
        XCTAssertEqual("WINDWARD PARK & RIDE - BAY C".baseStopName, "WINDWARD PARK & RIDE")
        XCTAssertEqual("WINDWARD PARK & RIDE".baseStopName, "WINDWARD PARK & RIDE")
        XCTAssertEqual("MORRIS RD @ 13560".baseStopName, "MORRIS RD @ 13560")
    }
}

// MARK: - Rail delay parsing

final class RailFeedTests: XCTestCase {
    func testParseDelay() {
        XCTAssertEqual(RailFeed.parseDelay("T93S"), 93)
        XCTAssertEqual(RailFeed.parseDelay("T-3S"), -3)
        XCTAssertEqual(RailFeed.parseDelay("T0S"), 0)
        XCTAssertNil(RailFeed.parseDelay(nil))
        XCTAssertNil(RailFeed.parseDelay(""))
        XCTAssertNil(RailFeed.parseDelay("93"))
    }
}

// MARK: - Departure grouping + arrival identity

final class DepartureGroupTests: XCTestCase {
    private func arrival(route: String, dest: String?, inSeconds: Int) -> Arrival {
        Arrival(stopId: "S", stopName: "Stop", route: route, destination: dest,
                direction: nil, predictedTime: Date().addingTimeInterval(TimeInterval(inSeconds)),
                delaySeconds: nil)
    }

    func testGroupsByRouteAndDestinationSortedBySoonest() {
        let groups = DepartureGroup.group([
            arrival(route: "140", dest: "North Springs Stn", inSeconds: 600),
            arrival(route: "RED", dest: "Airport", inSeconds: 120),
            arrival(route: "140", dest: "North Springs Stn", inSeconds: 1500),
            arrival(route: "140", dest: "Morris Rd", inSeconds: 900),
        ])
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].route, "RED")                    // soonest first
        XCTAssertEqual(groups[1].route, "140")
        XCTAssertEqual(groups[1].destination, "North Springs Stn")
        XCTAssertEqual(groups[1].arrivals.count, 2)               // merged times
        XCTAssertEqual(groups[2].destination, "Morris Rd")
    }

    func testArrivalIdentityIsStable() {
        let time = Date(timeIntervalSince1970: 1_780_000_000)
        let a = Arrival(stopId: "S1", stopName: nil, route: "140", destination: "X",
                        direction: nil, predictedTime: time, delaySeconds: 5)
        let b = Arrival(stopId: "S1", stopName: "different display", route: "140",
                        destination: "X", direction: nil, predictedTime: time, delaySeconds: 99)
        XCTAssertEqual(a.id, b.id, "same logical arrival must keep its identity")
    }
}

// MARK: - Facility grouping (real bundled stops.txt)

final class StopCatalogGroupingTests: XCTestCase {
    func testWindwardBaysGroupIntoFacility() {
        // Bays B/C/D (500346/47/48) share parent 510035 in MARTA's GTFS.
        XCTAssertEqual(StopCatalog.shared.groupCode(for: "500347"), "510035")
        let members = StopCatalog.shared.members(of: "510035")
        for id in ["500346", "500347", "500348", "510035"] {
            XCTAssertTrue(members.contains(id), "missing \(id)")
        }
    }

    func testBayLabel() {
        XCTAssertEqual(StopCatalog.shared.bayLabel(for: "500347"), "Bay C")
        XCTAssertNil(StopCatalog.shared.bayLabel(for: "510035"))   // the facility itself
    }

    func testSearchCollapsesBaysIntoOneRow() {
        let results = StopCatalog.shared.search("windward park and ride")
        let facilityRows = results.filter { $0.name.baseStopName.uppercased() == "WINDWARD PARK & RIDE" }
        XCTAssertEqual(facilityRows.count, 1, "bays should fold into one facility row")
        XCTAssertEqual(facilityRows.first?.id, "510035")
    }
}

// MARK: - ETA confidence + volatility

final class ETAConfidenceTests: XCTestCase {
    func testMeasuredErrorCurve() {
        XCTAssertEqual(ETAConfidence.typicalErrorMinutes(isRail: true, horizonMinutes: 5), 1)
        XCTAssertEqual(ETAConfidence.typicalErrorMinutes(isRail: true, horizonMinutes: 16), 2)
        XCTAssertEqual(ETAConfidence.typicalErrorMinutes(isRail: true, horizonMinutes: 25), 3)
        XCTAssertEqual(ETAConfidence.typicalErrorMinutes(isRail: false, horizonMinutes: 16), 2)
    }

    func testApproximateThreshold() {
        XCTAssertFalse(ETAConfidence.isApproximate(horizonMinutes: 14))
        XCTAssertTrue(ETAConfidence.isApproximate(horizonMinutes: 15))
    }

    func testVolatility() {
        var a = Arrival(stopId: "S", stopName: nil, route: "140", destination: nil,
                        direction: nil, predictedTime: .now, delaySeconds: nil)
        XCTAssertFalse(a.isVolatile, "unknown shift is not volatile")
        a.predictionShift = 30
        XCTAssertFalse(a.isVolatile, "small shift is normal jitter")
        a.predictionShift = -90
        XCTAssertTrue(a.isVolatile, "large shift means actively re-estimating")
    }
}

// MARK: - Recents + reminder identity

final class RecentsAndReminderTests: XCTestCase {
    func testRecentsRecordDedupesAndCaps() {
        UserDefaults.standard.removeObject(forKey: "recents.v1")
        for i in 0..<10 { Recents.record(kind: "route", code: "\(i)", name: "Route \(i)") }
        Recents.record(kind: "route", code: "9", name: "Route 9")   // dupe -> stays first
        let items = Recents.all()
        XCTAssertEqual(items.count, 8, "capped at 8")
        XCTAssertEqual(items.first?.code, "9")
        XCTAssertEqual(items.filter { $0.code == "9" }.count, 1, "deduped")
        UserDefaults.standard.removeObject(forKey: "recents.v1")
    }

    func testReminderKeyStableAcrossPredictionChanges() {
        let t1 = Arrival(stopId: "500347", stopName: nil, route: "140",
                         destination: "North Springs Stn", direction: nil,
                         predictedTime: Date(timeIntervalSince1970: 1_780_000_000),
                         delaySeconds: nil, predictionShift: nil, tripId: "T1")
        var t2 = t1
        // Same bus, new prediction: reminder identity must not change.
        XCTAssertEqual(ReminderService.stableKey(t1), ReminderService.stableKey(t2))
        t2 = Arrival(stopId: "500347", stopName: nil, route: "140",
                     destination: "North Springs Stn", direction: nil,
                     predictedTime: Date(timeIntervalSince1970: 1_780_000_300),
                     delaySeconds: nil, predictionShift: 300, tripId: "T1")
        XCTAssertEqual(ReminderService.stableKey(t1), ReminderService.stableKey(t2))
        XCTAssertNotEqual(t1.id, t2.id, "display identity does change with time")
    }
}

// MARK: - Commute sibling bays

final class CommuteTests: XCTestCase {
    func testAllFromCodesFallsBackToPickedStop() {
        let legacy = Commute(routeKey: "140", fromCode: "500348",
                             fromName: "Windward", toName: "North Springs Stn")
        XCTAssertEqual(legacy.allFromCodes, ["500348"])
        var upgraded = legacy
        upgraded.fromCodes = ["500346", "500347", "500348"]
        XCTAssertEqual(upgraded.allFromCodes.count, 3)
    }

    func testLegacyCommuteDecodesWithoutFromCodes() throws {
        let json = #"[{"routeKey":"140","fromCode":"500348","fromName":"W","toName":"N"}]"#
        let commutes = try JSONDecoder().decode([Commute].self, from: Data(json.utf8))
        XCTAssertNil(commutes[0].fromCodes)
        XCTAssertEqual(commutes[0].allFromCodes, ["500348"])
    }
}
