import Foundation

public enum Format {
    /// Numbers here are read by eye against a config file, so a whole number should print as one.
    public static func number(_ value: Double) -> String {
        guard value.isFinite else { return "\(value)" }
        return value == value.rounded() && abs(value) < 1e15
            ? String(Int(value))
            : String(format: "%g", value)
    }
}
