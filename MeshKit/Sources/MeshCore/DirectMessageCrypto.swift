import CryptoKit
import Foundation

/// End-to-end encryption for direct messages.
///
/// Each message uses a fresh ephemeral X25519 key, agreed with the recipient's
/// long-lived agreement key, run through HKDF-SHA256 into a ChaCha20-Poly1305 key.
/// The sender's public key and the packet ID are bound in as associated data, so a
/// relay can't re-sign someone else's ciphertext as its own.
///
/// Sealed format: ephemeralPublicKey 32 | nonce 12 | ciphertext | tag 16.
///
/// Not forward secret against compromise of the recipient's long-lived key;
/// a Noise XX handshake (as bitchat uses) would fix that.
public enum DirectMessageCrypto {
    public enum CryptoError: Error {
        case malformed
    }

    private static let info = Data("meshchat-dm-v1".utf8)

    public static func seal(
        _ plaintext: Data,
        to recipientAgreementKey: Data,
        associatedData: Data
    ) throws -> Data {
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientAgreementKey)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let key = try deriveKey(
            secret: ephemeral.sharedSecretFromKeyAgreement(with: recipient),
            ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
            recipientPublicKey: recipientAgreementKey
        )
        let box = try ChaChaPoly.seal(plaintext, using: key, authenticating: associatedData)
        return ephemeral.publicKey.rawRepresentation + box.combined
    }

    public static func open(
        _ sealed: Data,
        with agreementKey: Curve25519.KeyAgreement.PrivateKey,
        associatedData: Data
    ) throws -> Data {
        guard sealed.count > 32 + 12 + 16 else { throw CryptoError.malformed }
        let ephemeralPublicKey = Data(sealed.prefix(32))
        let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralPublicKey)
        let key = try deriveKey(
            secret: agreementKey.sharedSecretFromKeyAgreement(with: ephemeral),
            ephemeralPublicKey: ephemeralPublicKey,
            recipientPublicKey: agreementKey.publicKey.rawRepresentation
        )
        let box = try ChaChaPoly.SealedBox(combined: sealed.dropFirst(32))
        return try ChaChaPoly.open(box, using: key, authenticating: associatedData)
    }

    private static func deriveKey(
        secret: SharedSecret,
        ephemeralPublicKey: Data,
        recipientPublicKey: Data
    ) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ephemeralPublicKey + recipientPublicKey,
            sharedInfo: info,
            outputByteCount: 32
        )
    }
}
