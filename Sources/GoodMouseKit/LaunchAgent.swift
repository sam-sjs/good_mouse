import Foundation

/// Install and remove the per-user launchd agent that runs `goodmouse watch`.
///
/// A user agent, not a system daemon: these are per-service HID properties, and an unprivileged
/// process can write them.
public enum LaunchAgent {
    public static let label = "dev.samiam.goodmouse"

    public static var plistPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public static var logDirectory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/goodmouse")
    }

    public static var serviceTarget: String {
        "gui/\(getuid())/\(label)"
    }

    public static func plist(executablePath: String, configPath: String?) -> String {
        var arguments = [executablePath, "watch"]
        if let configPath {
            arguments += ["--config", configPath]
        }
        let argumentXML = arguments
            .map { "        <string>\(escape($0))</string>" }
            .joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
        \(argumentXML)
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ProcessType</key>
            <string>Background</string>
            <key>StandardOutPath</key>
            <string>\(escape(logDirectory))/goodmouse.log</string>
            <key>StandardErrorPath</key>
            <string>\(escape(logDirectory))/goodmouse.err.log</string>
        </dict>
        </plist>

        """
    }

    public static func install(executablePath: String, configPath: String?) throws {
        try FileManager.default.createDirectory(
            atPath: logDirectory, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: plistPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(plist(executablePath: executablePath, configPath: configPath).utf8)
            .write(to: URL(fileURLWithPath: plistPath))

        // Replacing an existing agent: bootout first, ignoring the failure when it is not loaded.
        _ = try? Shell.run("/bin/launchctl", ["bootout", serviceTarget])
        let result = try Shell.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistPath])
        guard result.status == 0 else {
            throw ConfigError.invalid(detail: """
            launchctl bootstrap failed (status \(result.status)):
            \(result.output)
            """)
        }
    }

    public static func uninstall() throws -> (wasLoaded: Bool, plistRemoved: Bool) {
        let bootout = try Shell.run("/bin/launchctl", ["bootout", serviceTarget])
        let wasLoaded = bootout.status == 0
        var removed = false
        if FileManager.default.fileExists(atPath: plistPath) {
            try FileManager.default.removeItem(atPath: plistPath)
            removed = true
        }
        return (wasLoaded, removed)
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
