import Foundation
import CoreLocation

/// Decodes the subset of GTFS-Realtime we need directly from the protobuf bytes,
/// using ProtobufReader. Field numbers come from the GTFS-Realtime spec
/// (transit_realtime.proto) and are stable across versions.
///
/// FeedMessage { header=1; repeated FeedEntity entity=2 }
/// FeedEntity  { id=1; TripUpdate trip_update=3; VehiclePosition vehicle=4 }
/// VehiclePosition { TripDescriptor trip=1; Position position=2;
///                   VehicleDescriptor vehicle=8 }
/// Position    { float latitude=1; float longitude=2 }
/// TripDescriptor { trip_id=1; route_id=5; direction_id=6 }
/// VehicleDescriptor { id=1 }
/// TripUpdate  { TripDescriptor trip=1; repeated StopTimeUpdate stop_time_update=2 }
/// StopTimeUpdate { stop_sequence=1; StopTimeEvent arrival=2;
///                  StopTimeEvent departure=3; stop_id=4 }
/// StopTimeEvent { int32 delay=1; int64 time=2 }
enum GTFSRealtime {

    // MARK: - Decoded intermediate types

    struct TripDescriptor {
        var tripId: String?
        var routeId: String?
        var directionId: Int?
    }

    struct Position {
        var latitude: Float?
        var longitude: Float?
    }

    struct VehiclePosition {
        var trip = TripDescriptor()
        var position = Position()
        var vehicleId: String?
        var occupancy: Int?   // GTFS OccupancyStatus raw value (field 9)
    }

    /// A service alert: which routes/stops it touches and its rider-facing text.
    struct AlertInfo: Equatable {
        var routeIds: [String] = []
        var stopIds: [String] = []
        var header: String = ""
        var detail: String?
    }

    struct StopTimeEvent {
        var delay: Int?
        var time: Int?
    }

    struct StopTimeUpdate {
        var stopSequence: Int?
        var stopId: String?
        var arrival: StopTimeEvent?
        var departure: StopTimeEvent?
    }

    struct TripUpdate {
        var trip = TripDescriptor()
        var stopTimeUpdates: [StopTimeUpdate] = []
    }

    // MARK: - Public entry points

    /// Parse the vehicle-positions feed into map-ready Vehicle values.
    static func vehicles(from data: Data) -> [Vehicle] {
        var out: [Vehicle] = []
        forEachEntity(in: data) { entity in
            guard let vp = decodeVehiclePosition(entity.vehicleBytes) else { return }
            guard let lat = vp.position.latitude, let lon = vp.position.longitude else { return }
            let id = vp.vehicleId ?? vp.trip.tripId ?? UUID().uuidString
            out.append(Vehicle(
                id: id,
                mode: .bus,
                route: vp.trip.routeId ?? "?",
                tripId: vp.trip.tripId,
                coordinate: CLLocationCoordinate2D(latitude: Double(lat), longitude: Double(lon)),
                direction: vp.trip.directionId.map(String.init),
                delaySeconds: nil,   // filled in later by joining trip updates
                occupancy: vp.occupancy
            ))
        }
        return out
    }

    /// Parse the trip-updates feed into TripUpdate values keyed for lookup.
    static func tripUpdates(from data: Data) -> [TripUpdate] {
        var out: [TripUpdate] = []
        forEachEntity(in: data) { entity in
            guard let tu = decodeTripUpdate(entity.tripUpdateBytes) else { return }
            out.append(tu)
        }
        return out
    }

    /// Parse the service-alerts feed. FeedEntity.alert = 5;
    /// Alert { informed_entity=5 (EntitySelector{route_id=2, stop_id=5}),
    ///         header_text=10, description_text=11 (TranslatedString{translation=1{text=1}}) }
    static func alerts(from data: Data) -> [AlertInfo] {
        var out: [AlertInfo] = []
        forEachEntity(in: data) { entity in
            guard let bytes = entity.alertBytes else { return }
            var info = AlertInfo()
            var r = ProtobufReader(bytes)
            while let f = r.nextField() {
                switch (f.number, f.wireType) {
                case (5, .lengthDelimited):
                    var er = ProtobufReader(f.bytes)
                    while let ef = er.nextField() {
                        switch (ef.number, ef.wireType) {
                        case (2, .lengthDelimited): info.routeIds.append(ef.stringValue)
                        case (5, .lengthDelimited): info.stopIds.append(ef.stringValue)
                        default: break
                        }
                    }
                case (10, .lengthDelimited): info.header = translatedText(f.bytes) ?? info.header
                case (11, .lengthDelimited): info.detail = translatedText(f.bytes)
                default: break
                }
            }
            if !info.header.isEmpty { out.append(info) }
        }
        return out
    }

