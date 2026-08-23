import Testing
@testable import GoodMouseKit

/// Stands in for a real service so ordering can be checked without hardware.
struct FakeService: ServiceKeys {
    var pointerAccelerationKey: String = HIDKeys.mouseAcceleration
    var scrollAccelerationKey: String = HIDKeys.mouseScrollAcceleration
    var publishedScrollResolutionAxisKeys: [String] = []
}

@Suite("WritePlanner")
struct WritePlannerTests {
    static let curveAxis = AxisSettings(mode: .curve, resolution: 800, acceleration: 0.5, curve: CurveSpec())

    /// The single ordering rule that makes any of this work: resolution is *not* one of the keys
    /// whose arrival triggers a rebuild, so it must already be in place; the acceleration value is,
    /// so it goes last and fires the rebuild that picks up everything before it.
    @Test("Resolution is written first and the acceleration key last")
    func orderingIsResolutionFirstAccelerationLast() {
        let plan = WritePlanner.pointerPlan(Self.curveAxis, on: FakeService())
        #expect(plan.first?.key == HIDKeys.pointerResolution)
        #expect(plan.last?.key == HIDKeys.mouseAcceleration)
    }

    @Test("The curve, the algorithm and the linear flag all land between the two")
    func middleOfThePlan() {
        let keys = WritePlanner.pointerPlan(Self.curveAxis, on: FakeService()).map(\.key)
        #expect(keys == [
            HIDKeys.pointerResolution,
            HIDKeys.userPointerAccelCurves,
            HIDKeys.pointerAccelerationAlgorithm,
            HIDKeys.useLinearScalingMouseAcceleration,
            HIDKeys.mouseAcceleration,
        ])
    }

    @Test("Curve mode selects the parametric algorithm and clears the linear short-circuit")
    func curveModeValues() throws {
        let plan = WritePlanner.pointerPlan(Self.curveAxis, on: FakeService())
        let byKey = Dictionary(uniqueKeysWithValues: plan.map { ($0.key, $0.value) })
        #expect(byKey[HIDKeys.pointerAccelerationAlgorithm] == .int(HIDKeys.Algorithm.parametric.rawValue))
        #expect(byKey[HIDKeys.useLinearScalingMouseAcceleration] == .int(0))
        #expect(byKey[HIDKeys.pointerResolution] == .int(IOFixed.from(800)))
        #expect(byKey[HIDKeys.mouseAcceleration] == .int(IOFixed.from(0.5)))
    }

    /// The device's own type key decides where the acceleration value goes. Writing to a key the
    /// filter does not read is a silent no-op.
    @Test("The acceleration write follows the service's own acceleration key")
    func honoursTheServiceAccelerationKey() {
        let trackpad = FakeService(pointerAccelerationKey: "HIDTrackpadAcceleration")
        let plan = WritePlanner.pointerPlan(Self.curveAxis, on: trackpad)
        #expect(plan.last?.key == "HIDTrackpadAcceleration")
    }

    @Test("Raw mode writes a single negative acceleration and nothing else")
    func rawMode() throws {
        let plan = WritePlanner.pointerPlan(AxisSettings(mode: .raw), on: FakeService())
        #expect(plan.count == 1)
        let write = try #require(plan.first)
        #expect(write.key == HIDKeys.mouseAcceleration)
        #expect(write.value == .int(-65536))
        // Negative is the whole mechanism: the filter returns before building any accelerator.
        #expect(IOFixed.toDouble(-65536) < 0)
    }

    @Test("Linear mode sets the short-circuit flag and skips resolution and curves")
    func linearMode() {
        let axis = AxisSettings(mode: .linear, resolution: 800, acceleration: 2)
        let keys = WritePlanner.pointerPlan(axis, on: FakeService()).map(\.key)
        #expect(keys.contains(HIDKeys.useLinearScalingMouseAcceleration))
        #expect(keys.contains(HIDKeys.pointerResolution) == false)
        #expect(keys.contains(HIDKeys.userPointerAccelCurves) == false)
        #expect(keys.last == HIDKeys.mouseAcceleration)
    }

    @Test("Linear mode writes the acceleration minimum only when one is configured")
    func linearMinimum() {
        let without = AxisSettings(mode: .linear, acceleration: 0)
        #expect(WritePlanner.pointerPlan(without, on: FakeService())
            .map(\.key).contains(HIDKeys.pointerAccelerationMinimum) == false)

        let with = AxisSettings(mode: .linear, acceleration: 0, accelerationMinimum: 0.25)
        #expect(WritePlanner.pointerPlan(with, on: FakeService())
            .map(\.key).contains(HIDKeys.pointerAccelerationMinimum))
    }

    /// The filter takes the linear-scaling path only for mouse acceleration, so on a trackpad the
    /// mode would be silently ignored. Saying so beats letting it look applied.
    @Test("Linear mode is flagged as unavailable on a non-mouse acceleration type")
    func linearUnavailableOnTrackpad() {
        #expect(WritePlanner.linearModeUnavailableReason(on: FakeService()) == nil)
        let trackpad = FakeService(pointerAccelerationKey: "HIDTrackpadAcceleration")
        let reason = WritePlanner.linearModeUnavailableReason(on: trackpad)
        #expect(reason?.contains("HIDTrackpadAcceleration") == true)
    }

    // MARK: Scroll

    /// The filter reads `HIDScrollResolutionX/Y/Z` first per axis, so writing only the generic key
    /// would leave any published axis key in force.
    @Test("Published per-axis scroll resolution keys are written alongside the generic one")
    func scrollResolutionAxisKeys() {
        let bare = FakeService()
        let bareKeys = WritePlanner.scrollPlan(Self.curveAxis, on: bare).map(\.key)
        #expect(bareKeys.filter { $0.hasPrefix("HIDScrollResolution") } == [HIDKeys.scrollResolution])

        let perAxis = FakeService(publishedScrollResolutionAxisKeys: [
            HIDKeys.scrollResolutionX, HIDKeys.scrollResolutionY,
        ])
        let perAxisKeys = WritePlanner.scrollPlan(Self.curveAxis, on: perAxis).map(\.key)
        #expect(perAxisKeys.contains(HIDKeys.scrollResolutionX))
        #expect(perAxisKeys.contains(HIDKeys.scrollResolutionY))
        // Not invented where the device publishes none — that would change how the filter reads it.
        #expect(perAxisKeys.contains(HIDKeys.scrollResolutionZ) == false)
    }

    @Test("Scroll resolution uses the scroll clamp, not the pointer's")
    func scrollUsesScrollClamp() throws {
        let axis = AxisSettings(mode: .linear, resolution: 9, acceleration: 0.3125)
        let plan = WritePlanner.scrollPlan(axis, on: FakeService())
        let write = try #require(plan.first { $0.key == HIDKeys.scrollResolution })
        #expect(write.value == .int(IOFixed.from(9)))
    }

    @Test("The scroll plan also ends on its acceleration key")
    func scrollOrdering() {
        let plan = WritePlanner.scrollPlan(Self.curveAxis, on: FakeService())
        #expect(plan.first?.key == HIDKeys.scrollResolution)
        #expect(plan.last?.key == HIDKeys.mouseScrollAcceleration)
    }

    @Test("A profile with both axes plans pointer first, then scroll")
    func fullPlan() {
        let profile = Profile(
            pointer: Self.curveAxis,
            scroll: AxisSettings(mode: .linear, resolution: 9, acceleration: 0.3125)
        )
        let keys = WritePlanner.plan(for: profile, on: FakeService()).map(\.key)
        let pointerEnd = keys.firstIndex(of: HIDKeys.mouseAcceleration)
        let scrollStart = keys.firstIndex(of: HIDKeys.scrollResolution)
        #expect(pointerEnd != nil && scrollStart != nil)
        #expect(pointerEnd! < scrollStart!)
    }

    @Test("A profile with neither axis plans nothing")
    func emptyProfile() {
        #expect(WritePlanner.plan(for: Profile(), on: FakeService()).isEmpty)
    }

    @Test("Every key the planner writes has a documented neutral or is a resolution/acceleration key")
    func restoreCoversEveryPlannedKey() {
        let service = FakeService(publishedScrollResolutionAxisKeys: [HIDKeys.scrollResolutionX])
        let profile = Profile(pointer: Self.curveAxis, scroll: Self.curveAxis)
        for write in WritePlanner.plan(for: profile, on: service) {
            let recoverable = Applicator.neutralValues[write.key] != nil
                || write.key.contains("Resolution")
                || write.key == service.pointerAccelerationKey
                || write.key == service.scrollAccelerationKey
            #expect(recoverable, "\(write.key) has no way back to a stock value")
        }
    }
}

