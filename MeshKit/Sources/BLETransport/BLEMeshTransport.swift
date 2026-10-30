import CoreBluetooth
import Foundation
import MeshCore

/// MeshTransport over Bluetooth Low Energy. Every device is both a peripheral
/// (advertises our service, accepts writes, sends notifications) and a central
/// (scans for the service, connects, writes). All callbacks run on the main queue.
///
/// Link IDs are "p:<uuid>" for devices we connected to and "c:<uuid>" for devices
/// that connected to us.
public final class BLEMeshTransport: NSObject, MeshTransport {
    public enum Status: Equatable {
        case off
        case starting
        case ready
        case poweredOff
        case unauthorized
        case unsupported
    }

    public static let serviceUUID = CBUUID(string: "7D48FCFD-7056-4BA3-B597-C9227F8B4921")
    public static let packetCharacteristicUUID = CBUUID(string: "561C4010-0969-4E25-A7BB-F1D07B9F17C0")

    public weak var delegate: MeshTransportDelegate?
    public var onStatusChange: ((Status) -> Void)?
    public private(set) var status: Status = .off {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }

    /// Ignore devices weaker than this; very weak links mostly drop frames.
    public var minimumRSSI = -90

    /// Random per launch. Advertised as the local name and used to decide which side
    /// of a pair connects, so two devices don't open two links to each other.
    private let nodeID = String(UUID().uuidString.prefix(8))

    private var central: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var characteristic: CBMutableCharacteristic?

    // Devices we connect to as a central.
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var remoteCharacteristics: [UUID: CBCharacteristic] = [:]
    // Devices connected to us, subscribed to our characteristic.
    private var centrals: [UUID: CBCentral] = [:]

    private var outbox: [LinkID: [Data]] = [:]
    private var reassemblers: [LinkID: Reassembler] = [:]
    private var nextFragmentID: UInt16 = 0

    public override init() {
        super.init()
    }

    public func start() {
        guard central == nil else { return }
        status = .starting
        // Creating the managers triggers the Bluetooth permission prompt.
        central = CBCentralManager(delegate: self, queue: nil)
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    }

    public func stop() {
        central?.stopScan()
        for peripheral in peripherals.values {
            central?.cancelPeripheralConnection(peripheral)
        }
        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()
        let links = Array(remoteCharacteristics.keys.map(Self.peripheralLink) + centrals.keys.map(Self.centralLink))
        peripherals.removeAll()
        remoteCharacteristics.removeAll()
        centrals.removeAll()
        outbox.removeAll()
        reassemblers.removeAll()
        central = nil
        peripheralManager = nil
        characteristic = nil
        status = .off
        for link in links {
            delegate?.transport(self, didDisconnect: link)
        }
    }

    public func send(_ packet: Data, to link: LinkID) {
        guard let maxFrameSize = maxFrameSize(for: link) else { return }
        nextFragmentID &+= 1
        outbox[link, default: []] += Fragmenter.frames(for: packet, maxFrameSize: maxFrameSize, fragmentID: nextFragmentID)
        flush(link)
    }

    // MARK: - Links

    private static func peripheralLink(_ id: UUID) -> LinkID { "p:\(id.uuidString)" }
    private static func centralLink(_ id: UUID) -> LinkID { "c:\(id.uuidString)" }

    private func maxFrameSize(for link: LinkID) -> Int? {
        if let (peripheral, _) = remotePeripheral(for: link) {
            return peripheral.maximumWriteValueLength(for: .withoutResponse)
        }
        if let central = subscribedCentral(for: link) {
            return central.maximumUpdateValueLength
        }
        return nil
    }

    private func remotePeripheral(for link: LinkID) -> (CBPeripheral, CBCharacteristic)? {
        guard link.hasPrefix("p:"), let id = UUID(uuidString: String(link.dropFirst(2))),
              let peripheral = peripherals[id], let characteristic = remoteCharacteristics[id]
        else { return nil }
        return (peripheral, characteristic)
    }

    private func subscribedCentral(for link: LinkID) -> CBCentral? {
        guard link.hasPrefix("c:"), let id = UUID(uuidString: String(link.dropFirst(2))) else { return nil }
        return centrals[id]
    }

