import Foundation

/// The whole configuration file.
public struct Config: Codable, Equatable, Sendable {
    /// Rules in precedence order: the first matching rule wins.
    public var devices: [DeviceRule]
    public var profiles: [String: Profile]

    public init(devices: [DeviceRule] = [], profiles: [String: Profile] = [:]) {
        self.devices = devices
        self.profiles = profiles
    }

    /// The profile a device should get, or nil when no rule matches it.
    public func profile(for device: DeviceInfo) -> (name: String, profile: Profile)? {
        guard let rule = DeviceMatcher.firstRule(in: devices, for: device),
              let profile = profiles[rule.profile]
        else { return nil }
        return (rule.profile, profile)
    }
}

// MARK: - Errors

public enum ConfigError: Error, CustomStringConvertible {
    case notFound(path: String)
    case unreadable(path: String, underlying: any Error)
    case malformed(path: String, detail: String)
    case invalid(detail: String)

    public var description: String {
        switch self {
        case .notFound(let path):
            return """
            No config file at \(path).
            Run `goodmouse write-default-config` to create one.
            """
        case .unreadable(let path, let underlying):
            return "Could not read \(path): \(underlying.localizedDescription)"
        case .malformed(let path, let detail):
            return "\(path) is not valid JSON for a goodmouse config:\n  \(detail)"
        case .invalid(let detail):
            return "Config is invalid:\n  \(detail)"
        }
    }
}

// MARK: - Warnings

/// Something worth telling the user about that is not fatal.
public struct ConfigWarning: Equatable, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

// MARK: - Loading

