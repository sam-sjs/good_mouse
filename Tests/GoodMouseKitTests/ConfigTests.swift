import Foundation
import Testing
@testable import GoodMouseKit

@Suite("Config")
struct ConfigTests {
    static func decode(_ json: String) throws -> (config: Config, warnings: [ConfigWarning]) {
        try ConfigLoader.decode(Data(json.utf8))
    }

    // MARK: Defaults

    @Test("An axis with only a mode picks up every default")
    func defaults() throws {
        let (config, _) = try Self.decode("""
        {
          "devices": [{ "match": { "product": "X*" }, "profile": "p" }],
          "profiles": { "p": { "pointer": { "mode": "curve", "curve": { "gainLinear": 1 } } } }
        }
        """)
        let pointer = try #require(config.profiles["p"]?.pointer)
        #expect(pointer.resolution == CurveModel.defaultResolution)
        #expect(pointer.acceleration == AxisSettings.defaultAcceleration)
        #expect(pointer.accelerationMinimum == nil)
    }

    @Test("An axis with no mode defaults to curve")
    func defaultMode() throws {
        let (config, _) = try Self.decode("""
        {
          "devices": [{ "match": { "product": "X*" }, "profile": "p" }],
          "profiles": { "p": { "pointer": { "curve": { "gainLinear": 1 } } } }
        }
        """)
        #expect(config.profiles["p"]?.pointer?.mode == .curve)
    }

    @Test("A curve block with no gains at all defaults to a usable shape")
    func curveDefaults() {
        let spec = CurveSpec()
        #expect(spec.hasNonZeroGain)
        #expect(spec.gainLinear == 1.0)
        #expect(spec.kneeSpeed == 8.0)
        #expect(spec.taperSpeed == 18.0)
    }

    // MARK: Clamping

    @Test("Pointer resolution clamps into 10…1995 and says so")
    func clamping() throws {
        for (input, expected) in [(1.0, 10.0), (9999.0, 1995.0), (400.0, 400.0)] {
            let axis = AxisSettings(mode: .curve, resolution: input, curve: CurveSpec())
            #expect(axis.clampedResolution(for: .pointer) == expected)
            #expect(axis.resolutionWasClamped(for: .pointer) == (input != expected))
        }
    }

    /// Scroll resolution is a much smaller figure than pointer DPI — a stock device publishes 9 —
    /// so the pointer's floor of 10 must not be applied to it.
    @Test("Scroll resolution is not clamped by the pointer's floor")
    func scrollClampIsSeparate() {
        let axis = AxisSettings(mode: .linear, resolution: 9)
        #expect(axis.clampedResolution(for: .scroll) == 9)
        #expect(axis.resolutionWasClamped(for: .scroll) == false)
        // The same value would be pushed up to 10 on the pointer axis.
        #expect(axis.clampedResolution(for: .pointer) == 10)
    }

    @Test("A clamped resolution produces a warning, not a failure")
    func clampingWarns() throws {
        let (_, warnings) = try Self.decode("""
        {
          "devices": [{ "match": { "product": "X*" }, "profile": "p" }],
          "profiles": { "p": { "pointer": { "resolution": 9000, "curve": { "gainLinear": 1 } } } }
        }
        """)
        #expect(warnings.contains { $0.description.contains("clamped to 1995") })
    }

    // MARK: Errors

