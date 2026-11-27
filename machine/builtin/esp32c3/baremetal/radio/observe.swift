import CoreBluetooth
import Foundation

final class Observer: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager!
    private let service: CBUUID

    init(service: UUID) {
        self.service = CBUUID(string: service.uuidString)
        super.init()
        manager = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("Bluetooth ready. Looking for \(service.uuidString)")
            fflush(stdout)
            central.scanForPeripherals(withServices: [service])
        case .unsupported, .unauthorized, .poweredOff:
            print("Bluetooth unavailable (state \(central.state.rawValue), authorization \(CBCentralManager.authorization.rawValue))")
            exit(2)
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard services.contains(service) else { return }
        print("BLE PASS \(service.uuidString) RSSI \(RSSI) dBm")
        central.stopScan()
        exit(0)
    }
}

guard CommandLine.arguments.count == 2, let service = UUID(uuidString: CommandLine.arguments[1]) else {
    print("Usage: c3-ble-observer SERVICE_UUID")
    exit(2)
}
let observer = Observer(service: service)
DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
    print("No matching BLE advertisement within 30 seconds")
    exit(1)
}
withExtendedLifetime(observer) { RunLoop.main.run() }
