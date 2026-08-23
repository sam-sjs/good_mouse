import Foundation

/// Runs an external command and collects its output.
///
/// Every caller passes an **absolute** path on purpose. `FilterLog` in particular must invoke
/// `/usr/bin/log` rather than `log`, because zsh has a `log` builtin that shadows it, consumes the
/// arguments, exits 0 and prints nothing — which looks exactly like a genuine empty result.
enum Shell {
    struct Result {
        let status: Int32
        /// stdout and stderr merged, trimmed.
        let output: String
    }

    static func run(_ executablePath: String, _ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        // Read before waiting: a command that outfills the pipe buffer would otherwise block
        // forever while we wait for an exit that cannot happen.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Result(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
