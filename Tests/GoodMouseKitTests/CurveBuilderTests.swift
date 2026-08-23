import Testing
@testable import GoodMouseKit

@Suite("CurveBuilder")
struct CurveBuilderTests {
    @Test("Doubles survive the IOFixed round trip to within one step")
    func roundTrip() {
        let step = 1.0 / IOFixed.scale
        let values: [Double] = [0, 1, 0.6875, 0.08, 0.4, 8, 18, 1995, 400, 0.0001, 123.456, -1, -0.5]
        for value in values {
            let recovered = IOFixed.toDouble(IOFixed.from(value))
            #expect(abs(recovered - value) <= step / 2 + 1e-12, "\(value) came back as \(recovered)")
        }
    }

    @Test("A CurveSpec survives the round trip through its IOFixed dictionary")
    func curveRoundTrip() {
        let step = 1.0 / IOFixed.scale
        let spec = CurveSpec(
            gainLinear: 1.25, gainParabolic: 0.4, gainCubic: 0.08, gainQuartic: 0.015,
            kneeSpeed: 8.5, taperSpeed: 18.25
        )
        let recovered = CurveBuilder.curve(from: CurveBuilder.curveDictionary(spec))

        #expect(abs(recovered.gainLinear - spec.gainLinear) <= step)
        #expect(abs(recovered.gainParabolic - spec.gainParabolic) <= step)
        #expect(abs(recovered.gainCubic - spec.gainCubic) <= step)
        #expect(abs(recovered.gainQuartic - spec.gainQuartic) <= step)
        #expect(abs(recovered.tangentSpeedLinear - spec.kneeSpeed) <= step)
        #expect(abs(recovered.tangentSpeedParabolicRoot - spec.taperSpeed) <= step)
        #expect(recovered.index == 0)
    }

    @Test("Every curve key is present in the emitted dictionary")
    func emitsEveryKey() {
        let dictionary = CurveBuilder.curveDictionary(CurveSpec())
        let expected = [
            HIDKeys.accelIndex,
            HIDKeys.accelGainLinear, HIDKeys.accelGainParabolic,
            HIDKeys.accelGainCubic, HIDKeys.accelGainQuartic,
            HIDKeys.accelTangentSpeedLinear, HIDKeys.accelTangentSpeedParabolicRoot,
        ]
        #expect(Set(dictionary.keys) == Set(expected))
    }

    /// The user-curve keys really are unprefixed. Getting "corrected" to `HIDUserPointer…` would
    /// write a key nothing reads, and the failure would be silent.
    @Test("The SPI curve keys carry no HID prefix")
    func spiKeyLiterals() {
        #expect(HIDKeys.userPointerAccelCurves == "UserPointerAccelCurvesKey")
        #expect(HIDKeys.userScrollAccelCurves == "UserScrollAccelCurvesKey")
    }

    @Test("Missing keys read back as zero, as the kernel treats them")
    func absentKeysAreZero() {
        let curve = CurveBuilder.curve(from: [HIDKeys.accelGainLinear: 65536])
        #expect(curve.gainLinear == 1.0)
        #expect(curve.gainParabolic == 0)
        #expect(curve.tangentSpeedLinear == 0)
    }

    @Test("A profile in curve mode yields a model; linear and raw do not")
    func modelForAxis() {
        #expect(CurveBuilder.model(for: AxisSettings(mode: .curve, curve: CurveSpec())) != nil)
        #expect(CurveBuilder.model(for: AxisSettings(mode: .linear)) == nil)
        #expect(CurveBuilder.model(for: AxisSettings(mode: .raw)) == nil)
        // Curve mode with no curve block cannot produce one either.
        #expect(CurveBuilder.model(for: AxisSettings(mode: .curve, curve: nil)) == nil)
    }

    @Test("The model uses the clamped resolution, not the raw one")
    func modelUsesClampedResolution() throws {
        let axis = AxisSettings(mode: .curve, resolution: 9000, curve: CurveSpec())
        let model = try #require(CurveBuilder.model(for: axis))
        #expect(model.resolution == AxisKind.pointer.resolutionRange.upperBound)
    }
}
