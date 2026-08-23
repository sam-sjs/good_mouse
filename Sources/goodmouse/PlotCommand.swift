import ArgumentParser
import Foundation
import GoodMouseKit

struct PlotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plot",
        abstract: "Draw the acceleration curve a profile produces."
    )

    @OptionGroup var options: ConfigOptions

    @Option(name: .long, help: "Profile to plot. Defaults to the only one, when there is only one.")
    var profile: String?

    @Option(name: .long, help: "Right-hand edge of the plot, in device counts per report.")
    var maxSpeed: Double = 60

    @Option(name: .long, help: "Plot the scroll axis instead of the pointer.")
    var axis: String = "pointer"

    @Flag(name: .long, help: "Also print sampled multipliers.")
    var table = false

    func run() throws {
        let config = try options.load()

        let name: String
        if let profile {
            name = profile
        } else if config.profiles.count == 1, let only = config.profiles.keys.first {
            name = only
        } else {
            throw ValidationError("""
            Several profiles are defined (\(config.profiles.keys.sorted().joined(separator: ", "))). \
            Pass --profile to choose one.
            """)
        }

        guard let profile = config.profiles[name] else {
            throw ValidationError("No profile named \"\(name)\".")
        }

        let kind: AxisKind
        let settings: AxisSettings?
        switch axis {
        case "pointer": kind = .pointer; settings = profile.pointer
        case "scroll": kind = .scroll; settings = profile.scroll
        default: throw ValidationError("--axis must be \"pointer\" or \"scroll\".")
        }

        guard let settings else {
            throw ValidationError("Profile \"\(name)\" has no \(axis) settings.")
        }

        switch settings.mode {
        case .raw:
            print("""
            Profile "\(name)", \(axis): mode "raw".
            No accelerator is built at all, so the multiplier is a flat 1.0 at every speed and
            there is nothing to plot.
            """)
            return
        case .linear:
            print("""
            Profile "\(name)", \(axis): mode "linear".
            A flat multiplier of \(Format.number(settings.acceleration)) at every speed — a
            horizontal line, with resolution ignored. Nothing to plot.
            """)
            return
        case .curve:
            break
        }

        guard let model = CurveBuilder.model(for: settings, kind: kind) else {
            throw ValidationError("""
            Profile "\(name)", \(axis) produces no curve. The kernel discards a curve whose gains \
            are all zero, and would build no accelerator at all.
            """)
        }

        print("Profile \"\(name)\", \(axis) — mode \"curve\"")
        print("")
        print(Plot.render(model, maxRawSpeed: maxSpeed))
        print("")
        print(Plot.legend(model))
        if table {
            print("")
            print(Plot.table(model, maxRawSpeed: maxSpeed))
        }
    }
}

