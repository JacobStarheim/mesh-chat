import Foundation

/// Splits packets into BLE-sized frames and puts them back together.
///
/// Frame format:
///
///     0x00 | packet                                  (fits in one frame)
///     0x01 | fragmentID u16 | index u8 | count u8 | chunk
public enum Fragmenter {
    static let wholeKind: UInt8 = 0
    static let fragmentKind: UInt8 = 1
    static let fragmentHeaderLength = 5

    public static func frames(for packet: Data, maxFrameSize: Int, fragmentID: UInt16) -> [Data] {
        precondition(maxFrameSize > fragmentHeaderLength, "frame size too small")
        if packet.count + 1 <= maxFrameSize {
            return [Data([wholeKind]) + packet]
        }
        let chunkSize = maxFrameSize - fragmentHeaderLength
        let count = (packet.count + chunkSize - 1) / chunkSize
        precondition(count <= Int(UInt8.max), "packet too large to fragment")

        return (0..<count).map { index in
            let start = packet.startIndex + index * chunkSize
            let end = min(start + chunkSize, packet.endIndex)
            var writer = ByteWriter()
            writer.write(fragmentKind)
            writer.write(fragmentID)
            writer.write(UInt8(index))
            writer.write(UInt8(count))
            writer.write(packet[start..<end])
            return writer.data
        }
    }
}

/// Reassembles frames from one link. Keep one instance per link.
public struct Reassembler {
    private struct Partial {
        var chunks: [Data?]
        var startedAt: Date
    }

    private var partials: [UInt16: Partial] = [:]
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 30) {
        self.timeout = timeout
    }

    /// Returns a complete packet once all of its frames have arrived.
    public mutating func add(_ frame: Data, now: Date = Date()) -> Data? {
        partials = partials.filter { now.timeIntervalSince($0.value.startedAt) < timeout }

        var reader = ByteReader(frame)
        guard let kind = try? reader.readUInt8() else { return nil }
        if kind == Fragmenter.wholeKind {
            return reader.readRest()
        }
        guard kind == Fragmenter.fragmentKind,
              let fragmentID = try? reader.readUInt16(),
              let index = try? reader.readUInt8(),
              let count = try? reader.readUInt8(),
              count > 0, index < count
        else { return nil }

        var partial = partials[fragmentID] ?? Partial(chunks: Array(repeating: nil, count: Int(count)), startedAt: now)
        guard partial.chunks.count == Int(count) else {
            partials[fragmentID] = nil
            return nil
        }
        partial.chunks[Int(index)] = reader.readRest()

        if partial.chunks.allSatisfy({ $0 != nil }) {
            partials[fragmentID] = nil
            return partial.chunks.reduce(into: Data()) { $0.append($1!) }
        }
        partials[fragmentID] = partial
        return nil
    }
}