@Suite("LaunchAgent")
struct LaunchAgentTests {
    @Test("The plist names the binary, the watch subcommand and the log paths")
    func plistContents() {
        let plist = LaunchAgent.plist(executablePath: "/usr/local/bin/goodmouse", configPath: nil)
        #expect(plist.contains("<string>/usr/local/bin/goodmouse</string>"))
        #expect(plist.contains("<string>watch</string>"))
        #expect(plist.contains("dev.samiam.goodmouse"))
        #expect(plist.contains("RunAtLoad"))
        #expect(plist.contains("KeepAlive"))
        #expect(plist.contains("Library/Logs/goodmouse"))
    }

    @Test("A custom config path is passed through to the agent")
    func plistCarriesConfigPath() {
        let plist = LaunchAgent.plist(executablePath: "/usr/local/bin/goodmouse", configPath: "/tmp/c.json")
        #expect(plist.contains("<string>--config</string>"))
        #expect(plist.contains("<string>/tmp/c.json</string>"))
    }

    @Test("Paths with XML metacharacters are escaped")
    func plistEscapes() {
        let plist = LaunchAgent.plist(executablePath: "/tmp/a&b<c>/goodmouse", configPath: nil)
        #expect(plist.contains("/tmp/a&amp;b&lt;c&gt;/goodmouse"))
        #expect(plist.contains("a&b<c>") == false)
    }

    @Test("The service target is scoped to the current GUI session")
    func serviceTarget() {
        #expect(LaunchAgent.serviceTarget.hasPrefix("gui/"))
        #expect(LaunchAgent.serviceTarget.hasSuffix("/dev.samiam.goodmouse"))
    }
}
