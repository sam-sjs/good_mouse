import ArgumentParser
import Foundation
import GoodMouseKit

@main
struct GoodMouse: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "goodmouse",
        abstract: "Pointer sensitivity and acceleration for a trackball Karabiner-Elements has seized.",
        discussion: """
        Karabiner grabs the physical device and re-emits through its own virtual HID pointing
        device, so pointer settings applied to the trackball land on something that no longer emits
        anything. goodmouse matches on HID usage instead of transport, finds the virtual device,
        and tunes that.
        """,
        version: "0.1.0",
        subcommands: [
            Devices.self, Apply.self, Watch.self, Status.self,
            PlotCommand.self, Restore.self, InstallAgent.self, UninstallAgent.self,
            WriteDefaultConfig.self,
        ],
        defaultSubcommand: Devices.self
    )
}

