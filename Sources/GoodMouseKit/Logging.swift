import Foundation
import os

public enum Log {
    public static let subsystem = "dev.samiam.goodmouse"

    public static let applicator = Logger(subsystem: subsystem, category: "applicator")
    public static let monitor = Logger(subsystem: subsystem, category: "monitor")
    public static let config = Logger(subsystem: subsystem, category: "config")
}
