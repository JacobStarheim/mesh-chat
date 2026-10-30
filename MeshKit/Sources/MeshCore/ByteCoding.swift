import Foundation

public enum PacketDecodingError: Error, Equatable {
    case truncated
    case unsupportedVersion(UInt8)
    case unknownType(UInt8)
    case trailingBytes
    case invalidField
}

/// Big-endian binary writer. JSON would waste most of a ~180-byte BLE frame.
struct ByteWriter {
    private(set) var data = Data()

    mutating func write(_ value: UInt8) {
        data.append(value)
    }

    mutating func write(_ value: UInt16) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xFF))
    }

    mutating func write(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    mutating func write(_ bytes: Data) {
        data.append(bytes)
    }
}

struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var isAtEnd: Bool { offset == data.endIndex }
    var remaining: Int { data.endIndex - offset }

    mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else { throw PacketDecodingError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        let high = UInt16(try readUInt8())
        let low = UInt16(try readUInt8())
        return high << 8 | low
    }

    mutating func readUInt64() throws -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<8 {
            value = value << 8 | UInt64(try readUInt8())
        }
        return value
    }

    mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw PacketDecodingError.truncated }
        defer { offset += count }
        return Data(data[offset..<offset + count])
    }

    mutating func readRest() -> Data {
        defer { offset = data.endIndex }
        return Data(data[offset...])
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    static func random(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
