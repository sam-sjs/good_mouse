import ArgumentParser
import Foundation
import GoodMouseKit

// MARK: - restore

struct Restore: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Put matching devices back to stock acceleration settings."
    )

    @OptionGroup var options: ConfigOptions

    func run() throws {
        let config = try options.load()
        let monitor = try Runtime.monitor()
        let devices = Runtime.resolved(config: config, monitor: monitor)
        Runtime.warnIfNoMatches(devices)

        // A separate process cannot know what the values were before some earlier `apply` — that
        // history lives only in the applicator that made the writes. What restore can do is put
        // every key this config would touch back to a stock value. `watch` shutting down is the
        // other restore, and it undoes only its own writes.
        let applicator = Applicator()
        for device in devices {
            let plan = WritePlanner.plan(for: device.profile, on: device.service)
            let stock = WritePlanner.stockPlan(for: plan, on: device.service)
            print("\(device.info.displayName)  →  restoring \(stock.count) key(s) to stock")
            printResult(applicator.apply(stock, to: device.service),
                        wroteVerb: "restored", skippedVerb: "already ")

            // Scroll resolution and scroll acceleration are published per device by the driver, so
            // there is no stock value to write. Saying so beats guessing one.
            let untouched = WritePlanner.unrestorableKeys(in: plan, on: device.service)
            if !untouched.isEmpty {
                print("  left alone (no knowable stock value; a replug or dext reload resets these):")
                for key in untouched { print("    \(key)") }
            }
            print("")
        }
    }

}

// MARK: - install-agent / uninstall-agent

struct InstallAgent: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-agent",
        abstract: "Install and load the launchd user agent that runs `goodmouse watch`."
    )

    @OptionGroup var options: ConfigOptions

    func run() throws {
        // Validate before installing: an agent that cannot load its config would just respawn.
        _ = try options.load()

        // launchd needs an absolute path that outlives this process, so resolve argv[0] fully.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path

        try LaunchAgent.install(executablePath: executable, configPath: options.config)
        print("""
        Installed \(LaunchAgent.plistPath)
          runs: \(executable) watch
          logs: \(LaunchAgent.logDirectory)/

        The agent is loaded and will start again at login.
        """)
        if executable.contains("/.build/") {
            print("""

            Note: that path is inside the build directory. Move the binary somewhere stable and \
            re-run install-agent, or the agent will break on the next `swift build`.
            """)
        }
    }
}

struct UninstallAgent: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall-agent",
        abstract: "Unload and remove the launchd user agent."
    )

    func run() throws {
        let (wasLoaded, removed) = try LaunchAgent.uninstall()
        print(wasLoaded ? "Unloaded \(LaunchAgent.serviceTarget)" : "Agent was not loaded")
        print(removed ? "Removed \(LaunchAgent.plistPath)" : "No plist at \(LaunchAgent.plistPath)")
    }
}

// MARK: - write-default-config

struct WriteDefaultConfig: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "write-default-config",
        abstract: "Write a commented starter config."
    )

    @OptionGroup var options: ConfigOptions

    @Flag(name: .long, help: "Overwrite an existing file.")
    var force = false

    func run() throws {
        let path = options.config ?? ConfigLoader.defaultPath
        try DefaultConfig.write(to: path, force: force)
        print("Wrote \(path)")

        // Prove the file we just wrote actually loads, comments and all.
        let (_, warnings) = try ConfigLoader.load(path: path)
        for warning in warnings {
            print("warning: \(warning.description)")
        }
    }
}

