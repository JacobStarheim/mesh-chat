import BLETransport
import Foundation
import MeshCore
import Observation

/// The public channel or a direct-message thread with one person.
enum Conversation: Hashable {
    case everyone
    case direct(Data)
}

struct ChatLine: Identifiable, Equatable {
    let id: Data
    let author: String
    let text: String
    let date: Date
    /// How many devices relayed it to us; nil for our own messages.
    let relays: Int?
    let isMine: Bool
}

/// Glue between the mesh router and the UI. Everything runs on the main thread:
/// CoreBluetooth calls back on the main queue, and so does the router.
@Observable
final class ChatModel {
    private(set) var lines: [Conversation: [ChatLine]] = [:]
    private(set) var peers: [Peer] = []
    private(set) var linkCount = 0
    private(set) var status: BLEMeshTransport.Status = .off
    private(set) var unread: Set<Conversation> = []
    private(set) var nickname: String
    var lastError: String?
    var selection: Conversation? = .everyone {
        didSet { if let selection { unread.remove(selection) } }
    }

    private let transport = BLEMeshTransport()
    private let router: MeshRouter
    private var started = false

    init() {
        let identity = IdentityStore.loadOrCreate()
        nickname = identity.nickname
        router = MeshRouter(identity: identity, transport: transport)
        router.delegate = self
        transport.onStatusChange = { [weak self] status in
            self?.status = status
        }
    }

    var myName: String { "\(nickname)#\(Fingerprint.short(router.identity.publicKey))" }
    var fingerprint: String { router.identity.fingerprint.map { String(format: "%02x", $0) }.joined() }

    /// Direct threads with people we've heard from, plus anyone who messaged us
    /// before we received their announce.
    var directConversations: [Data] {
        let known = peers.map(\.publicKey)
        let others = lines.keys.compactMap { conversation -> Data? in
            if case let .direct(key) = conversation, !known.contains(key) { return key }
            return nil
        }
        return known + others
    }

    func start() {
        guard !started else { return }
        started = true
        router.start()
    }

    func canSend(in conversation: Conversation) -> Bool {
        switch conversation {
        case .everyone: return true
        case let .direct(key): return router.peers[key] != nil
        }
    }

    func send(_ text: String, in conversation: Conversation) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let packet: Packet
            switch conversation {
            case .everyone:
                packet = try router.sendPublic(trimmed)
            case let .direct(key):
                guard let peer = router.peers[key] else { return }
                packet = try router.sendDirect(trimmed, to: peer)
            }
            append(
                ChatLine(id: packet.id, author: myName, text: trimmed, date: packet.date, relays: nil, isMine: true),
                to: conversation
            )
        } catch MeshRouter.SendError.messageTooLong {
            lastError = "That message is too long. The limit is 500 bytes."
        } catch {
            lastError = error.localizedDescription
        }
    }

    func rename(to newName: String) {
        let trimmed = String(newName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        guard !trimmed.isEmpty, trimmed != nickname else { return }
        nickname = trimmed
        IdentityStore.saveNickname(trimmed)
        router.setNickname(trimmed)
    }

    func title(for conversation: Conversation) -> String {
        switch conversation {
        case .everyone: return "Everyone"
        case let .direct(key): return displayName(for: key)
        }
    }

    func displayName(for key: Data) -> String {
        router.peers[key]?.displayName ?? "unknown#\(Fingerprint.short(key))"
    }

    func peer(for key: Data) -> Peer? {
        router.peers[key]
    }

    private func append(_ line: ChatLine, to conversation: Conversation) {
        var thread = lines[conversation] ?? []
        thread.append(line)
        // Store-and-forward can deliver old messages late, so keep threads in send order.
        thread.sort { $0.date < $1.date }
        lines[conversation] = thread
        if conversation != selection {
            unread.insert(conversation)
        }
    }
}

extension ChatModel: MeshRouterDelegate {
    func router(_ router: MeshRouter, didReceive message: ReceivedMessage) {
        let conversation: Conversation = message.isDirect ? .direct(message.sender) : .everyone
        let line = ChatLine(
            id: message.id,
            author: displayName(for: message.sender),
            text: message.text,
            date: message.sentAt,
            relays: message.relays,
            isMine: false
        )
        append(line, to: conversation)
    }

    func routerDidUpdatePeers(_ router: MeshRouter) {
        peers = router.peers.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    func routerDidUpdateLinks(_ router: MeshRouter) {
        linkCount = router.links.count
    }
}

extension BLEMeshTransport.Status {
    var label: String {
        switch self {
        case .off: return "Off"
        case .starting: return "Starting Bluetooth…"
        case .ready: return "Bluetooth on"
        case .poweredOff: return "Bluetooth is turned off"
        case .unauthorized: return "Bluetooth not allowed. Enable it in Settings."
        case .unsupported: return "Bluetooth LE isn't available on this device"
        }
    }
}
