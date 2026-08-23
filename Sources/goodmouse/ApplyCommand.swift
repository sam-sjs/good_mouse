import ArgumentParser
import Foundation
import GoodMouseKit

struct Apply: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Apply the config to every matching device, once."
    )

    @OptionGroup var options: ConfigOptions

    @Option(name: .long, help: "Only apply this profile.")
    var profile: String?

    @Flag(name: .long, help: "Print the exact writes without performing them.")
    var dryRun = false

    func run() throws {
        let config = try options.load()
        let monitor = try Runtime.monitor()
        let devices = Runtime.resolved(config: config, monitor: monitor, onlyProfile: profile)
        Runtime.warnIfNoMatches(devices)

        let applicator = Applicator()
        for device in devices {
            let plan = WritePlanner.plan(for: device.profile, on: device.service)
            print("\(device.info.displayName)  →  profile \"\(device.profileName)\"")

            if device.profile.pointer?.mode == .linear,
               let reason = WritePlanner.linearModeUnavailableReason(on: device.service) {
                print("  warning: \(reason)")
            }

            if dryRun {
                for (i, write) in plan.enumerated() {
                    let current = device.service.copyProperty(write.key)?.displayString(forKey: write.key) ?? "(absent)"
                    let next = write.value.displayString(forKey: write.key)
                    let marker = device.service.copyProperty(write.key) == write.value ? " " : "*"
                    print("  \(marker) \(i + 1). \(write.key)")
                    print("        now:  \(current)")
                    print("        next: \(next)")
                    if !write.note.isEmpty { print("        why:  \(write.note)") }
                }
                print("  (dry run — nothing written; * marks a change)")
            } else {
                let result = applicator.apply(plan, to: device.service)
                if printResult(result, wroteVerb: "wrote  ", skippedVerb: "already") {
                    throw ExitCode.failure
                }
            }
            print("")
        }
    }
}

