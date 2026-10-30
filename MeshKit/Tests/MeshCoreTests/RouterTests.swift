import XCTest
@testable import MeshCore

private final class Inbox: MeshRouterDelegate {
    var messages: [ReceivedMessage] = []

    func router(_ router: MeshRouter, didReceive message: ReceivedMessage) {
        messages.append(message)
    }
}

/// A handful of routers on a simulated network.
private struct Mesh {
    let network: SimulatedNetwork
    let transports: [SimulatedTransport]
    let routers: [MeshRouter]
    let inboxes: [Inbox]

    init(count: Int, lossRate: Double = 0) {
        let network = SimulatedNetwork(lossRate: lossRate)
        let transports = (0..<count).map { network.makeTransport(name: "n\($0)") }
        let routers = transports.enumerated().map { MeshRouter(identity: Identity(nickname: "n\($0.offset)"), transport: $0.element) }
        let inboxes = routers.map { _ in Inbox() }
        for (router, inbox) in zip(routers, inboxes) {
            router.delegate = inbox
        }
        self.network = network
        self.transports = transports
        self.routers = routers
        self.inboxes = inboxes
    }

    func link(_ a: Int, _ b: Int) {
        network.connect(transports[a], transports[b])
    }

    func linkInALine() {
        for i in 0..<(routers.count - 1) { link(i, i + 1) }
    }

    func startAll() {
        routers.forEach { $0.start() }
        network.run()
    }
}

final class RouterTests: XCTestCase {
    func testMessageCrossesFiveNodesInALine() throws {
        let mesh = Mesh(count: 5)
        mesh.linkInALine()
        mesh.startAll()

        try mesh.routers[0].sendPublic("hei alle")
        mesh.network.run()

        for i in 1..<5 {
            XCTAssertEqual(mesh.inboxes[i].messages.map(\.text), ["hei alle"], "node \(i)")
            XCTAssertEqual(mesh.inboxes[i].messages.first?.relays, i - 1)
        }
        XCTAssertTrue(mesh.inboxes[0].messages.isEmpty, "sender must not receive its own echo")
    }

    func testTTLLimitsHowFarAMessageTravels() throws {
        let mesh = Mesh(count: 5)
        mesh.linkInALine()
        mesh.startAll()

        try mesh.routers[0].sendPublic("kort rekkevidde", ttl: 2)
        mesh.network.run()

        XCTAssertEqual(mesh.inboxes.map(\.messages.count), [0, 1, 1, 0, 0])
    }

    func testEachNodeHandlesAMessageOnceEvenInALoop() throws {
        let mesh = Mesh(count: 6)
        mesh.linkInALine()
        mesh.link(5, 0)  // close the ring
        mesh.link(1, 4)  // and add a shortcut
        mesh.startAll()

        try mesh.routers[0].sendPublic("en gang")
        mesh.network.run()

        XCTAssertEqual(mesh.inboxes.dropFirst().map(\.messages.count), [1, 1, 1, 1, 1])
        XCTAssertGreaterThan(mesh.routers.map(\.stats.duplicates).reduce(0, +), 0)
    }

    func testDirectMessageIsRelayedButOnlyReadableByRecipient() throws {
        let mesh = Mesh(count: 3)
        mesh.linkInALine()
        mesh.startAll()

        let carol = try XCTUnwrap(mesh.routers[0].peers[mesh.routers[2].identity.publicKey], "announces should introduce peers")
        try mesh.routers[0].sendDirect("bare til deg", to: carol)
        mesh.network.run()

        XCTAssertEqual(mesh.inboxes[2].messages.map(\.text), ["bare til deg"])
        XCTAssertEqual(mesh.inboxes[2].messages.first?.isDirect, true)
        XCTAssertTrue(mesh.inboxes[1].messages.isEmpty, "the relay must not see the plaintext")
        XCTAssertGreaterThan(mesh.routers[1].stats.relayed, 0)
    }

    func testStoreAndForwardReachesANodeThatArrivesLater() throws {
        let mesh = Mesh(count: 3)
        mesh.link(0, 1)
        mesh.startAll()

        try mesh.routers[0].sendPublic("noen der?")
        mesh.network.run()
        XCTAssertTrue(mesh.inboxes[2].messages.isEmpty)

        // Node 2 walks into range of node 1 after the message was sent.
        mesh.link(1, 2)
        mesh.network.run()
        XCTAssertEqual(mesh.inboxes[2].messages.map(\.text), ["noen der?"])
    }

    func testForgedPacketIsRejectedAndNotRelayed() throws {
        let mesh = Mesh(count: 3)
        mesh.linkInALine()
        mesh.startAll()

        let mallory = Identity(nickname: "mallory")
        var bytes = Packet(type: .message, ttl: 7, payload: Data("ekte".utf8), signedBy: mallory).encoded()
        bytes[bytes.endIndex - Packet.signatureLength - 1] ^= 0x01
        mesh.routers[1].transport(mesh.transports[1], didReceive: bytes, from: "n0")
        mesh.network.run()

        XCTAssertTrue(mesh.inboxes[1].messages.isEmpty)
        XCTAssertTrue(mesh.inboxes[2].messages.isEmpty)
        XCTAssertEqual(mesh.routers[1].stats.rejected, 1)
    }

    func testRejectsHopLimitAboveMaximum() throws {
        let mesh = Mesh(count: 2)
        mesh.link(0, 1)
        mesh.startAll()

        let spammer = Identity(nickname: "spam")
        let bytes = Packet(type: .message, ttl: 50, payload: Data("x".utf8), signedBy: spammer).encoded()
        mesh.routers[1].transport(mesh.transports[1], didReceive: bytes, from: "n0")
        XCTAssertTrue(mesh.inboxes[1].messages.isEmpty)
    }

    func testNicknameChangeReachesPeers() throws {
        let mesh = Mesh(count: 3)
        mesh.linkInALine()
        mesh.startAll()

        mesh.routers[2].setNickname("carol")
        mesh.network.run()

        XCTAssertEqual(mesh.routers[0].peers[mesh.routers[2].identity.publicKey]?.nickname, "carol")
    }

    func testRejectsOversizedMessage() {
        let mesh = Mesh(count: 1)
        XCTAssertThrowsError(try mesh.routers[0].sendPublic(String(repeating: "a", count: 501))) { error in
            XCTAssertEqual(error as? MeshRouter.SendError, .messageTooLong)
        }
    }
}