    @Test("Malformed JSON reports the path that is wrong")
    func malformedJSON() {
        #expect(throws: ConfigError.self) {
            try Self.decode("{ this is not json")
        }
    }

    @Test("A wrongly typed field names the field")
    func typeMismatch() throws {
        do {
            _ = try Self.decode("""
            {
              "devices": [],
              "profiles": { "p": { "pointer": { "resolution": "fast" } } }
            }
            """)
            Issue.record("expected a decoding failure")
        } catch let error as ConfigError {
            #expect("\(error)".contains("resolution"))
        }
    }

    @Test("A rule naming an undefined profile is rejected, and lists what is defined")
    func unknownProfile() throws {
        do {
            _ = try Self.decode("""
            {
              "devices": [{ "match": { "product": "X*" }, "profile": "nope" }],
              "profiles": { "trackball": {} }
            }
            """)
            Issue.record("expected validation to fail")
        } catch let error as ConfigError {
            let text = "\(error)"
            #expect(text.contains("nope"))
            #expect(text.contains("trackball"))
        }
    }

    /// An empty matcher would claim every pointing device on the system, including the trackpad.
    @Test("An empty match block is rejected")
    func emptyMatch() {
        #expect(throws: ConfigError.self) {
            try Self.decode("""
            {
              "devices": [{ "match": {}, "profile": "p" }],
              "profiles": { "p": {} }
            }
            """)
        }
    }

    /// The kernel discards a curve with no gains and then builds no accelerator at all, so the
    /// pointer would go raw rather than slow. Failing loudly beats that.
    @Test("A curve with every gain at zero is rejected")
    func allZeroGainsRejected() throws {
        do {
            _ = try Self.decode("""
            {
              "devices": [{ "match": { "product": "X*" }, "profile": "p" }],
              "profiles": { "p": { "pointer": { "mode": "curve", "curve": {
                  "gainLinear": 0, "gainParabolic": 0, "gainCubic": 0, "gainQuartic": 0,
                  "kneeSpeed": 8, "taperSpeed": 18
              } } } }
            }
            """)
            Issue.record("expected validation to fail")
        } catch let error as ConfigError {
            #expect("\(error)".contains("gainLinear"))
        }
    }

    @Test("Curve mode with no curve block is rejected")
    func curveModeNeedsACurve() {
        #expect(throws: ConfigError.self) {
            try Self.decode("""
            {
              "devices": [{ "match": { "product": "X*" }, "profile": "p" }],
              "profiles": { "p": { "pointer": { "mode": "curve" } } }
            }
            """)
        }
    }

    @Test("A negative acceleration is rejected in curve mode, pointing at raw mode")
    func negativeAccelerationRejected() throws {
        do {
            _ = try Self.decode("""
            {
              "devices": [{ "match": { "product": "X*" }, "profile": "p" }],
              "profiles": { "p": { "pointer": { "acceleration": -1, "curve": { "gainLinear": 1 } } } }
            }
            """)
            Issue.record("expected validation to fail")
        } catch let error as ConfigError {
            #expect("\(error)".contains("raw"))
        }
    }

    // MARK: Warnings

    @Test("A taper at or below the knee warns that the straight segment is empty")
    func taperBelowKneeWarns() throws {
        let (_, warnings) = try Self.decode("""
        {
          "devices": [{ "match": { "product": "X*" }, "profile": "p" }],
          "profiles": { "p": { "pointer": { "curve": {
              "gainLinear": 1, "kneeSpeed": 20, "taperSpeed": 10
          } } } }
        }
        """)
        #expect(warnings.contains { $0.description.contains("taperSpeed") })
    }

    @Test("Linear mode warns that resolution is ignored")
    func linearIgnoresResolutionWarning() throws {
        let (_, warnings) = try Self.decode("""
        {
          "devices": [{ "match": { "product": "X*" }, "profile": "p" }],
          "profiles": { "p": { "pointer": { "mode": "linear", "resolution": 800, "acceleration": 1 } } }
        }
        """)
        #expect(warnings.contains { $0.description.contains("ignores `resolution`") })
    }

    @Test("An empty devices list warns rather than failing")
    func emptyDevicesWarns() throws {
        let (_, warnings) = try Self.decode("""
        { "devices": [], "profiles": {} }
        """)
        #expect(warnings.contains { $0.description.contains("no device will ever be configured") })
    }

    // MARK: The shipped default

    @Test("The default config parses, validates, and matches the virtual device")
    func defaultConfigIsValid() throws {
        let (config, warnings) = try Self.decode(DefaultConfig.json)
        #expect(warnings.isEmpty, "default config produced warnings: \(warnings)")

        let virtualDevice = DeviceInfo(
            registryID: 0x100000a8a,
            product: "Karabiner DriverKit VirtualHIDPointing 1.8.0",
            vendorID: 0x16C0,
            productID: 0x27DA,
            primaryUsagePage: 1,
            primaryUsage: 2,
            transport: nil
        )
        let match = try #require(config.profile(for: virtualDevice))
        #expect(match.name == "trackball")
        #expect(match.profile.pointer?.mode == .curve)
    }

    /// The default config carries comments, which is only legal because the loader enables JSON5.
    @Test("The default config really does contain comments")
    func defaultConfigHasComments() {
        #expect(DefaultConfig.json.contains("//"))
    }

    @Test("The default config leaves the trackpad and the physical trackball alone")
    func defaultConfigDoesNotClaimOtherDevices() throws {
        let (config, _) = try Self.decode(DefaultConfig.json)
        let others = [
            DeviceInfo(registryID: 1, product: "Apple Internal Keyboard / Trackpad",
                       vendorID: 1452, productID: 638, primaryUsagePage: 1, primaryUsage: 2, transport: "USB"),
            DeviceInfo(registryID: 2, product: "DEFT Pro TrackBall",
                       vendorID: 1390, productID: 306, primaryUsagePage: 1, primaryUsage: 2, transport: "USB"),
        ]
        for device in others {
            #expect(config.profile(for: device) == nil, "\(device.displayName) should not match")
        }
    }
}
