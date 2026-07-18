import Foundation
import IOKit
import IOKit.serial
import VibeStickSetupCore

public protocol SerialDeviceDiscovering: Sendable {
    func discover() -> [SerialDevice]
}

public struct IOKitSerialDiscovery: SerialDeviceDiscovering, Sendable {
    public init() {}

    public func discover() -> [SerialDevice] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        (matching as NSMutableDictionary)[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var devices: [SerialDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = stringProperty(service, key: kIOCalloutDeviceKey),
                  path.hasPrefix("/dev/cu.") else { continue }

            var registryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &registryID)
            let vendorID = intProperty(service, key: "idVendor", recursive: true)
            let productID = intProperty(service, key: "idProduct", recursive: true)
            let productName = stringProperty(service, key: "USB Product Name", recursive: true)
                ?? stringProperty(service, key: "IOTTYDevice")
                ?? URL(fileURLWithPath: path).lastPathComponent
            let serial = stringProperty(service, key: "USB Serial Number", recursive: true)

            devices.append(
                SerialDevice(
                    id: registryID == 0 ? stableFallbackID(path) : registryID,
                    calloutPath: path,
                    name: productName,
                    vendorID: vendorID,
                    productID: productID,
                    serialNumber: serial
                )
            )
        }

        return devices.sorted {
            if $0.isEspressifUSB != $1.isEspressifUSB { return $0.isEspressifUSB }
            return $0.calloutPath.localizedStandardCompare($1.calloutPath) == .orderedAscending
        }
    }

    private func property(_ service: io_registry_entry_t, key: String, recursive: Bool) -> AnyObject? {
        if recursive {
            return IORegistryEntrySearchCFProperty(
                service,
                kIOServicePlane,
                key as CFString,
                kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            )
        }
        return IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
    }

    private func stringProperty(_ service: io_registry_entry_t, key: String, recursive: Bool = false) -> String? {
        property(service, key: key, recursive: recursive) as? String
    }

    private func intProperty(_ service: io_registry_entry_t, key: String, recursive: Bool = false) -> Int? {
        (property(service, key: key, recursive: recursive) as? NSNumber)?.intValue
    }

    private func stableFallbackID(_ value: String) -> UInt64 {
        value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}
