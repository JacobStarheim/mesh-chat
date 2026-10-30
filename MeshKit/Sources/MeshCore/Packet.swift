import CryptoKit
import Foundation

public enum PacketType: UInt8 {
    /// "I'm here": nickname + key-agreement key, so others can send us DMs.
    case announce = 1
    /// Public text message to everyone in range of the mesh.
    case message = 2
    /// End-to-end encrypted message to one recipient. Relays can't read it.
    case direct = 3
}

/// One mesh packet.
///
/// Wire format (big-endian):
///
///     version u8 | type u8 | hopLimit u8 | ttl u8 | flags u8 | id 16 | timestamp u64 (ms)
///     | sender 32 | [recipient 8, if flags & hasRecipient] | payloadLength u16 | payload
///     | signature 64
///
/// The signature covers every field except `ttl` (and itself), because relays
/// decrement `ttl` on every hop. `hopLimit` is the sender's original TTL, so
/// receivers can tell how many hops a packet travelled.
public struct Packet: Equatable {
    public static let version: UInt8 = 1
    public static let idLength = 16
    public static let signatureLength = 64
    public static let maxPayloadLength = 1024

    private static let hasRecipientFlag: UInt8 = 0x01

    public let type: PacketType
    public let hopLimit: UInt8
    public var ttl: UInt8
    public let id: Data
    public let timestamp: UInt64
    public let sender: Data
    public let recipient: Data?
    public let payload: Data
    public private(set) var signature: Data

    public var hops: Int { Int(hopLimit) - Int(ttl) }
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000) }

    /// Creates and signs a new packet.
    public init(
        type: PacketType,
        ttl: UInt8,
        recipient: Data? = nil,
        payload: Data,
        signedBy identity: Identity,
        id: Data? = nil,
        date: Date = Date()
    ) {
        precondition(payload.count <= Packet.maxPayloadLength, "payload too large")
        precondition(recipient == nil || recipient?.count == Fingerprint.length)
        precondition(id == nil || id?.count == Packet.idLength)
        self.type = type
        self.hopLimit = ttl
        self.ttl = ttl
        self.id = id ?? Data.random(count: Packet.idLength)
        self.timestamp = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        self.sender = identity.publicKey
        self.recipient = recipient
        self.payload = payload
        self.signature = Data()
        self.signature = (try? identity.signingKey.signature(for: signedBytes)) ?? Data()
    }

    public init(decoding data: Data) throws {
        var reader = ByteReader(data)
        let version = try reader.readUInt8()
        guard version == Packet.version else { throw PacketDecodingError.unsupportedVersion(version) }
        let rawType = try reader.readUInt8()
        guard let type = PacketType(rawValue: rawType) else { throw PacketDecodingError.unknownType(rawType) }
        self.type = type
        self.hopLimit = try reader.readUInt8()
        self.ttl = try reader.readUInt8()
        let flags = try reader.readUInt8()
        self.id = try reader.readBytes(Packet.idLength)
        self.timestamp = try reader.readUInt64()
        self.sender = try reader.readBytes(32)
        self.recipient = flags & Packet.hasRecipientFlag != 0 ? try reader.readBytes(Fingerprint.length) : nil
        let payloadLength = Int(try reader.readUInt16())
        guard payloadLength <= Packet.maxPayloadLength else { throw PacketDecodingError.invalidField }
        self.payload = try reader.readBytes(payloadLength)
        self.signature = try reader.readBytes(Packet.signatureLength)
        guard reader.isAtEnd else { throw PacketDecodingError.trailingBytes }
    }

    public func encoded() -> Data {
        var writer = ByteWriter()
        writeHeader(into: &writer, includingTTL: true)
        writer.write(signature)
        return writer.data
    }

    public func hasValidSignature() -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: sender) else { return false }
        return key.isValidSignature(signature, for: signedBytes)
    }

    private var signedBytes: Data {
        var writer = ByteWriter()
        writeHeader(into: &writer, includingTTL: false)
        return writer.data
    }

    private func writeHeader(into writer: inout ByteWriter, includingTTL: Bool) {
        writer.write(Packet.version)
        writer.write(type.rawValue)
        writer.write(hopLimit)
        if includingTTL { writer.write(ttl) }
        writer.write(recipient == nil ? 0 : Packet.hasRecipientFlag)
        writer.write(id)
        writer.write(timestamp)
        writer.write(sender)
        if let recipient { writer.write(recipient) }
        writer.write(UInt16(payload.count))
        writer.write(payload)
    }
}

/// Payload of an `.announce` packet: agreement key (32 bytes) followed by the UTF-8 nickname.
enum AnnouncePayload {
    static let maxNicknameBytes = 32

    static func encode(agreementKey: Data, nickname: String) -> Data {
        agreementKey + Data(nickname.utf8.prefix(maxNicknameBytes))
    }

    static func decode(_ payload: Data) -> (agreementKey: Data, nickname: String)? {
        guard payload.count >= 32 else { return nil }
        let key = Data(payload.prefix(32))
        let nickname = String(decoding: payload.dropFirst(32), as: UTF8.self)
        return (key, nickname)
    }
}
