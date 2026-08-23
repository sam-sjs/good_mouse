import Foundation

// A Swift port of the kernel-side parametric pointer acceleration algorithm.
//
// This file must not import IOKit. It is pure math so it stays unit-testable and can drive
// `goodmouse plot` without touching a device.
//
// Every constant and every line of the arithmetic below was checked against
// IOHIDFamily/IOHIDEventSystemPlugIns/IOHIDAccelerationAlgorithm.cpp. Where this and the
// system disagree, the system is right and this is a bug.

/// One entry of a parametric acceleration curve set, in natural (non-IOFixed) units.
public struct AccelCurve: Equatable, Sendable {
    public var index: Double
    public var gainLinear: Double
    public var gainParabolic: Double
    public var gainCubic: Double
    public var gainQuartic: Double
    public var tangentSpeedLinear: Double
    public var tangentSpeedParabolicRoot: Double

    public init(
        index: Double = 0,
        gainLinear: Double = 0,
        gainParabolic: Double = 0,
        gainCubic: Double = 0,
        gainQuartic: Double = 0,
        tangentSpeedLinear: Double = 0,
        tangentSpeedParabolicRoot: Double = 0
    ) {
        self.index = index
        self.gainLinear = gainLinear
        self.gainParabolic = gainParabolic
        self.gainCubic = gainCubic
        self.gainQuartic = gainQuartic
        self.tangentSpeedLinear = tangentSpeedLinear
        self.tangentSpeedParabolicRoot = tangentSpeedParabolicRoot
    }

    /// A curve with every gain at zero is discarded by the filter. If that leaves no curves at all,
    /// no accelerator is built and motion passes through unaccelerated — so this is a real
    /// configuration error, not a cosmetic one.
    public var isValid: Bool {
        gainLinear != 0 || gainParabolic != 0 || gainCubic != 0 || gainQuartic != 0
    }

    static func lerp(_ lo: AccelCurve, _ hi: AccelCurve, _ ratio: Double) -> AccelCurve {
        func mix(_ a: Double, _ b: Double) -> Double { a + ratio * (b - a) }
        return AccelCurve(
            index: mix(lo.index, hi.index),
            gainLinear: mix(lo.gainLinear, hi.gainLinear),
            gainParabolic: mix(lo.gainParabolic, hi.gainParabolic),
            gainCubic: mix(lo.gainCubic, hi.gainCubic),
            gainQuartic: mix(lo.gainQuartic, hi.gainQuartic),
            tangentSpeedLinear: mix(lo.tangentSpeedLinear, hi.tangentSpeedLinear),
            tangentSpeedParabolicRoot: mix(lo.tangentSpeedParabolicRoot, hi.tangentSpeedParabolicRoot)
        )
    }
}

/// The evaluated curve: a polynomial ramp, then a straight line, then a square-root taper.
public struct CurveModel: Sendable {
    /// Report rate the algorithm normalises against. `FRAME_RATE` in IOHIDAcceleration.hpp.
    public static let frameRate: Double = 67.0
    /// `SCREEN_RESOLUTION` in IOHIDAcceleration.hpp.
    public static let screenResolution: Double = 96.0
    /// `kCursorScale` in IOHIDAccelerationAlgorithm.hpp.
    public static let cursorScale: Double = screenResolution / frameRate
    /// `kDefaultPointerResolutionFixed >> 16` in IOHIDPointerScrollFilter.h.
    public static let defaultResolution: Double = 400.0

    /// The curve actually in force, after selection and interpolation.
    public let curve: AccelCurve
    public let acceleration: Double
    public let resolution: Double
    public let rate: Double

    /// End of the polynomial segment. `.greatestFiniteMagnitude` when there is no knee.
    public let tangent0: Double
    /// End of the linear segment. `.greatestFiniteMagnitude` when there is no taper.
    public let tangent1: Double

    let m0: Double, b0: Double
    let m1: Double, b1: Double

    /// The filter only takes the straight-line segment when the first tangent came from
    /// `tangentSpeedLinear`. With a taper but no knee the polynomial runs straight into the
    /// square root instead.
    let usesLinearSegment: Bool

