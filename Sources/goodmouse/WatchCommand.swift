import ArgumentParser
import Foundation
import GoodMouseKit

struct Watch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Stay running and keep the config asserted. The launchd agent entry point."
    )

    @OptionGroup var options: ConfigOptions

    @Option(name: .long, help: "Seconds between reconcile passes.")
    var interval: Double = 5

    func run() throws {
        let config = try options.load()
        let monitor = try Runtime.monitor()
        let applicator = Applicator()

        // Under launchd stdout is a file, which is block-buffered — log lines would sit unwritten
        // for a long time. Line buffering makes both the agent log and an interactive run readable.
        setvbuf(stdout, nil, _IOLBF, 0)

        // Ignoring the signal first is required: without it the dispatch source never fires and
        // restore() is skipped on shutdown.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let queue = monitor.callbackQueue

        /// Everything worth saying goes to both stdout and the unified log: stdout so a foreground
        /// run and the agent's log file show progress, os_log so it is greppable after the fact.
        func report(_ message: String) {
            print("\(Self.timestamp())  \(message)")
            Log.monitor.info("\(message, privacy: .public)")
        }

        /// Applies the config to every service the config claims. Confined to the callback queue.
        func reconcile(reason: String) {
            for device in Runtime.resolved(config: config, monitor: monitor) {
                let plan = WritePlanner.plan(for: device.profile, on: device.service)
                // The comparison inside apply() is the loop guard: our own writes come back through
                // the property-changed callback, so writing unconditionally would spin.
                let result = applicator.apply(plan, to: device.service)
                if result.changedAnything {
                    let keys = result.written.map(\.key).joined(separator: ", ")
                    report("\(reason): reasserted \(result.written.count) key(s) on \(device.info.displayName) — \(keys)")
                }
                for write in result.failed {
                    report("FAILED to write \(write.key) on \(device.info.displayName)")
                }
            }
        }

        monitor.start(
            onAppear: { service in
                report("device appeared: \(service.info.displayName)")
                reconcile(reason: "device appeared")
            },
            onRemove: { registryID in
                report("device removed: \(String(format: "0x%llx", registryID))")
            },
            onPropertyChange: {
                reconcile(reason: "property changed")
            }
        )

        // A periodic pass catches drift no callback reported — a setting changed while asleep, or
        // by something that wrote it without going through the event system.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { reconcile(reason: "reconcile") }
        timer.resume()

        // Both signal sources deliver onto `queue`, so this closure is *already running on it*.
        // Wrapping the body in `queue.sync` deadlocks — libdispatch detects the self-wait and traps
        // with an illegal instruction rather than hanging. Run the work directly.
        let shutdown = { (name: String) in
            report("\(name): restoring original values")
            for device in Runtime.resolved(config: config, monitor: monitor) {
                let result = applicator.restore(device.service)
                report("restored \(result.written.count) key(s) on \(device.info.displayName)")
            }
            report("goodmouse stopped")
            Foundation.exit(0)
        }

        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        term.setEventHandler { shutdown("SIGTERM") }
        term.resume()

        let int = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        int.setEventHandler { shutdown("SIGINT") }
        int.resume()

        report("goodmouse watching — reconcile every \(Format.number(interval))s, Ctrl-C to stop and restore")
        dispatchMain()
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}