    private static func translatedText(_ bytes: [UInt8]) -> String? {
        var r = ProtobufReader(bytes)
        while let f = r.nextField() {
            guard f.number == 1, f.wireType == .lengthDelimited else { continue }
            var tr = ProtobufReader(f.bytes)
            while let tf = tr.nextField() {
                if tf.number == 1, tf.wireType == .lengthDelimited { return tf.stringValue }
            }
        }
        return nil
    }

    // MARK: - Entity walking

    private struct EntityBytes {
        var vehicleBytes: [UInt8]?     // field 4 payload
        var tripUpdateBytes: [UInt8]?  // field 3 payload
        var alertBytes: [UInt8]?       // field 5 payload
    }

    private static func forEachEntity(in data: Data, _ body: (EntityBytes) -> Void) {
        var reader = ProtobufReader(data)
        while let field = reader.nextField() {
            // FeedMessage.entity = 2 (length-delimited FeedEntity)
            guard field.number == 2, field.wireType == .lengthDelimited else { continue }
            var entity = EntityBytes()
            var eReader = ProtobufReader(field.bytes)
            while let ef = eReader.nextField() {
                switch (ef.number, ef.wireType) {
                case (3, .lengthDelimited): entity.tripUpdateBytes = ef.bytes  // trip_update
                case (4, .lengthDelimited): entity.vehicleBytes = ef.bytes     // vehicle
                case (5, .lengthDelimited): entity.alertBytes = ef.bytes       // alert
                default: break
                }
            }
            body(entity)
        }
    }

    // MARK: - Message decoders

    private static func decodeTripDescriptor(_ bytes: [UInt8]) -> TripDescriptor {
        var td = TripDescriptor()
        var r = ProtobufReader(bytes)
        while let f = r.nextField() {
            switch (f.number, f.wireType) {
            case (1, .lengthDelimited): td.tripId = f.stringValue
            case (5, .lengthDelimited): td.routeId = f.stringValue
            case (6, .varint): td.directionId = f.signedInt
            default: break
            }
        }
        return td
    }

    private static func decodePosition(_ bytes: [UInt8]) -> Position {
        var p = Position()
        var r = ProtobufReader(bytes)
        while let f = r.nextField() {
            switch (f.number, f.wireType) {
            case (1, .fixed32): p.latitude = f.floatValue
            case (2, .fixed32): p.longitude = f.floatValue
            default: break
            }
        }
        return p
    }

    private static func decodeVehicleDescriptorId(_ bytes: [UInt8]) -> String? {
        var r = ProtobufReader(bytes)
        while let f = r.nextField() {
            if f.number == 1, f.wireType == .lengthDelimited { return f.stringValue }
        }
        return nil
    }

    private static func decodeVehiclePosition(_ bytes: [UInt8]?) -> VehiclePosition? {
        guard let bytes else { return nil }
        var vp = VehiclePosition()
        var r = ProtobufReader(bytes)
        while let f = r.nextField() {
            switch (f.number, f.wireType) {
            case (1, .lengthDelimited): vp.trip = decodeTripDescriptor(f.bytes)
            case (2, .lengthDelimited): vp.position = decodePosition(f.bytes)
            case (8, .lengthDelimited): vp.vehicleId = decodeVehicleDescriptorId(f.bytes)
            case (9, .varint): vp.occupancy = f.signedInt   // OccupancyStatus
            default: break
            }
        }
        return vp
    }

    private static func decodeStopTimeEvent(_ bytes: [UInt8]) -> StopTimeEvent {
        var e = StopTimeEvent()
        var r = ProtobufReader(bytes)
        while let f = r.nextField() {
            switch (f.number, f.wireType) {
            case (1, .varint): e.delay = f.signedInt
            case (2, .varint): e.time = f.signedInt
            default: break
            }
        }
        return e
    }

    private static func decodeStopTimeUpdate(_ bytes: [UInt8]) -> StopTimeUpdate {
        var s = StopTimeUpdate()
        var r = ProtobufReader(bytes)
        while let f = r.nextField() {
            switch (f.number, f.wireType) {
            case (1, .varint): s.stopSequence = f.signedInt
            case (2, .lengthDelimited): s.arrival = decodeStopTimeEvent(f.bytes)
            case (3, .lengthDelimited): s.departure = decodeStopTimeEvent(f.bytes)
            case (4, .lengthDelimited): s.stopId = f.stringValue
            default: break
            }
        }
        return s
    }

    private static func decodeTripUpdate(_ bytes: [UInt8]?) -> TripUpdate? {
        guard let bytes else { return nil }
        var tu = TripUpdate()
        var r = ProtobufReader(bytes)
        while let f = r.nextField() {
            switch (f.number, f.wireType) {
            case (1, .lengthDelimited): tu.trip = decodeTripDescriptor(f.bytes)
            case (2, .lengthDelimited): tu.stopTimeUpdates.append(decodeStopTimeUpdate(f.bytes))
            default: break
            }
        }
        return tu
    }
}
