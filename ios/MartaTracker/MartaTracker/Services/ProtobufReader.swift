import Foundation

/// A tiny protobuf wire-format reader — just enough to decode the handful of
/// GTFS-Realtime fields the app needs, with no external dependencies.
///
/// Protobuf wire format: each field is a varint tag = (fieldNumber << 3) | wireType,
/// followed by a payload whose shape depends on the wire type:
///   0 = varint (LEB128)        1 = 64-bit fixed
///   2 = length-delimited       5 = 32-bit fixed
struct ProtobufReader {
    enum WireType: Int {
        case varint = 0
        case fixed64 = 1
        case lengthDelimited = 2
        case fixed32 = 5
    }

    struct Field {
        let number: Int
        let wireType: WireType
        /// For varint/fixed types: the raw integer bits. For length-delimited: 0.
        let intValue: UInt64
        /// For length-delimited fields: the payload bytes. Otherwise empty.
        let bytes: [UInt8]
    }

    private let data: [UInt8]
    private var index: Int

    init(_ data: [UInt8]) {
        self.data = data
        self.index = 0
    }

    init(_ data: Data) {
        self.init([UInt8](data))
    }

    var isAtEnd: Bool { index >= data.count }

    /// Read the next field, or nil at end / on malformed input.
    mutating func nextField() -> Field? {
        guard let tag = readVarint() else { return nil }
        let number = Int(tag >> 3)
        guard let wireType = WireType(rawValue: Int(tag & 0x07)) else { return nil }
        switch wireType {
        case .varint:
            guard let v = readVarint() else { return nil }
            return Field(number: number, wireType: wireType, intValue: v, bytes: [])
        case .fixed64:
            guard let v = readFixed(8) else { return nil }
            return Field(number: number, wireType: wireType, intValue: v, bytes: [])
        case .fixed32:
            guard let v = readFixed(4) else { return nil }
            return Field(number: number, wireType: wireType, intValue: v, bytes: [])
        case .lengthDelimited:
            guard let len = readVarint() else { return nil }
            let n = Int(len)
            guard index + n <= data.count else { return nil }
            let slice = Array(data[index ..< index + n])
            index += n
            return Field(number: number, wireType: wireType, intValue: 0, bytes: slice)
        }
    }

    private mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.count {
            let byte = data[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    private mutating func readFixed(_ count: Int) -> UInt64? {
        guard index + count <= data.count else { return nil }
        var value: UInt64 = 0
        for i in 0 ..< count {
            value |= UInt64(data[index + i]) << (8 * i)  // little-endian
        }
        index += count
        return value
    }
}

extension ProtobufReader.Field {
    /// Interpret a fixed32 payload as an IEEE-754 float (GTFS positions).
    var floatValue: Float {
        Float(bitPattern: UInt32(truncatingIfNeeded: intValue))
    }

    /// Interpret a length-delimited payload as a UTF-8 string.
    var stringValue: String {
        String(decoding: bytes, as: UTF8.self)
    }

    /// Interpret a varint as a signed Int (times, delays, sequences).
    var signedInt: Int {
        Int(bitPattern: UInt(intValue))
    }
}
