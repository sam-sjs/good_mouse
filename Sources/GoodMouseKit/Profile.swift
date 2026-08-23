import Foundation

/// How an axis is driven.
public enum AxisMode: String, Codable, Sendable, CaseIterable {
    /// Parametric user curve. The full four-gain, two-tangent shape.
    case curve
    /// Flat multiplier, no acceleration. The filter's linear-scaling short-circuit.
    case linear
    /// No accelerator at all: 1:1 device motion. Resolution and curves are inert.
    case raw
}

/// The six curve fields are direct aliases for the kernel's `HIDAccelGain*` and
/// `HIDAccelTangentSpeed*` parameters. They are deliberately not reparametrised into something
/// friendlier — `goodmouse plot` is what makes them legible.
public struct CurveSpec: Codable, Equatable, Sendable {
    /// `HIDAccelGainLinear`. The low-speed multiplier — this is "sensitivity".
    public var gainLinear: Double
    /// `HIDAccelGainParabolic`. How hard acceleration ramps. Enters the math as `(gainParabolic * v)^2`.
    public var gainParabolic: Double
    /// `HIDAccelGainCubic`. Enters as `(gainCubic * v)^3`.
    public var gainCubic: Double
    /// `HIDAccelGainQuartic`. Enters as `(gainQuartic * v)^4`.
    public var gainQuartic: Double
    /// `HIDAccelTangentSpeedLinear`. Where the polynomial ramp stops and a straight line takes over.
    public var kneeSpeed: Double
    /// `HIDAccelTangentSpeedParabolicRoot`. Where the straight line gives way to a square-root taper.
    public var taperSpeed: Double

    public init(
        gainLinear: Double = 1.0,
        gainParabolic: Double = 0.4,
        gainCubic: Double = 0.08,
        gainQuartic: Double = 0.0,
        kneeSpeed: Double = 8.0,
        taperSpeed: Double = 18.0
    ) {
        self.gainLinear = gainLinear
        self.gainParabolic = gainParabolic
        self.gainCubic = gainCubic
        self.gainQuartic = gainQuartic
        self.kneeSpeed = kneeSpeed
        self.taperSpeed = taperSpeed
    }

    /// Mirrors the kernel's own validity test: a curve with every gain at zero is discarded.
    public var hasNonZeroGain: Bool {
        gainLinear != 0 || gainParabolic != 0 || gainCubic != 0 || gainQuartic != 0
    }

    enum CodingKeys: String, CodingKey {
        case gainLinear, gainParabolic, gainCubic, gainQuartic, kneeSpeed, taperSpeed
    }

    /// Every field falls back to its default, so a config can name only the one being tuned. The
    /// alternative — demanding all six every time — makes changing one gain a six-line edit.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = CurveSpec()
        gainLinear = try c.decodeIfPresent(Double.self, forKey: .gainLinear) ?? fallback.gainLinear
        gainParabolic = try c.decodeIfPresent(Double.self, forKey: .gainParabolic) ?? fallback.gainParabolic
        gainCubic = try c.decodeIfPresent(Double.self, forKey: .gainCubic) ?? fallback.gainCubic
        gainQuartic = try c.decodeIfPresent(Double.self, forKey: .gainQuartic) ?? fallback.gainQuartic
        kneeSpeed = try c.decodeIfPresent(Double.self, forKey: .kneeSpeed) ?? fallback.kneeSpeed
        taperSpeed = try c.decodeIfPresent(Double.self, forKey: .taperSpeed) ?? fallback.taperSpeed
    }
}

/// Which axis a set of settings drives. The two are not interchangeable: they read different keys
/// and accept different resolution ranges.
public enum AxisKind: String, Sendable {
    case pointer
    case scroll

    /// Pointer resolution is a device DPI figure in the hundreds; scroll resolution is a much
    /// smaller notches-per-unit figure — a stock device here publishes 9. Clamping scroll to the
    /// pointer's floor of 10 would silently change a valid setting.
    public var resolutionRange: ClosedRange<Double> {
        switch self {
        case .pointer: return 10...1995
        case .scroll: return 1...1995
        }
    }
}