    /// Sends queued frames until BLE flow control says stop. Resumed from the
    /// "ready to send" callbacks.
    private func flush(_ link: LinkID) {
        while let frame = outbox[link]?.first {
            let sent: Bool
            if let (peripheral, characteristic) = remotePeripheral(for: link) {
                guard peripheral.canSendWriteWithoutResponse else { return }
                peripheral.writeValue(frame, for: characteristic, type: .withoutResponse)
                sent = true
            } else if let central = subscribedCentral(for: link), let characteristic, let peripheralManager {
                sent = peripheralManager.updateValue(frame, for: characteristic, onSubscribedCentrals: [central])
            } else {
                outbox[link] = nil
                return
            }
            guard sent else { return }
            outbox[link]?.removeFirst()
        }
    }

    private func receive(_ frame: Data, from link: LinkID) {
        var reassembler = reassemblers[link] ?? Reassembler()
        let packet = reassembler.add(frame)
        reassemblers[link] = reassembler
        if let packet {
            delegate?.transport(self, didReceive: packet, from: link)
        }
    }

    private func linkDidClose(_ link: LinkID) {
        outbox[link] = nil
        reassemblers[link] = nil
        delegate?.transport(self, didDisconnect: link)
    }

    private func updateStatus() {
        let states = [central?.state, peripheralManager?.state].compactMap { $0 }
        if states.contains(.unauthorized) {
            status = .unauthorized
        } else if states.contains(.unsupported) {
            status = .unsupported
        } else if states.contains(.poweredOff) {
            status = .poweredOff
        } else if states.count == 2, states.allSatisfy({ $0 == .poweredOn }) {
            status = .ready
        } else {
            status = .starting
        }
    }

    private func startScanning() {
        central?.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }
}

// MARK: - Central role

extension BLEMeshTransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        updateStatus()
        if central.state == .poweredOn {
            startScanning()
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard peripherals[peripheral.identifier] == nil, RSSI.intValue >= minimumRSSI else { return }
        // Both sides see each other; only the one with the smaller ID connects.
        // In the background iOS drops the local name, so then we connect anyway.
        if let theirID = advertisementData[CBAdvertisementDataLocalNameKey] as? String,
           theirID.count == nodeID.count, theirID < nodeID {
            return
        }
        peripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        peripherals[peripheral.identifier] = nil
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        peripherals[peripheral.identifier] = nil
        if remoteCharacteristics.removeValue(forKey: peripheral.identifier) != nil {
            linkDidClose(Self.peripheralLink(peripheral.identifier))
        }
        // Without duplicate reporting, a scan doesn't re-report a device it has already seen.
        central.stopScan()
        startScanning()
    }
}

extension BLEMeshTransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.packetCharacteristicUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.packetCharacteristicUUID }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.setNotifyValue(true, for: characteristic)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.isNotifying else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        guard remoteCharacteristics[peripheral.identifier] == nil else { return }
        remoteCharacteristics[peripheral.identifier] = characteristic
        delegate?.transport(self, didConnect: Self.peripheralLink(peripheral.identifier))
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let frame = characteristic.value else { return }
        receive(frame, from: Self.peripheralLink(peripheral.identifier))
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        flush(Self.peripheralLink(peripheral.identifier))
    }
}

// MARK: - Peripheral role

extension BLEMeshTransport: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        updateStatus()
        guard peripheral.state == .poweredOn, characteristic == nil else { return }
        let characteristic = CBMutableCharacteristic(
            type: Self.packetCharacteristicUUID,
            properties: [.writeWithoutResponse, .notify],
            value: nil,
            permissions: [.writeable]
        )
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [characteristic]
        self.characteristic = characteristic
        peripheral.add(service)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else { return }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataLocalNameKey: nodeID,
        ])
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard centrals[central.identifier] == nil else { return }
        centrals[central.identifier] = central
        delegate?.transport(self, didConnect: Self.centralLink(central.identifier))
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard centrals.removeValue(forKey: central.identifier) != nil else { return }
        linkDidClose(Self.centralLink(central.identifier))
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // Write-without-response only, so there's nothing to respond to.
        for request in requests {
            guard let frame = request.value else { continue }
            receive(frame, from: Self.centralLink(request.central.identifier))
        }
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        for id in centrals.keys {
            flush(Self.centralLink(id))
        }
    }
}
