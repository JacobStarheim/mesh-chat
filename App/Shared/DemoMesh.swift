import Foundation
import MeshCore

/// Demo mode (launch with `-demo`): runs the real MeshRouter over an in-memory
/// network with a few virtual neighbours, so the app can be tried without
/// Bluetooth or a second device. Topology:
///
///     dave ── you ── alice ── bob ── carol
///
/// Messages from carol reach you via two relays, exactly as they would over BLE.
final class DemoMesh {
    let transport: SimulatedTransport
    private let network = SimulatedNetwork()
    private var routers: [String: MeshRouter] = [:]
    private var bots: [Bot] = []

    init() {
        transport = network.makeTransport(name: "you")
        var transports = ["you": transport]
        for name in ["alice", "bob", "carol", "dave"] {
            let peerTransport = network.makeTransport(name: name)
            let router = MeshRouter(identity: Identity(nickname: name), transport: peerTransport)
            let bot = Bot(deliver: { [weak network] in network?.run() })
            router.delegate = bot
            transports[name] = peerTransport
            routers[name] = router
            bots.append(bot)
        }
        for (a, b) in [("you", "alice"), ("alice", "bob"), ("bob", "carol"), ("you", "dave")] {
            network.connect(transports[a]!, transports[b]!)
        }
    }

    /// Starts the virtual neighbours and plays a short conversation.
    /// Call after the user's own router has started.
    func start() {
        routers.values.forEach { $0.start() }
        run()

        let script: [(String, String)] = [
            ("alice", "Anyone else here with no signal? The mobile network at the festival is completely down."),
            ("bob", "Same here. Meet by the food trucks at 8?"),
            ("carol", "I'm by the main stage. This message hopped through two phones to reach you."),
            ("dave", "Food trucks works for me."),
        ]
        for (index, (name, text)) in script.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 * Double(index + 1)) { [weak self] in
                _ = try? self?.routers[name]?.sendPublic(text)
                self?.run()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
            guard let self, let carol = routers["carol"],
                  let yourKey = yourPublicKey(seenBy: carol), let you = carol.peers[yourKey]
            else { return }
            _ = try? carol.sendDirect("Can you save me a spot? Battery at 9 %, going quiet for a bit.", to: you)
            run()
        }
    }

    /// Delivers everything queued on the simulated radio.
    func run() {
        network.run()
    }

    private func yourPublicKey(seenBy router: MeshRouter) -> Data? {
        let neighbours = Set(routers.values.map(\.identity.publicKey))
        return router.peers.keys.first { !neighbours.contains($0) }
    }
}

/// A virtual neighbour that answers direct messages.
private final class Bot: MeshRouterDelegate {
    private let deliver: () -> Void

    init(deliver: @escaping () -> Void) {
        self.deliver = deliver
    }

    func router(_ router: MeshRouter, didReceive message: ReceivedMessage) {
        guard message.isDirect, let sender = router.peers[message.sender] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak router, deliver] in
            _ = try? router?.sendDirect("Got it, thanks!", to: sender)
            deliver()
        }
    }
}
