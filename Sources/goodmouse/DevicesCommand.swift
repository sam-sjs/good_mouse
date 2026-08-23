import ArgumentParser
import Foundation
import GoodMouseKit

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "List pointing devices the HID event system can see."
    )

    @OptionGroup var options: ConfigOptions

    func run() throws {
        let monitor = try Runtime.monitor()
        let services = monitor.pointingServices()
        // A missing or broken config should not stop the device list from printing — this command
        // is the first thing to reach for when something is wrong.
        let config = try? options.load()

        guard !services.isEmpty else {
            print("No pointing devices found.")
            return
        }

        var rows: [[String]] = [["DEVICE", "VID:PID", "TRANSPORT", "REGISTRY", "RESOLUTION", "ACCEL TYPE", "ACCEL", "PROFILE"]]
        for service in services {
            let info = service.info
            let match = config?.profile(for: info)
            let ids: String = info.vendorID.map {
                String(format: "%04x:%04x", $0, info.productID ?? 0)
            } ?? "—"
            // The whole diagnostic in one column: a device with no transport is invisible to every
            // tool that keys devices as vendor-product-transport.
            let transport: String = info.transport ?? "—"
            let registry = String(format: "0x%llx", info.registryID)
            let resolution: String = service.fixed(HIDKeys.pointerResolution).map(Format.number) ?? "—"
            let accelType: String = service.string(HIDKeys.pointerAccelerationType) ?? "—"
            let accel: String = service.fixed(service.pointerAccelerationKey).map(Format.number) ?? "—"
            let profileName: String = match?.name ?? "—"

            rows.append([info.displayName, ids, transport, registry, resolution, accelType, accel, profileName])
        }
        print(Table.render(rows))

        if config == nil {
            print("\nNo usable config, so the PROFILE column is empty. Run `goodmouse write-default-config`.")
        } else if rows.dropFirst().allSatisfy({ $0.last == "—" }) {
            print("\nNo device matches any rule. Check the `devices` rules against the DEVICE column above.")
        }
    }
}

