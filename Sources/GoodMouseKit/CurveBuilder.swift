import Foundation

/// Turns a `CurveSpec` from the config into the IOFixed dictionaries the kernel expects, and into
/// the `AccelCurve` the pure model evaluates. Both come from the same place so the plot cannot
/// drift from what is actually written.
public enum CurveBuilder {
    /// `mode: "curve"` emits a single-entry array at index 0. A multi-entry set — which the kernel
    /// would interpolate between by acceleration index — is supported by the model but is not
    /// something the config can express yet.
    public static let singleCurveIndex: Double = 0

    public static func accelCurve(_ spec: CurveSpec, index: Double = singleCurveIndex) -> AccelCurve {
        AccelCurve(
            index: index,
            gainLinear: spec.gainLinear,
            gainParabolic: spec.gainParabolic,
            gainCubic: spec.gainCubic,
            gainQuartic: spec.gainQuartic,
            tangentSpeedLinear: spec.kneeSpeed,
            tangentSpeedParabolicRoot: spec.taperSpeed
        )
    }

    /// One entry of `UserPointerAccelCurvesKey`. Every value is IOFixed — a plain double here is
    /// read as a nonsense fixed-point number.
    public static func curveDictionary(_ spec: CurveSpec, index: Double = singleCurveIndex) -> [String: Int] {
        dictionary(from: accelCurve(spec, index: index))
    }

    public static func dictionary(from curve: AccelCurve) -> [String: Int] {
        [
            HIDKeys.accelIndex: IOFixed.from(curve.index),
            HIDKeys.accelGainLinear: IOFixed.from(curve.gainLinear),
            HIDKeys.accelGainParabolic: IOFixed.from(curve.gainParabolic),
            HIDKeys.accelGainCubic: IOFixed.from(curve.gainCubic),
            HIDKeys.accelGainQuartic: IOFixed.from(curve.gainQuartic),
            HIDKeys.accelTangentSpeedLinear: IOFixed.from(curve.tangentSpeedLinear),
            HIDKeys.accelTangentSpeedParabolicRoot: IOFixed.from(curve.tangentSpeedParabolicRoot),
        ]
    }

    /// The inverse of `dictionary(from:)`. Absent keys read as zero, exactly as the kernel treats
    /// them.
    public static func curve(from dictionary: [String: Int]) -> AccelCurve {
        func value(_ key: String) -> Double { IOFixed.toDouble(dictionary[key] ?? 0) }
        return AccelCurve(
            index: value(HIDKeys.accelIndex),
            gainLinear: value(HIDKeys.accelGainLinear),
            gainParabolic: value(HIDKeys.accelGainParabolic),
            gainCubic: value(HIDKeys.accelGainCubic),
            gainQuartic: value(HIDKeys.accelGainQuartic),
            tangentSpeedLinear: value(HIDKeys.accelTangentSpeedLinear),
            tangentSpeedParabolicRoot: value(HIDKeys.accelTangentSpeedParabolicRoot)
        )
    }

    /// The model for an axis as the kernel will build it, or nil when the settings produce no
    /// accelerator (`.raw`, or a curve the kernel would discard).
    public static func model(for axis: AxisSettings, kind: AxisKind = .pointer) -> CurveModel? {
        switch axis.mode {
        case .curve:
            guard let spec = axis.curve else { return nil }
            return CurveModel(
                curves: [accelCurve(spec)],
                acceleration: axis.acceleration,
                resolution: axis.clampedResolution(for: kind)
            )
        case .linear, .raw:
            return nil
        }
    }
}