    /// Mirrors `IOHIDParametricAcceleration::CreateWithParameters`, which returns NULL — meaning
    /// no accelerator at all, so raw 1:1 motion — for a negative acceleration or an empty curve set.
    public init?(
        curves: [AccelCurve],
        acceleration: Double,
        resolution: Double = CurveModel.defaultResolution,
        rate: Double = CurveModel.frameRate
    ) {
        guard acceleration >= 0 else { return nil }

        // The filter drops invalid curves, then picks the last one whose index does not exceed the
        // requested acceleration. (Apple's loop tracks that position against the unfiltered array,
        // which misbehaves when invalid curves are interleaved. `CurveBuilder` never emits an
        // invalid curve, so the distinction cannot arise from anything this project writes.)
        let valid = curves.filter(\.isValid)
        guard !valid.isEmpty else { return nil }

        var current = 0
        for (i, c) in valid.enumerated() where acceleration >= c.index {
            current = i
        }

        let selected: AccelCurve
        if valid[current].index < acceleration, current + 1 < valid.count {
            let lo = valid[current], hi = valid[current + 1]
            let span = hi.index - lo.index
            let ratio = span == 0 ? 0 : (acceleration - lo.index) / span
            selected = AccelCurve.lerp(lo, hi, ratio)
        } else {
            selected = valid[current]
        }

        self.curve = selected
        self.acceleration = acceleration
        self.resolution = resolution
        self.rate = rate

        let gl = selected.gainLinear
        let gp = selected.gainParabolic
        let gc = selected.gainCubic
        let gq = selected.gainQuartic
        let tsl = selected.tangentSpeedLinear
        let tspr = selected.tangentSpeedParabolicRoot

        // Each gain is raised to its own power: (gp * v)^2, not gp * v^2. Getting this wrong makes
        // the plot lie about what the kernel is doing.
        func poly(_ v: Double) -> Double {
            gl * v + pow(gp * v, 2) + pow(gc * v, 3) + pow(gq * v, 4)
        }
        /// d/dv of `poly`, with each gain still raised to its own power.
        func slope(_ v: Double) -> Double {
            gl + 2 * v * pow(gp, 2) + 3 * pow(v, 2) * pow(gc, 3) + 4 * pow(v, 3) * pow(gq, 4)
        }

        var t0 = Double.greatestFiniteMagnitude
        var t1 = Double.greatestFiniteMagnitude
        var m0 = 0.0, b0 = 0.0, m1 = 0.0, b1 = 0.0
        var usesLinear = false

        if tsl != 0 {
            let y0 = poly(tsl)
            m0 = slope(tsl)
            b0 = y0 - m0 * tsl
            t0 = tsl
            usesLinear = true

            if tspr != 0 {
                let y1 = m0 * tspr + b0
                m1 = 2 * y1 * m0
                b1 = pow(y1, 2) - m1 * tspr
                t1 = tspr
            }
        } else if tspr != 0 {
            // No knee: the polynomial runs to the taper speed and hands straight to the square root.
            let y0 = poly(tspr)
            m1 = slope(tspr)
            b1 = pow(y0, 2) - m1 * tspr
            t0 = tspr
        }

        self.tangent0 = t0
        self.tangent1 = t1
        self.m0 = m0
        self.b0 = b0
        self.m1 = m1
        self.b1 = b1
        self.usesLinearSegment = usesLinear
    }

    /// Device speed normalised by `resolution / rate`. This is the value the segments are defined
    /// over, and the x-axis `tangent0` / `tangent1` live on.
    public func normalizedSpeed(rawSpeed: Double) -> Double {
        rawSpeed / (resolution / rate)
    }

    /// The factor pointer deltas are multiplied by at a given raw device speed.
    public func multiplier(rawSpeed: Double) -> Double {
        multiplierForNormalizedSpeed(normalizedSpeed(rawSpeed: rawSpeed))
    }

    /// As `multiplier(rawSpeed:)`, but taking an already-normalised speed.
    public func multiplierForNormalizedSpeed(_ v: Double) -> Double {
        let result: Double
        if v <= tangent0 {
            result = polynomialSegment(v)
        } else if v <= tangent1, usesLinearSegment {
            result = linearSegment(v)
        } else {
            result = rootSegment(v)
        }
        return result * CurveModel.cursorScale
    }

    // The three segments, before `cursorScale`. Exposed so continuity can be tested by evaluating
    // both sides at exactly the boundary. Probing at `boundary ± ε` cannot do that job: the gap it
    // reports is the local slope times 2ε, which is non-zero for any continuous curve with slope.

    func polynomialSegment(_ v: Double) -> Double {
        curve.gainLinear * v
            + pow(curve.gainParabolic * v, 2)
            + pow(curve.gainCubic * v, 3)
            + pow(curve.gainQuartic * v, 4)
    }

    func linearSegment(_ v: Double) -> Double {
        m0 * v + b0
    }

    func rootSegment(_ v: Double) -> Double {
        // Apple does not guard this. A curve whose parameters drive the radicand negative produces
        // NaN in the kernel too, so reproducing that faithfully is the point.
        (m1 * v + b1).squareRoot()
    }

    /// Raw device speed at which the polynomial segment ends, or nil when there is no knee.
    public var kneeRawSpeed: Double? {
        tangent0 == .greatestFiniteMagnitude ? nil : tangent0 * (resolution / rate)
    }

    /// Raw device speed at which the linear segment gives way to the taper, or nil when absent.
    public var taperRawSpeed: Double? {
        tangent1 == .greatestFiniteMagnitude ? nil : tangent1 * (resolution / rate)
    }
}
