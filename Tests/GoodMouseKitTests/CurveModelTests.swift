import Foundation
import Testing
@testable import GoodMouseKit

/// Apple's own default mouse curve, dumped from a physical device's `HIDAccelCurves`. IOFixed.
/// Used as a fixture so the port is exercised against a real, multi-entry curve set rather than
/// only against curves this project generates.
enum AppleDefaultCurves {
    static let fixed: [[String: Int]] = [
        ["HIDAccelIndex": 0, "HIDAccelGainLinear": 65536, "HIDAccelTangentSpeedLinear": 524288],
        ["HIDAccelIndex": 8192, "HIDAccelGainLinear": 60293, "HIDAccelTangentSpeedLinear": 537395,
         "HIDAccelGainParabolic": 26214, "HIDAccelGainCubic": 5243, "HIDAccelTangentSpeedParabolicRoot": 1245184],
        ["HIDAccelIndex": 32768, "HIDAccelGainLinear": 60948, "HIDAccelTangentSpeedLinear": 543949,
         "HIDAccelGainParabolic": 36045, "HIDAccelGainCubic": 6554, "HIDAccelTangentSpeedParabolicRoot": 1179648],
        ["HIDAccelIndex": 45056, "HIDAccelGainLinear": 61604, "HIDAccelTangentSpeedLinear": 550502,
         "HIDAccelGainParabolic": 46531, "HIDAccelGainCubic": 7864, "HIDAccelTangentSpeedParabolicRoot": 1114112],
        ["HIDAccelIndex": 57344, "HIDAccelGainLinear": 62259, "HIDAccelTangentSpeedLinear": 557056,
         "HIDAccelGainParabolic": 57672, "HIDAccelGainCubic": 9830, "HIDAccelTangentSpeedParabolicRoot": 1048576],
        ["HIDAccelIndex": 65536, "HIDAccelGainLinear": 62915, "HIDAccelTangentSpeedLinear": 563610,
         "HIDAccelGainParabolic": 69468, "HIDAccelGainCubic": 11796, "HIDAccelTangentSpeedParabolicRoot": 983040],
        ["HIDAccelIndex": 98304, "HIDAccelGainLinear": 63570, "HIDAccelTangentSpeedLinear": 570163,
         "HIDAccelGainParabolic": 81920, "HIDAccelGainCubic": 14418, "HIDAccelTangentSpeedParabolicRoot": 917504],
        ["HIDAccelIndex": 131072, "HIDAccelGainLinear": 64225, "HIDAccelTangentSpeedLinear": 576717,
         "HIDAccelGainParabolic": 95027, "HIDAccelGainCubic": 17695, "HIDAccelTangentSpeedParabolicRoot": 851968],
        ["HIDAccelIndex": 163840, "HIDAccelGainLinear": 64881, "HIDAccelTangentSpeedLinear": 583270,
         "HIDAccelGainParabolic": 108790, "HIDAccelGainCubic": 21627, "HIDAccelTangentSpeedParabolicRoot": 786432],
        ["HIDAccelIndex": 196608, "HIDAccelGainLinear": 65536, "HIDAccelTangentSpeedLinear": 589824,
         "HIDAccelGainParabolic": 123208, "HIDAccelGainCubic": 26214, "HIDAccelTangentSpeedParabolicRoot": 786432],
    ]

    static let curves: [AccelCurve] = fixed.map(CurveBuilder.curve(from:))
}

@Suite("CurveModel")
struct CurveModelTests {
    /// The single curve the shipped default config produces.
    static let defaultSpec = CurveSpec()

    @Test("The Apple default curve set is monotonically increasing")
    func monotonic() throws {
        let model = try #require(CurveModel(curves: AppleDefaultCurves.curves, acceleration: 0.6875))
        var previous = -Double.infinity
        for step in 0...2000 {
            let speed = Double(step) * 0.1
            let value = model.multiplier(rawSpeed: speed)
            #expect(value.isFinite, "multiplier went non-finite at speed \(speed)")
            #expect(value >= previous - 1e-12, "multiplier decreased at speed \(speed)")
            previous = value
        }
    }

    /// Continuity means the two branch formulas agree at the boundary itself. Sampling at
    /// `boundary ± ε` cannot show that: the difference it reports is the local slope times 2ε,
    /// which is non-zero for any curve with slope, so it would fail on a perfectly continuous
    /// function and pass on a flat discontinuous one.
    static func segmentGaps(_ model: CurveModel) -> (knee: Double?, taper: Double?) {
        var knee: Double?
        var taper: Double?
        if model.usesLinearSegment {
            let t0 = model.tangent0
            knee = abs(model.polynomialSegment(t0) - model.linearSegment(t0))
            if model.tangent1 != .greatestFiniteMagnitude {
                let t1 = model.tangent1
                taper = abs(model.linearSegment(t1) - model.rootSegment(t1))
            }
        } else if model.tangent0 != .greatestFiniteMagnitude {
            // No knee: the polynomial hands straight to the square root at tangent0.
            let t0 = model.tangent0
            knee = abs(model.polynomialSegment(t0) - model.rootSegment(t0))
        }
        return (knee, taper)
    }

