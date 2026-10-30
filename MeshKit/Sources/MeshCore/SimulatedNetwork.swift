import Foundation

/// An in-memory radio network for tests and experiments: wire up any topology,
/// drop frames at random, and count every transmission. Deterministic for a given seed.
public final class SimulatedNetwork {
    private enum Event {
        case connect(SimulatedTransport, LinkID)
        case disconnect(SimulatedTransport, LinkID)
        case frame(SimulatedTransport, Data, from: LinkID)
    }

    public let lossRate: Double
    /// Every frame handed to the radio, including ones that were then lost.
    public private(set) var transmissions = 0

    private var nodes: [LinkID: SimulatedTransport] = [:]
    private var adjacency: [LinkID: Set<LinkID>] = [:]
    private var queue: [Event] = []
    private var queueHead = 0
    private var random: SplitMix64

    public init(lossRate: Double = 0, seed: UInt64 = 1) {
        self.lossRate = lossRate
        self.random = SplitMix64(seed: seed)
    }

    public func makeTransport(name: LinkID) -> SimulatedTransport {
        precondition(nodes[name] == nil, "duplicate node name")
        let transport = SimulatedTransport(name: name, network: self)
        nodes[name] = transport
        adjacency[name] = []
        return transport
    }

    /// Puts two nodes in radio range of each other.
    public func connect(_ a: SimulatedTransport, _ b: SimulatedTransport) {
        guard a !== b, adjacency[a.name]?.contains(b.name) == false else { return }
        adjacency[a.name, default: []].insert(b.name)
        adjacency[b.name, default: []].insert(a.name)
        if a.isRunning && b.isRunning {
            queue.append(.connect(a, b.name))
            queue.append(.connect(b, a.name))
        }
    }

    public func disconnect(_ a: SimulatedTransport, _ b: SimulatedTransport) {
        guard adjacency[a.name]?.remove(b.name) != nil else { return }
        adjacency[b.name]?.remove(a.name)
        queue.append(.disconnect(a, b.name))
        queue.append(.disconnect(b, a.name))
    }

    /// Delivers queued events until the network is quiet.
    public func run(maxEvents: Int = 10_000_000) {
        var processed = 0
        while queueHead < queue.count, processed < maxEvents {
            let event = queue[queueHead]
            queueHead += 1
            processed += 1
            switch event {
            case let .connect(node, link):
                node.delegate?.transport(node, didConnect: link)
            case let .disconnect(node, link):
                node.delegate?.transport(node, didDisconnect: link)
            case let .frame(node, data, link):
                // The link may have gone away while the frame was in flight.
                if adjacency[node.name]?.contains(link) == true {
                    node.delegate?.transport(node, didReceive: data, from: link)
                }
            }
        }
        if queueHead == queue.count {
            queue.removeAll(keepingCapacity: true)
            queueHead = 0
        }
    }

    fileprivate func started(_ node: SimulatedTransport) {
        for neighbour in adjacency[node.name] ?? [] {
            guard let other = nodes[neighbour], other.isRunning else { continue }
            queue.append(.connect(node, other.name))
            queue.append(.connect(other, node.name))
        }
    }

    fileprivate func send(_ data: Data, from sender: SimulatedTransport, to link: LinkID) {
        guard let receiver = nodes[link], adjacency[sender.name]?.contains(link) == true else { return }
        transmissions += 1
        if lossRate > 0, random.nextUnit() < lossRate { return }
        queue.append(.frame(receiver, data, from: sender.name))
    }
}

public final class SimulatedTransport: MeshTransport {
    public weak var delegate: MeshTransportDelegate?
    public let name: LinkID
    fileprivate private(set) var isRunning = false
    private unowned let network: SimulatedNetwork

    fileprivate init(name: LinkID, network: SimulatedNetwork) {
        self.name = name
        self.network = network
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        network.started(self)
    }

    public func stop() {
        isRunning = false
    }

    public func send(_ packet: Data, to link: LinkID) {
        network.send(packet, from: self, to: link)
    }
}

/// Small seedable PRNG so simulations are reproducible.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
