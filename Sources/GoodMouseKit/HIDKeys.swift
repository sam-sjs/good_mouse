import Foundation

/// Every HID property key literal the project writes or reads, in one place.
///
/// The public ones are `#define`s in the macOS SDK; the cited header is where each was read from.
/// The SPI ones appear in no header at all — they were taken from the strings of the shipping
/// `/System/Library/HIDPlugins/IOHIDPointerScrollFilter.plugin` binary.
public enum HIDKeys {
    // MARK: Device identity — IOKit/hid/IOHIDDeviceKeys.h

    public static let product = "Product"
    public static let vendorID = "VendorID"
    public static let productID = "ProductID"
    public static let transport = "Transport"
    public static let primaryUsage = "PrimaryUsage"
    public static let primaryUsagePage = "PrimaryUsagePage"
    public static let deviceUsage = "DeviceUsage"
    public static let deviceUsagePage = "DeviceUsagePage"

    // MARK: Pointer — IOKit/hidsystem/IOHIDParameter.h, IOKit/hid/IOHIDEventServiceKeys.h

    /// `kIOHIDPointerResolutionKey`. IOFixed. Higher means a *slower* pointer.
    public static let pointerResolution = "HIDPointerResolution"
    /// `kIOHIDPointerAccelerationTypeKey`. Its *value* names the key that carries the acceleration.
    public static let pointerAccelerationType = "HIDPointerAccelerationType"
    /// `kIOHIDPointerAccelerationKey`.
    public static let pointerAcceleration = "HIDPointerAcceleration"
    /// `kIOHIDMouseAccelerationTypeKey`.
    public static let mouseAcceleration = "HIDMouseAcceleration"
    /// `kIOHIDUseLinearScalingMouseAccelerationKey`. Non-zero short-circuits to a plain multiplier.
    public static let useLinearScalingMouseAcceleration = "HIDUseLinearScalingMouseAcceleration"
    /// `kIOHIDPointerAccelerationMinimumKey`, from IOHIDFamily's IOHIDKeys.h.
    public static let pointerAccelerationMinimum = "HIDPointerAccelerationMinimum"

    // MARK: Scroll — IOKit/hid/IOHIDEventServiceKeys.h

    /// `kIOHIDScrollResolutionKey`. Only consulted when the matching per-axis key is absent.
    public static let scrollResolution = "HIDScrollResolution"
    public static let scrollResolutionX = "HIDScrollResolutionX"
    public static let scrollResolutionY = "HIDScrollResolutionY"
    public static let scrollResolutionZ = "HIDScrollResolutionZ"
    /// `kIOHIDScrollAccelerationTypeKey`.
    public static let scrollAccelerationType = "HIDScrollAccelerationType"
    /// `kIOHIDScrollAccelerationKey`.
    public static let scrollAcceleration = "HIDScrollAcceleration"
    /// `kIOHIDMouseScrollAccelerationKey`.
    public static let mouseScrollAcceleration = "HIDMouseScrollAcceleration"

    /// The per-axis scroll resolution keys, in X, Y, Z order.
    public static let scrollResolutionAxisKeys = [scrollResolutionX, scrollResolutionY, scrollResolutionZ]

    // MARK: Curve entries — IOKit/hidsystem/IOHIDParameter.h. All values IOFixed.

    public static let accelIndex = "HIDAccelIndex"
    public static let accelGainLinear = "HIDAccelGainLinear"
    public static let accelGainParabolic = "HIDAccelGainParabolic"
    public static let accelGainCubic = "HIDAccelGainCubic"
    public static let accelGainQuartic = "HIDAccelGainQuartic"
    public static let accelTangentSpeedLinear = "HIDAccelTangentSpeedLinear"
    public static let accelTangentSpeedParabolicRoot = "HIDAccelTangentSpeedParabolicRoot"

    // MARK: SPI — no header anywhere

    /// Checked *before* the driver's own curves, which is what makes this the supported hook.
    /// Note the absent `HID` prefix: it really is `UserPointerAccelCurvesKey`.
    public static let userPointerAccelCurves = "UserPointerAccelCurvesKey"
    /// As above, for scroll.
    public static let userScrollAccelCurves = "UserScrollAccelCurvesKey"
    public static let pointerAccelerationAlgorithm = "HIDPointerAccelerationAlgorithm"
    public static let scrollAccelerationAlgorithm = "HIDScrollAccelerationAlgorithm"

    /// Values for the two `…AccelerationAlgorithm` keys. Anything else builds no accelerator at all.
    public enum Algorithm: Int {
        case table = 0
        case parametric = 1
        case `default` = 2

        public var label: String {
            switch self {
            case .table: return "table"
            case .parametric: return "parametric"
            case .default: return "system default"
            }
        }
    }

    /// Numeric keys that are plain integers rather than 16.16 fixed point. Almost every number in
    /// this API is IOFixed, so these are the exceptions worth naming — rendering `2` as
    /// `3.05e-05` would be nonsense.
    public static let plainIntegerKeys: Set<String> = [
        pointerAccelerationAlgorithm,
        scrollAccelerationAlgorithm,
        useLinearScalingMouseAcceleration,
    ]

    public static func isFixedPoint(_ key: String) -> Bool {
        !plainIntegerKeys.contains(key)
    }
}

/// IOFixed is a 16.16 fixed-point number: the double scaled by 65536.
public enum IOFixed {
    public static let scale: Double = 65536.0

    public static func from(_ value: Double) -> Int {
        Int((value * scale).rounded())
    }

    public static func toDouble(_ value: Int) -> Double {
        Double(value) / scale
    }
}