    @Test("The curve is continuous across the knee")
    func continuousAtKnee() throws {
        let model = try #require(CurveModel(
            curves: [CurveBuilder.accelCurve(Self.defaultSpec)],
            acceleration: 0
        ))
        let gap = try #require(Self.segmentGaps(model).knee)
        #expect(gap < 1e-9, "discontinuity of \(gap) at the knee")
    }

    @Test("The curve is continuous across the taper")
    func continuousAtTaper() throws {
        let model = try #require(CurveModel(
            curves: [CurveBuilder.accelCurve(Self.defaultSpec)],
            acceleration: 0
        ))
        let gap = try #require(Self.segmentGaps(model).taper)
        #expect(gap < 1e-9, "discontinuity of \(gap) at the taper")
    }

    @Test("Both boundaries stay continuous across the whole Apple curve set")
    func continuousForEveryAppleCurve() throws {
        for entry in AppleDefaultCurves.curves {
            let model = try #require(CurveModel(curves: [entry], acceleration: entry.index))
            let gaps = Self.segmentGaps(model)
            if let knee = gaps.knee {
                #expect(knee < 1e-9, "knee discontinuity \(knee) at index \(entry.index)")
            }
            if let taper = gaps.taper {
                #expect(taper < 1e-9, "taper discontinuity \(taper) at index \(entry.index)")
            }
        }
    }

    /// The complement of the boundary check: sampling either side must also converge, which rules
    /// out a jump that happens to leave both branch formulas agreeing at the point itself.
    @Test("Sampling either side of a boundary converges as the step shrinks")
    func gapShrinksWithStep() throws {
        let model = try #require(CurveModel(
            curves: [CurveBuilder.accelCurve(Self.defaultSpec)],
            acceleration: 0
        ))
        let knee = try #require(model.kneeRawSpeed)
        func gap(_ epsilon: Double) -> Double {
            abs(model.multiplier(rawSpeed: knee - epsilon) - model.multiplier(rawSpeed: knee + epsilon))
        }
        let coarse = gap(1e-6)
        let fine = gap(1e-8)
        #expect(fine < coarse / 10, "gap \(fine) did not shrink with the step from \(coarse)")
    }

    /// The single most dangerous mistake in the port: each gain is raised to *its own* power, so
    /// the parabolic term is `(gp * v)^2` and not `gp * v^2`. The two differ by a factor of `gp`,
    /// which would make `goodmouse plot` lie about what the kernel does.
    @Test("gainParabolic enters as (gain * speed)^2, not gain * speed^2")
    func parabolicGainIsRaisedToItsOwnPower() throws {
        let gp = 3.0
        let curve = AccelCurve(index: 0, gainLinear: 0, gainParabolic: gp)
        // No tangents, so the polynomial segment covers every speed.
        let model = try #require(CurveModel(curves: [curve], acceleration: 0, resolution: 67, rate: 67))

        // resolution == rate makes the normalised speed equal the raw speed.
        let v = 2.0
        #expect(model.normalizedSpeed(rawSpeed: v) == v)

        let correct = pow(gp * v, 2) * CurveModel.cursorScale
        let wrong = gp * pow(v, 2) * CurveModel.cursorScale
        let actual = model.multiplier(rawSpeed: v)

        #expect(abs(actual - correct) < 1e-12)
        #expect(abs(actual - wrong) > 1e-9, "the two forms must not coincide, or the test proves nothing")
    }

    @Test("Cubic and quartic gains are raised to their own powers too")
    func higherGainsAreRaisedToTheirOwnPowers() throws {
        let gc = 2.0, gq = 1.5, v = 1.7
        let curve = AccelCurve(index: 0, gainCubic: gc, gainQuartic: gq)
        let model = try #require(CurveModel(curves: [curve], acceleration: 0, resolution: 67, rate: 67))
        let expected = (pow(gc * v, 3) + pow(gq * v, 4)) * CurveModel.cursorScale
        #expect(abs(model.multiplier(rawSpeed: v) - expected) < 1e-12)
    }

    @Test("An acceleration index between two curves interpolates every parameter")
    func interpolatesBetweenCurves() throws {
        let lo = AccelCurve(index: 0, gainLinear: 1, gainParabolic: 2, gainCubic: 3, gainQuartic: 4,
                            tangentSpeedLinear: 10, tangentSpeedParabolicRoot: 20)
        let hi = AccelCurve(index: 1, gainLinear: 3, gainParabolic: 6, gainCubic: 7, gainQuartic: 8,
                            tangentSpeedLinear: 30, tangentSpeedParabolicRoot: 40)

        let model = try #require(CurveModel(curves: [lo, hi], acceleration: 0.25))
        let c = model.curve
        #expect(abs(c.gainLinear - 1.5) < 1e-12)
        #expect(abs(c.gainParabolic - 3.0) < 1e-12)
        #expect(abs(c.gainCubic - 4.0) < 1e-12)
        #expect(abs(c.gainQuartic - 5.0) < 1e-12)
        #expect(abs(c.tangentSpeedLinear - 15.0) < 1e-12)
        #expect(abs(c.tangentSpeedParabolicRoot - 25.0) < 1e-12)
        #expect(abs(c.index - 0.25) < 1e-12)
    }

    @Test("An index at or past the last curve uses that curve unchanged")
    func clampsToLastCurve() throws {
        let lo = AccelCurve(index: 0, gainLinear: 1, tangentSpeedLinear: 10)
        let hi = AccelCurve(index: 1, gainLinear: 3, tangentSpeedLinear: 30)

        let exact = try #require(CurveModel(curves: [lo, hi], acceleration: 1))
        #expect(exact.curve == hi)

        let beyond = try #require(CurveModel(curves: [lo, hi], acceleration: 99))
        #expect(beyond.curve == hi)
    }

    @Test("An index below the first curve uses the first curve")
    func clampsToFirstCurve() throws {
        let first = AccelCurve(index: 5, gainLinear: 1, tangentSpeedLinear: 10)
        let second = AccelCurve(index: 9, gainLinear: 3, tangentSpeedLinear: 30)
        let model = try #require(CurveModel(curves: [first, second], acceleration: 1))
        #expect(model.curve == first)
    }

    @Test("A negative acceleration builds no model at all")
    func negativeAccelerationDisablesAcceleration() {
        #expect(CurveModel(curves: AppleDefaultCurves.curves, acceleration: -1) == nil)
    }

    @Test("A curve set whose gains are all zero builds no model")
    func allZeroGainsAreDiscarded() {
        let dead = AccelCurve(index: 0, tangentSpeedLinear: 8, tangentSpeedParabolicRoot: 18)
        #expect(dead.isValid == false)
        #expect(CurveModel(curves: [dead], acceleration: 0) == nil)
    }

    @Test("An empty curve set builds no model")
    func emptyCurveSet() {
        #expect(CurveModel(curves: [], acceleration: 0) == nil)
    }

    @Test("Invalid curves are dropped, leaving the valid ones in force")
    func invalidCurvesAreSkipped() throws {
        let dead = AccelCurve(index: 0, tangentSpeedLinear: 1)
        let live = AccelCurve(index: 0, gainLinear: 2, tangentSpeedLinear: 5)
        let model = try #require(CurveModel(curves: [dead, live], acceleration: 0))
        #expect(model.curve == live)
    }

    @Test("Higher resolution means a lower multiplier at the same device speed")
    func higherResolutionIsSlower() throws {
        let curve = CurveBuilder.accelCurve(Self.defaultSpec)
        let fast = try #require(CurveModel(curves: [curve], acceleration: 0.6875, resolution: 400))
        let slow = try #require(CurveModel(curves: [curve], acceleration: 0.6875, resolution: 1200))
        // The same raw count normalises to a smaller speed at higher resolution, and the curve is
        // increasing — so it lands lower on the curve.
        #expect(slow.multiplier(rawSpeed: 10) < fast.multiplier(rawSpeed: 10))
    }

    @Test("With no tangents at all the polynomial covers every speed")
    func noTangents() throws {
        let curve = AccelCurve(index: 0, gainLinear: 2)
        let model = try #require(CurveModel(curves: [curve], acceleration: 0, resolution: 67, rate: 67))
        #expect(model.kneeRawSpeed == nil)
        #expect(model.taperRawSpeed == nil)
        #expect(abs(model.multiplier(rawSpeed: 1000) - 2 * 1000 * CurveModel.cursorScale) < 1e-6)
    }

    /// With no knee but a taper set, the polynomial hands straight to the square root — the filter
    /// skips the straight-line segment because it only takes it when the first tangent came from
    /// `tangentSpeedLinear`.
    @Test("A taper with no knee skips the straight-line segment")
    func taperWithoutKnee() throws {
        let curve = AccelCurve(index: 0, gainLinear: 1, tangentSpeedParabolicRoot: 12)
        let model = try #require(CurveModel(curves: [curve], acceleration: 0, resolution: 67, rate: 67))
        #expect(model.usesLinearSegment == false)
        #expect(model.kneeRawSpeed == 12)
        #expect(model.taperRawSpeed == nil)

        let gap = try #require(Self.segmentGaps(model).knee)
        #expect(gap < 1e-9, "discontinuity of \(gap) where the polynomial meets the square root")
    }

    @Test("The scaling constants match the kernel's")
    func constants() {
        #expect(CurveModel.frameRate == 67.0)
        #expect(CurveModel.screenResolution == 96.0)
        #expect(CurveModel.cursorScale == 96.0 / 67.0)
        #expect(CurveModel.defaultResolution == 400.0)
    }
}
