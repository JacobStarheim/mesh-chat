import CryptoKit
import Foundation

/// A user's long-lived identity. The Ed25519 public key *is* the user's ID;
/// nicknames are only labels and are not unique.
public struct Identity {
    public let signingKey: Curve25519.Signing.PrivateKey
    public let agreementKey: Curve25519.KeyAgreement.PrivateKey
    public var nickname: String

    public init(nickname: String) {
        self.signingKey = Curve25519.Signing.PrivateKey()
        self.agreementKey = Curve25519.KeyAgreement.PrivateKey()
        self.nickname = nickname
    }

    public init(signingKey: Data, agreementKey: Data, nickname: String) throws {
        self.signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: signingKey)
        self.agreementKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agreementKey)
        self.nickname = nickname
    }

    public var publicKey: Data { signingKey.publicKey.rawRepresentation }
    public var fingerprint: Data { Fingerprint.of(publicKey) }
}

public enum Fingerprint {
    public static let length = 8

    /// Short, stable ID derived from a public key. Used as the DM recipient field
    /// to save 24 bytes per packet compared with the full key.
    public static func of(_ publicKey: Data) -> Data {
        Data(SHA256.hash(data: publicKey).prefix(length))
    }

    /// Four hex characters, for showing "alice#3fa2" in the UI.
    public static func short(_ publicKey: Data) -> String {
        String(of(publicKey).hexString.prefix(4))
    }
}

/// Someone we have heard an announce from.
public struct Peer: Identifiable, Hashable {
    public let publicKey: Data
    public var nickname: String
    public var agreementKey: Data
    public var lastSeen: Date

    public var id: Data { publicKey }
    public var fingerprint: Data { Fingerprint.of(publicKey) }
    public var displayName: String { "\(nickname)#\(Fingerprint.short(publicKey))" }
}
