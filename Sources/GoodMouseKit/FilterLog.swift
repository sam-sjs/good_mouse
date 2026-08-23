import Foundation

/// Reads what the kernel's pointer/scroll filter says it built, from the unified log.
///
/// This exists because `ServiceFilterDebug` turns out not to be usable for the job. Every filter in
/// a service's chain answers that key with its own serialised state, and the first responder wins —
/// on this machine that is `IOHIDEventProcessorFilter`, which shadows `IOHIDPointerScrollFilter`
/// entirely. The log is the only outside view of what the acceleration filter actually did.
///
/// `IOHIDPointerScrollFilter` logs one line per axis from `setupPointerAcceleration` /
/// `setupScrollAcceleration`, naming the key it resolved the acceleration from and whether the
/// accelerator is enabled or disabled. It runs inside **WindowServer**, so the lines are attributed
/// to that process rather than to us.
public enum FilterLog {
    public struct Entry: Sendable {
        public let timestamp: String
        public let message: String
    }

    /// Lines the acceleration filter emitted in the last `seconds`.
    ///
    /// These are `Df` (info-level) records, so `--info` is required — without it the query returns
    /// nothing and looks like a negative result.
    public static func recentAccelerationLines(seconds: Int = 60) throws -> [Entry] {
        // Absolute path, not `log` — see Shell.run.
        let output = try Shell.run("/usr/bin/log", [
            "show",
            "--last", "\(seconds)s",
            "--info",
            "--style", "compact",
            "--predicate", #"subsystem == "com.apple.iohid" AND eventMessage CONTAINS "acceleration""#,
        ]).output

        return output
            .split(separator: "\n")
            .compactMap { line -> Entry? in
                let text = String(line)
                // Skip the header row and the log tool's own audit record.
                guard text.contains("acceleration"), !text.hasPrefix("Timestamp") else { return nil }
                guard let range = text.range(of: "] ", options: .backwards) else {
                    return Entry(timestamp: "", message: text)
                }
                let stamp = text.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                return Entry(timestamp: stamp, message: String(text[range.upperBound...]))
            }
    }
}
