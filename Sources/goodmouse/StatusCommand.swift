import ArgumentParser
import Foundation
import GoodMouseKit

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Compare desired against live values, per key."
    )

    @OptionGroup var options: ConfigOptions

    @Flag(name: .long, help: "Also report what the kernel's acceleration filter says it built, from the unified log.")
    var filterDebug = false

    @Option(name: .long, help: "How far back to read filter log lines, in seconds.")
    var logSeconds: Int = 60

    func run() throws {
        let config = try options.load()
        let monitor = try Runtime.monitor()
        let devices = Runtime.resolved(config: config, monitor: monitor)
        Runtime.warnIfNoMatches(devices)

        var anyDrift = false
        for device in devices {
            print("\(device.info.displayName)  →  profile \"\(device.profileName)\"")
            let plan = WritePlanner.plan(for: device.profile, on: device.service)

            var rows: [[String]] = [["", "KEY", "DESIRED", "LIVE"]]
            for write in plan {
                let live = device.service.copyProperty(write.key)
                let drifted = live != write.value
                anyDrift = anyDrift || drifted
                rows.append([
                    drifted ? "DRIFT" : "ok",
                    write.key,
                    write.value.displayString(forKey: write.key),
                    live?.displayString(forKey: write.key) ?? "(absent)",
                ])
            }
            print(Table.render(rows, indent: "  "))

            print("")
        }

        if filterDebug {
            reportFilterLog(seconds: logSeconds)
        }

        if anyDrift {
            throw ExitCode(1)
        }
    }

    /// The key/value table above compares *stored* properties. It cannot see whether the filter
    /// actually rebuilt its accelerator, so a setting can read "ok" everywhere and still not be in
    /// force. This is the only outside view of what the kernel built.
    private func reportFilterLog(seconds: Int) {
        print("Kernel filter log (last \(seconds)s) — what the acceleration filter reports building:")
        do {
            let entries = try FilterLog.recentAccelerationLines(seconds: seconds)
            guard !entries.isEmpty else {
                print("""
                  (nothing in the window — the filter only logs when it rebuilds. Run
                  `goodmouse apply` against a changed config, then look again.)
                """)
                return
            }
            for entry in entries {
                print("  \(entry.timestamp)  \(entry.message)")
            }
            print("""

              "enabled" means an accelerator was built; "disabled" means the acceleration value was
              negative and motion is passing through raw. The key named first is the one the filter
              resolved the value from.
            """)
        } catch {
            print("  (could not read the log: \(error.localizedDescription))")
        }
    }
}

