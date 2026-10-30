import Foundation

/// Identifies one direct radio link to a neighbour.
public typealias LinkID = String

/// Moves whole packets between direct neighbours. The router doesn't care whether
/// that's Bluetooth, Wi-Fi or an in-memory test network.
public protocol MeshTransport: AnyObject {
    var delegate: MeshTransportDelegate? { get set }
    func start()
    func stop()
    func send(_ packet: Data, to link: LinkID)
}

public protocol MeshTransportDelegate: AnyObject {
    func transport(_ transport: MeshTransport, didConnect link: LinkID)
    func transport(_ transport: MeshTransport, didDisconnect link: LinkID)
    func transport(_ transport: MeshTransport, didReceive packet: Data, from link: LinkID)
}