/// Settings for one axis — pointer or scroll — of a profile.
public struct AxisSettings: Codable, Equatable, Sendable {
    public var mode: AxisMode
    /// `HIDPointerResolution` / `HIDScrollResolution`, in natural units. Higher means slower.
    /// Ignored in `.linear` and `.raw`.
    public var resolution: Double
    /// The acceleration index the curve set is evaluated at.
    public var acceleration: Double
    /// Required in `.curve` mode, ignored otherwise.
    public var curve: CurveSpec?
    /// `HIDPointerAccelerationMinimum`. Only consulted in `.linear` mode when `acceleration` is 0.
    public var accelerationMinimum: Double?

    public init(
        mode: AxisMode = .curve,
        resolution: Double = CurveModel.defaultResolution,
        acceleration: Double = AxisSettings.defaultAcceleration,
        curve: CurveSpec? = nil,
        accelerationMinimum: Double? = nil
    ) {
        self.mode = mode
        self.resolution = resolution
        self.acceleration = acceleration
        self.curve = curve
        self.accelerationMinimum = accelerationMinimum
    }

    /// Matches the `HIDPointerAcceleration = 45056` seen on a stock device.
    public static let defaultAcceleration: Double = 0.6875

    enum CodingKeys: String, CodingKey {
        case mode, resolution, acceleration, curve, accelerationMinimum
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(AxisMode.self, forKey: .mode) ?? .curve
        resolution = try c.decodeIfPresent(Double.self, forKey: .resolution) ?? CurveModel.defaultResolution
        acceleration = try c.decodeIfPresent(Double.self, forKey: .acceleration) ?? AxisSettings.defaultAcceleration
        curve = try c.decodeIfPresent(CurveSpec.self, forKey: .curve)
        accelerationMinimum = try c.decodeIfPresent(Double.self, forKey: .accelerationMinimum)
    }

    /// Resolution clamped into the range the given axis accepts, for use when building writes.
    public func clampedResolution(for axis: AxisKind) -> Double {
        let range = axis.resolutionRange
        return min(max(resolution, range.lowerBound), range.upperBound)
    }

    /// True when `resolution` had to be clamped — worth telling the user about.
    public func resolutionWasClamped(for axis: AxisKind) -> Bool {
        clampedResolution(for: axis) != resolution
    }
}

/// A named set of axis settings.
public struct Profile: Codable, Equatable, Sendable {
    public var pointer: AxisSettings?
    public var scroll: AxisSettings?

    public init(pointer: AxisSettings? = nil, scroll: AxisSettings? = nil) {
        self.pointer = pointer
        self.scroll = scroll
    }
}

/// Which HID services a profile applies to.
///
/// Criteria are ANDed. `product` and `transport` are glob patterns (`*` and `?`); everything else
/// is an exact match. A criterion that names a property the device does not publish never matches —
/// which is exactly why `transport` cannot be used to reach the Karabiner virtual device.
public struct DeviceMatch: Codable, Equatable, Sendable {
    public var product: String?
    public var vendorID: Int?
    public var productID: Int?
    public var usagePage: Int?
    public var usage: Int?
    public var transport: String?

    public init(
        product: String? = nil,
        vendorID: Int? = nil,
        productID: Int? = nil,
        usagePage: Int? = nil,
        usage: Int? = nil,
        transport: String? = nil
    ) {
        self.product = product
        self.vendorID = vendorID
        self.productID = productID
        self.usagePage = usagePage
        self.usage = usage
        self.transport = transport
    }

    public var isEmpty: Bool {
        product == nil && vendorID == nil && productID == nil
            && usagePage == nil && usage == nil && transport == nil
    }
}

/// One rule binding a matcher to a profile name.
public struct DeviceRule: Codable, Equatable, Sendable {
    public var match: DeviceMatch
    public var profile: String

    public init(match: DeviceMatch, profile: String) {
        self.match = match
        self.profile = profile
    }
}
