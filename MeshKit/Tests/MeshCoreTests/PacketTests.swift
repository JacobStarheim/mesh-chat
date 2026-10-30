import XCTest
@testable import MeshCore

final class PacketTests: XCTestCase {
    let alice = Identity(nickname: "alice")

    func testRoundTripKeepsAllFieldsAndSignature() throws {
        let packet = Packet(type: .message, ttl: 7, payload: Data("hei".utf8), signedBy: alice)
        let decoded = try Packet(decoding: packet.encoded())
        XCTAssertEqual(decoded, packet)
        XCTAssertTrue(decoded.hasValidSignature())
        XCTAssertEqual(decoded.hops, 0)
    }

    func testRoundTripWithRecipient() throws {
        let recipient = Fingerprint.of(Identity(nickname: "bob").publicKey)
        let packet = Packet(type: .direct, ttl: 3, recipient: recipient, payload: Data([1, 2, 3]), signedBy: alice)
        let decoded = try Packet(decoding: packet.encoded())
        XCTAssertEqual(decoded.recipient, recipient)
        XCTAssertTrue(decoded.hasValidSignature())
    }

    func testRelaysCanDecrementTTLWithoutBreakingSignature() throws {
        var packet = Packet(type: .message, ttl: 7, payload: Data("hei".utf8), signedBy: alice)
        packet.ttl = 4
        let decoded = try Packet(decoding: packet.encoded())
        XCTAssertTrue(decoded.hasValidSignature())
        XCTAssertEqual(decoded.hops, 3)
    }

    func testTamperedPayloadFailsSignature() throws {
        let packet = Packet(type: .message, ttl: 7, payload: Data("pay 10 kr".utf8), signedBy: alice)
        var bytes = packet.encoded()
        // Last payload byte sits just before the 64-byte signature.
        bytes[bytes.endIndex - Packet.signatureLength - 1] ^= 0xFF
        let decoded = try Packet(decoding: bytes)
        XCTAssertFalse(decoded.hasValidSignature())
    }

    func testRaisingHopLimitFailsSignature() throws {
        let packet = Packet(type: .message, ttl: 2, payload: Data("x".utf8), signedBy: alice)
        var bytes = packet.encoded()
        bytes[bytes.startIndex + 2] = 10  // hopLimit
        bytes[bytes.startIndex + 3] = 10  // ttl
        XCTAssertFalse(try Packet(decoding: bytes).hasValidSignature())
    }

    func testTruncatedPacketThrows() {
        let bytes = Packet(type: .message, ttl: 7, payload: Data("hei".utf8), signedBy: alice).encoded()
        XCTAssertThrowsError(try Packet(decoding: bytes.dropLast()))
    }

    func testOverheadFitsAFewHundredByteFrame() {
        let bytes = Packet(type: .message, ttl: 7, payload: Data(), signedBy: alice).encoded()
        XCTAssertEqual(bytes.count, 127)
    }
}

final class DirectMessageCryptoTests: XCTestCase {
    let bob = Identity(nickname: "bob")
    let context = Data("packet-id+sender".utf8)

    func testRecipientCanOpen() throws {
        let sealed = try DirectMessageCrypto.seal(Data("hemmelig".utf8), to: bob.agreementKey.publicKey.rawRepresentation, associatedData: context)
        let opened = try DirectMessageCrypto.open(sealed, with: bob.agreementKey, associatedData: context)
        XCTAssertEqual(String(decoding: opened, as: UTF8.self), "hemmelig")
    }

    func testOthersCannotOpen() throws {
        let sealed = try DirectMessageCrypto.seal(Data("hemmelig".utf8), to: bob.agreementKey.publicKey.rawRepresentation, associatedData: context)
        let eve = Identity(nickname: "eve")
        XCTAssertThrowsError(try DirectMessageCrypto.open(sealed, with: eve.agreementKey, associatedData: context))
    }

    func testCiphertextIsBoundToContext() throws {
        let sealed = try DirectMessageCrypto.seal(Data("hemmelig".utf8), to: bob.agreementKey.publicKey.rawRepresentation, associatedData: context)
        XCTAssertThrowsError(try DirectMessageCrypto.open(sealed, with: bob.agreementKey, associatedData: Data("other".utf8)))
    }
}

final class FragmentationTests: XCTestCase {
    func testSmallPacketIsOneFrame() {
        let frames = Fragmenter.frames(for: Data(repeating: 7, count: 100), maxFrameSize: 182, fragmentID: 1)
        XCTAssertEqual(frames.count, 1)
        var reassembler = Reassembler()
        XCTAssertEqual(reassembler.add(frames[0]), Data(repeating: 7, count: 100))
    }

    func testLargePacketSplitsAndReassemblesOutOfOrder() {
        let packet = Data((0..<1000).map { UInt8($0 % 251) })
        let frames = Fragmenter.frames(for: packet, maxFrameSize: 20, fragmentID: 42)
        XCTAssertTrue(frames.allSatisfy { $0.count <= 20 })
        XCTAssertGreaterThan(frames.count, 1)

        var reassembler = Reassembler()
        var result: Data?
        for frame in frames.reversed() {
            result = reassembler.add(frame) ?? result
        }
        XCTAssertEqual(result, packet)
    }

    func testIncompletePacketExpires() {
        let frames = Fragmenter.frames(for: Data(repeating: 1, count: 100), maxFrameSize: 30, fragmentID: 9)
        var reassembler = Reassembler(timeout: 10)
        let start = Date()
        XCTAssertNil(reassembler.add(frames[0], now: start))
        for frame in frames.dropFirst() {
            XCTAssertNil(reassembler.add(frame, now: start.addingTimeInterval(60)))
        }
    }
}
