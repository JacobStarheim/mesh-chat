import Foundation

public struct ReceivedMessage: Identifiable, Equatable {
    public let id: Data
    public let sender: Data
    public let text: String
    public let isDirect: Bool
    public let sentAt: Date
    /// How many other devices relayed the message before it reached us. 0 = direct neighbour.
    public let relays: Int
}

public protocol MeshRouterDelegate: AnyObject {
    func router(_ router: MeshRouter, didReceive message: ReceivedMessage)
    func routerDidUpdatePeers(_ router: MeshRouter)
    func routerDidUpdateLinks(_ router: MeshRouter)
}

public extension MeshRouterDelegate {
    func routerDidUpdatePeers(_ router: MeshRouter) {}
    func routerDidUpdateLinks(_ router: MeshRouter) {}
}

/// The mesh itself: flooding with a hop limit, duplicate suppression, signature
/// checks and store-and-forward. Not thread-safe; call it from one queue
/// (the BLE transport delivers everything on the main queue).
public final class MeshRouter {
    public struct Configuration {
        /// Hops a new packet may travel. bitchat uses 7.
        public var defaultTTL: UInt8 = 7
        /// Packets claiming a higher hop limit are dropped, so nobody can flood the whole city.
        public var maxTTL: UInt8 = 10
        public var seenCapacity = 4096
        /// Packets kept for neighbours we meet later.
        public var storeCapacity = 300
        /// Packets older than this are neither accepted nor handed on.
        public var storeLifetime: TimeInterval = 6 * 60 * 60
        public var maxFutureSkew: TimeInterval = 5 * 60
        public var maxMessageBytes = 500
        /// Re-announce when a new neighbour shows up and our last announce is older than this.
        public var announceRefreshInterval: TimeInterval = 10 * 60

        public init() {}
    }

    public struct Stats: Equatable {
        public var accepted = 0
        public var duplicates = 0
        public var rejected = 0
        public var relayed = 0
    }

    public enum SendError: Error, Equatable {
        case emptyMessage
        case messageTooLong
    }

    public weak var delegate: MeshRouterDelegate?
    public private(set) var identity: Identity
    public private(set) var peers: [Data: Peer] = [:]
    public private(set) var links: Set<LinkID> = []
    public private(set) var stats = Stats()

    private let transport: MeshTransport
    private let configuration: Configuration
    private let now: () -> Date
    private var seen: SeenCache
    /// Messages to hand to neighbours we meet later, oldest first.
    private var store: [Packet] = []
    /// Newest announce per sender (including our own), so newcomers learn who's around.
    private var announces: [Data: Packet] = [:]

    public init(
        identity: Identity,
        transport: MeshTransport,
        configuration: Configuration = Configuration(),
        now: @escaping () -> Date = Date.init
    ) {
        self.identity = identity
        self.transport = transport
        self.configuration = configuration
        self.now = now
        self.seen = SeenCache(capacity: configuration.seenCapacity)
    }

    public func start() {
        transport.delegate = self
        announce()
        transport.start()
    }

    public func stop() {
        transport.stop()
        links.removeAll()
        delegate?.routerDidUpdateLinks(self)
    }

    public func setNickname(_ nickname: String) {
        identity.nickname = nickname
        announce()
    }

    public func announce() {
        let payload = AnnouncePayload.encode(
            agreementKey: identity.agreementKey.publicKey.rawRepresentation,
            nickname: identity.nickname
        )
        originate(Packet(type: .announce, ttl: configuration.defaultTTL, payload: payload, signedBy: identity, date: now()))
    }

    @discardableResult
    public func sendPublic(_ text: String, ttl: UInt8? = nil) throws -> Packet {
        let body = try validated(text)
        let hopLimit = min(ttl ?? configuration.defaultTTL, configuration.maxTTL)
        let packet = Packet(type: .message, ttl: hopLimit, payload: body, signedBy: identity, date: now())
        originate(packet)
        return packet
    }

    @discardableResult
    public func sendDirect(_ text: String, to peer: Peer) throws -> Packet {
        let body = try validated(text)
        let id = Data.random(count: Packet.idLength)
        let sealed = try DirectMessageCrypto.seal(body, to: peer.agreementKey, associatedData: id + identity.publicKey)
        let packet = Packet(
            type: .direct,
            ttl: configuration.defaultTTL,
            recipient: peer.fingerprint,
            payload: sealed,
            signedBy: identity,
            id: id,
            date: now()
        )
        originate(packet)
        return packet
    }

    // MARK: - Internals

    private func validated(_ text: String) throws -> Data {
        let body = Data(text.utf8)
        guard !body.isEmpty else { throw SendError.emptyMessage }
        guard body.count <= configuration.maxMessageBytes else { throw SendError.messageTooLong }
        return body
    }