public enum ConfigLoader {
    /// `$XDG_CONFIG_HOME/goodmouse/config.json`, falling back to `~/.config/goodmouse/config.json`.
    public static var defaultPath: String {
        let base: String
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = xdg
        } else {
            base = (NSHomeDirectory() as NSString).appendingPathComponent(".config")
        }
        return (base as NSString).appendingPathComponent("goodmouse/config.json")
    }

    public static func load(path: String? = nil) throws -> (config: Config, warnings: [ConfigWarning]) {
        let path = path ?? defaultPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw ConfigError.notFound(path: path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw ConfigError.unreadable(path: path, underlying: error)
        }
        return try decode(data, path: path)
    }

    public static func decode(_ data: Data, path: String = "<input>") throws -> (config: Config, warnings: [ConfigWarning]) {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true  // so the shipped default config may carry its comments
        let config: Config
        do {
            config = try decoder.decode(Config.self, from: data)
        } catch let error as DecodingError {
            throw ConfigError.malformed(path: path, detail: describe(error))
        } catch {
            throw ConfigError.malformed(path: path, detail: error.localizedDescription)
        }
        let warnings = try validate(config)
        return (config, warnings)
    }

    /// Throws on anything that would make the config do the wrong thing; returns warnings for
    /// everything else.
    @discardableResult
    public static func validate(_ config: Config) throws -> [ConfigWarning] {
        var warnings: [ConfigWarning] = []

        if config.devices.isEmpty {
            warnings.append(ConfigWarning("`devices` is empty, so no device will ever be configured."))
        }

        for (i, rule) in config.devices.enumerated() {
            if rule.match.isEmpty {
                throw ConfigError.invalid(detail: """
                devices[\(i)] has an empty `match`. A rule with no criteria would claim every \
                pointing device on the system, so it is rejected. Give it at least one of \
                product, vendorID, productID, usagePage, usage, transport.
                """)
            }
            guard config.profiles[rule.profile] != nil else {
                let known = config.profiles.keys.sorted().joined(separator: ", ")
                throw ConfigError.invalid(detail: """
                devices[\(i)] names profile "\(rule.profile)", which is not defined. \
                Defined profiles: \(known.isEmpty ? "(none)" : known).
                """)
            }
        }

        for name in config.profiles.keys.sorted() {
            let profile = config.profiles[name]!
            if profile.pointer == nil, profile.scroll == nil {
                warnings.append(ConfigWarning("Profile \"\(name)\" sets neither `pointer` nor `scroll`, so it does nothing."))
            }
            try validate(profile.pointer, kind: .pointer, profile: name, warnings: &warnings)
            try validate(profile.scroll, kind: .scroll, profile: name, warnings: &warnings)
        }

        return warnings
    }

    private static func validate(
        _ axis: AxisSettings?,
        kind: AxisKind,
        profile: String,
        warnings: inout [ConfigWarning]
    ) throws {
        guard let axis else { return }
        let axisName = kind.rawValue
        let where_ = "profiles.\(profile).\(axisName)"

        switch axis.mode {
        case .curve:
            guard let curve = axis.curve else {
                throw ConfigError.invalid(detail: """
                \(where_) uses mode "curve" but has no `curve` block.
                """)
            }
            guard curve.hasNonZeroGain else {
                throw ConfigError.invalid(detail: """
                \(where_) has every gain at zero. The kernel discards such a curve, and with no \
                curves left it builds no accelerator at all — the pointer would silently go raw \
                rather than slow. Set at least one of gainLinear, gainParabolic, gainCubic, \
                gainQuartic.
                """)
            }
            guard axis.acceleration >= 0 else {
                throw ConfigError.invalid(detail: """
                \(where_) has a negative `acceleration` (\(axis.acceleration)). A negative value \
                disables acceleration entirely; use mode "raw" if that is what you want.
                """)
            }
            if curve.kneeSpeed < 0 || curve.taperSpeed < 0 {
                throw ConfigError.invalid(detail: "\(where_) has a negative kneeSpeed or taperSpeed.")
            }
            if curve.kneeSpeed != 0, curve.taperSpeed != 0, curve.taperSpeed <= curve.kneeSpeed {
                warnings.append(ConfigWarning("""
                \(where_): taperSpeed (\(curve.taperSpeed)) is not above kneeSpeed \
                (\(curve.kneeSpeed)), so the straight-line segment is empty and the curve jumps \
                from the polynomial ramp into the square-root taper.
                """))
            }
            if curve.gainLinear < 0 || curve.gainParabolic < 0 || curve.gainCubic < 0 || curve.gainQuartic < 0 {
                warnings.append(ConfigWarning("""
                \(where_) has a negative gain. The curve may be non-monotonic — check \
                `goodmouse plot` before relying on it.
                """))
            }
            if axis.resolutionWasClamped(for: kind) {
                warnings.append(ConfigWarning("""
                \(where_): resolution \(axis.resolution) clamped to \(axis.clampedResolution(for: kind)) \
                (allowed \(Int(kind.resolutionRange.lowerBound))…\(Int(kind.resolutionRange.upperBound))).
                """))
            }

        case .linear:
            guard axis.acceleration >= 0 else {
                throw ConfigError.invalid(detail: """
                \(where_) has a negative `acceleration` (\(axis.acceleration)) in mode "linear". \
                Use mode "raw" to disable acceleration.
                """)
            }
            if axis.acceleration == 0, axis.accelerationMinimum == nil {
                warnings.append(ConfigWarning("""
                \(where_): mode "linear" with acceleration 0 falls back to the system's \
                acceleration minimum. Set `accelerationMinimum` to control it.
                """))
            }
            // Only the pointer has a linear-scaling short-circuit. It is taken before resolution is
            // consulted, so resolution really is dead there. Scroll has no such path: its "linear"
            // mode is the default algorithm with no user curve, and resolution still applies.
            if kind == .pointer, axis.resolution != CurveModel.defaultResolution {
                warnings.append(ConfigWarning("""
                    \(where_): mode "linear" ignores `resolution` — the filter short-circuits to a \
                    flat multiplier before resolution is consulted.
                    """))
            }

        case .raw:
            if axis.curve != nil {
                warnings.append(ConfigWarning("\(where_): mode \"raw\" ignores the `curve` block."))
            }
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let parts = context.codingPath.map(\.stringValue)
            return parts.isEmpty ? "(root)" : parts.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "missing required key \"\(key.stringValue)\" at \(path(context))"
        case .typeMismatch(let type, let context):
            return "\(path(context)) has the wrong type — expected \(type)"
        case .valueNotFound(let type, let context):
            return "\(path(context)) is null — expected \(type)"
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty
                ? context.debugDescription
                : "\(path(context)): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }
}
