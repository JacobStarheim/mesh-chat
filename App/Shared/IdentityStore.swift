import Foundation
import MeshCore

/// Persists the user's keys and nickname between launches.
///
/// Kept in UserDefaults to keep the demo simple. A real app should store the
/// private keys in the Keychain.
enum IdentityStore {
    private static let defaults = UserDefaults.standard
    private static let signingKeyKey = "identity.signingKey"
    private static let agreementKeyKey = "identity.agreementKey"
    private static let nicknameKey = "identity.nickname"

    static func loadOrCreate() -> Identity {
        let nickname = defaults.string(forKey: nicknameKey) ?? "anon\(Int.random(in: 100...999))"
        if let signingKey = defaults.data(forKey: signingKeyKey),
           let agreementKey = defaults.data(forKey: agreementKeyKey),
           let identity = try? Identity(signingKey: signingKey, agreementKey: agreementKey, nickname: nickname) {
            return identity
        }
        let identity = Identity(nickname: nickname)
        defaults.set(identity.signingKey.rawRepresentation, forKey: signingKeyKey)
        defaults.set(identity.agreementKey.rawRepresentation, forKey: agreementKeyKey)
        defaults.set(nickname, forKey: nicknameKey)
        return identity
    }

    static func saveNickname(_ nickname: String) {
        defaults.set(nickname, forKey: nicknameKey)
    }
}