    private func originate(_ packet: Packet) {
        seen.insert(packet.id)
        remember(packet)
        broadcast(packet, except: nil)
    }

    private func broadcast(_ packet: Packet, except excluded: LinkID?) {
        let bytes = packet.encoded()
        for link in links where link != excluded {
            transport.send(bytes, to: link)
        }
    }

    private func handle(_ packet: Packet, from link: LinkID) {
        if seen.contains(packet.id) {
            stats.duplicates += 1
            return
        }
        // Verify before marking as seen: otherwise a forged copy that arrives first
        // could block the genuine packet with the same ID.
        guard isAcceptable(packet) else {
            stats.rejected += 1
            return
        }
        seen.insert(packet.id)
        stats.accepted += 1
        if let lastSeen = peers[packet.sender]?.lastSeen, packet.date > lastSeen {
            peers[packet.sender]?.lastSeen = packet.date
        }

        var isForUsOnly = false
        switch packet.type {
        case .announce:
            learnPeer(from: packet)
        case .message:
            deliver(packet, text: String(decoding: packet.payload, as: UTF8.self), isDirect: false)
        case .direct:
            if packet.recipient == identity.fingerprint {
                isForUsOnly = true
                if let plaintext = try? DirectMessageCrypto.open(
                    packet.payload,
                    with: identity.agreementKey,
                    associatedData: packet.id + packet.sender
                ) {
                    deliver(packet, text: String(decoding: plaintext, as: UTF8.self), isDirect: true)
                }
            }
        }

        guard !isForUsOnly, packet.ttl > 1 else { return }
        var relay = packet
        relay.ttl -= 1
        remember(relay)
        if links.contains(where: { $0 != link }) {
            stats.relayed += 1
            broadcast(relay, except: link)
        }
    }

    private func isAcceptable(_ packet: Packet) -> Bool {
        guard packet.sender != identity.publicKey,
              packet.hopLimit <= configuration.maxTTL,
              packet.ttl >= 1, packet.ttl <= packet.hopLimit
        else { return false }
        let age = now().timeIntervalSince(packet.date)
        guard age < configuration.storeLifetime, age > -configuration.maxFutureSkew else { return false }
        return packet.hasValidSignature()
    }

    private func learnPeer(from packet: Packet) {
        guard let (agreementKey, nickname) = AnnouncePayload.decode(packet.payload) else { return }
        if let known = announces[packet.sender], known.timestamp > packet.timestamp {
            return
        }
        peers[packet.sender] = Peer(
            publicKey: packet.sender,
            nickname: nickname,
            agreementKey: agreementKey,
            lastSeen: max(peers[packet.sender]?.lastSeen ?? .distantPast, packet.date)
        )
        announces[packet.sender] = packet
        delegate?.routerDidUpdatePeers(self)
    }

    private func deliver(_ packet: Packet, text: String, isDirect: Bool) {
        let message = ReceivedMessage(
            id: packet.id,
            sender: packet.sender,
            text: text,
            isDirect: isDirect,
            sentAt: packet.date,
            relays: packet.hops
        )
        delegate?.router(self, didReceive: message)
    }

    private func remember(_ packet: Packet) {
        if packet.type == .announce {
            if let known = announces[packet.sender], known.timestamp > packet.timestamp { return }
            announces[packet.sender] = packet
            return
        }
        store.append(packet)
        if store.count > configuration.storeCapacity {
            store.removeFirst(store.count - configuration.storeCapacity)
        }
    }

    private func dropExpired() {
        let cutoff = now().addingTimeInterval(-configuration.storeLifetime)
        store.removeAll { $0.date < cutoff }
        announces = announces.filter { $0.value.date >= cutoff }
    }
}

extension MeshRouter: MeshTransportDelegate {
    public func transport(_ transport: MeshTransport, didConnect link: LinkID) {
        if let own = announces[identity.publicKey],
           now().timeIntervalSince(own.date) > configuration.announceRefreshInterval {
            announce()
        }
        links.insert(link)
        delegate?.routerDidUpdateLinks(self)

        // Store-and-forward: hand the newcomer everything we're carrying.
        // Packets it has already seen are dropped by its duplicate check.
        dropExpired()
        for packet in announces.values.sorted(by: { $0.timestamp < $1.timestamp }) + store {
            transport.send(packet.encoded(), to: link)
        }
    }

    public func transport(_ transport: MeshTransport, didDisconnect link: LinkID) {
        links.remove(link)
        delegate?.routerDidUpdateLinks(self)
    }

    public func transport(_ transport: MeshTransport, didReceive packet: Data, from link: LinkID) {
        guard let decoded = try? Packet(decoding: packet) else {
            stats.rejected += 1
            return
        }
        handle(decoded, from: link)
    }
}
