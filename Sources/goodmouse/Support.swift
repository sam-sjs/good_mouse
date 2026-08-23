import ArgumentParser
import Foundation
import GoodMouseKit

struct ConfigOptions: ParsableArguments {
    @Option(name: .long, help: "Path to the config file. Defaults to $XDG_CONFIG_HOME/goodmouse/config.json, else ~/.config/goodmouse/config.json.")
    var config: String?

    func load() throws -> Config {
        let (config, warnings) = try ConfigLoader.load(path: config)
        for warning in warnings {
            FileHandle.standardError.write(Data("warning: \(warning.description)\n".utf8))
        }
        return config
    }
}

/// Resolving a device to the profile the config says it should have.
struct ResolvedDevice {
    let service: HIDService
    let info: DeviceInfo
    let profileName: String
    let profile: Profile
}

enum Runtime {
    static func monitor() throws -> HIDServiceMonitor {
        guard let monitor = HIDServiceMonitor() else {
            throw ValidationError("Could not create a HID event system client.")
        }
        return monitor
    }

    /// Pointing services that a config rule claims, optionally narrowed to one profile.
    static func resolved(
        config: Config,
        monitor: HIDServiceMonitor,
        onlyProfile: String? = nil
    ) -> [ResolvedDevice] {
        monitor.pointingServices().compactMap { service in
            let info = service.info
            guard let (name, profile) = config.profile(for: info) else { return nil }
            if let onlyProfile, name != onlyProfile { return nil }
            return ResolvedDevice(service: service, info: info, profileName: name, profile: profile)
        }
    }

    static func warnIfNoMatches(_ devices: [ResolvedDevice]) {
        guard devices.isEmpty else { return }
        FileHandle.standardError.write(Data("""
        No connected pointing device matches any rule in the config.
        Run `goodmouse devices` to see what is present and what each rule would claim.

        """.utf8))
    }
}

/// Prints an apply/restore result. `apply` and `restore` differ only in the verb they use for a
/// write that landed, so the shape lives here rather than in both.
///
/// Returns true when anything failed, so the caller can decide the exit code.
@discardableResult
func printResult(_ result: Applicator.ApplyResult, wroteVerb: String, skippedVerb: String) -> Bool {
    for write in result.written {
        print("  \(wroteVerb) \(write.key) = \(write.value.displayString(forKey: write.key))")
    }
    for write in result.skipped {
        print("  \(skippedVerb) \(write.key)")
    }
    for write in result.failed {
        print("  FAILED  \(write.key) = \(write.value.displayString(forKey: write.key))")
    }
    for write in result.rejected {
        print("  IGNORED \(write.key) — the write was accepted but the device kept its own value")
    }
    if !result.rejected.isEmpty {
        print("""
              Those settings have no effect on this device. The driver republishes them, so nothing
              written through the HID event system survives.
        """)
    }
    return !result.failed.isEmpty
}

// MARK: - Table rendering

enum Table {
    static func render(_ rows: [[String]], indent: String = "") -> String {
        guard let first = rows.first else { return "" }
        let columnCount = first.count
        var widths = [Int](repeating: 0, count: columnCount)
        for row in rows {
            for (i, cell) in row.enumerated() where i < columnCount {
                widths[i] = max(widths[i], cell.count)
            }
        }
        return rows.map { row in
            indent + row.enumerated().map { i, cell in
                i == columnCount - 1 ? cell : cell.padding(toLength: widths[i], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }
}
