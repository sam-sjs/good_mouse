import Testing
@testable import GoodMouseKit

/// Records every write so the trigger behaviour can be asserted without hardware.
final class RecordingService: PropertyStore {
    var pointerAccelerationKey = HIDKeys.mouseAcceleration
    var scrollAccelerationKey = HIDKeys.mouseScrollAcceleration
    var publishedScrollResolutionAxisKeys: [String] = []

    let registryID: UInt64 = 0xfeed
    var stored: [String: PropertyValue] = [:]
    var writeLog: [String] = []

    func copyProperty(_ key: String) -> PropertyValue? { stored[key] }

    @discardableResult
    func setProperty(_ key: String, _ value: PropertyValue) -> Bool {
        stored[key] = value
        writeLog.append(key)
        return true
    }
}

/// Drives the real `Applicator`, so this suite cannot pass while the shipping logic is wrong.
func applyPlan(_ plan: [PropertyWrite], to service: RecordingService) {
    Applicator().apply(plan, to: service)
}

@Suite("Rebuild trigger")
struct RebuildTriggerTests {
    static func axis(resolution: Double, gainLinear: Double = 1.0) -> AxisSettings {
        AxisSettings(
            mode: .curve,
            resolution: resolution,
            acceleration: 0.6875,
            curve: CurveSpec(
                gainLinear: gainLinear, gainParabolic: 0, gainCubic: 0, gainQuartic: 0,
                kneeSpeed: 0, taperSpeed: 0
            )
        )
    }

    @Test("Each axis plan ends on exactly one rebuild trigger")
    func exactlyOneTriggerPerAxis() {
        let service = RecordingService()
        let pointer = WritePlanner.pointerPlan(Self.axis(resolution: 400), on: service)
        #expect(pointer.filter(\.triggersRebuild).count == 1)
        #expect(pointer.last?.triggersRebuild == true)

        let scroll = WritePlanner.scrollPlan(Self.axis(resolution: 9), on: service)
        #expect(scroll.filter(\.triggersRebuild).count == 1)
        #expect(scroll.last?.triggersRebuild == true)
    }

    @Test("Every mode marks its trigger", arguments: [AxisMode.curve, .linear, .raw])
    func everyModeHasATrigger(mode: AxisMode) {
        let service = RecordingService()
        var axis = Self.axis(resolution: 400)
        axis.mode = mode
        let plan = WritePlanner.pointerPlan(axis, on: service)
        #expect(plan.last?.triggersRebuild == true, "\(mode) has no rebuild trigger")
    }

    /// The exact on-device failure: two configs that differ *only* in resolution. Resolution is not
    /// a cached key, so without forcing the trailing acceleration write nothing rebuilds the
    /// accelerator and the new resolution is stored but never used.
    @Test("A resolution-only change still fires the rebuild trigger")
    func resolutionOnlyChangeStillTriggersRebuild() {
        let service = RecordingService()

        // First apply: everything differs, so the trigger is written on value alone.
        applyPlan(WritePlanner.pointerPlan(Self.axis(resolution: 1995), on: service), to: service)
        #expect(service.stored[HIDKeys.pointerResolution] == .int(IOFixed.from(1995)))

        // Second apply: identical curve and acceleration, only resolution moves.
        service.writeLog.removeAll()
        applyPlan(WritePlanner.pointerPlan(Self.axis(resolution: 10), on: service), to: service)

        #expect(service.writeLog.contains(HIDKeys.pointerResolution))
        #expect(
            service.writeLog.contains(HIDKeys.mouseAcceleration),
            "the acceleration key was skipped, so nothing rebuilt the accelerator and resolution 10 is inert"
        )
        // And the trigger must still land last, after the resolution it exists to pick up.
        #expect(service.writeLog.last == HIDKeys.mouseAcceleration)
    }

    /// The counterpart: forcing the trigger must not become an unconditional write, or the
    /// property-changed callback in `watch` would drive an endless reassert loop.
    @Test("A pass with nothing to change writes nothing at all")
    func converges() {
        let service = RecordingService()
        let plan = WritePlanner.pointerPlan(Self.axis(resolution: 400), on: service)

        applyPlan(plan, to: service)
        #expect(service.writeLog.isEmpty == false)

        // Second pass over an already-correct service.
        service.writeLog.removeAll()
        applyPlan(plan, to: service)
        #expect(service.writeLog.isEmpty, "reapplying an unchanged plan wrote \(service.writeLog)")

        // And a third, to be sure it is a fixed point rather than an alternation.
        applyPlan(plan, to: service)
        #expect(service.writeLog.isEmpty)
    }

    @Test("Only the axis that changed re-fires its own trigger")
    func triggersAreScopedToTheirAxis() {
        let service = RecordingService()
        let before = Profile(pointer: Self.axis(resolution: 400), scroll: Self.axis(resolution: 9))
        applyPlan(WritePlanner.plan(for: before, on: service), to: service)

        // Move the pointer resolution only; scroll is untouched.
        service.writeLog.removeAll()
        let after = Profile(pointer: Self.axis(resolution: 800), scroll: Self.axis(resolution: 9))
        applyPlan(WritePlanner.plan(for: after, on: service), to: service)

        #expect(service.writeLog.contains(HIDKeys.mouseAcceleration))
        #expect(
            service.writeLog.contains(HIDKeys.mouseScrollAcceleration) == false,
            "scroll did not change, so its trigger should not have been forced"
        )
    }

    /// `goodmouse restore` builds its plan from `stockPlan`, which originally created its writes
    /// without `triggersRebuild` — reproducing the stranded-resolution bug on the restore path.
    @Test("The stock plan fires the rebuild trigger too")
    func stockPlanTriggersRebuild() throws {
        let service = RecordingService()

        // Land a profile whose resolution differs from stock but whose acceleration matches it.
        let axis = AxisSettings(
            mode: .curve,
            resolution: 1200,
            acceleration: AxisSettings.defaultAcceleration,
            curve: CurveSpec(gainLinear: 1, gainParabolic: 0, gainCubic: 0, gainQuartic: 0,
                             kneeSpeed: 0, taperSpeed: 0)
        )
        let plan = WritePlanner.pointerPlan(axis, on: service)
        applyPlan(plan, to: service)

        let stock = WritePlanner.stockPlan(for: plan, on: service)
        #expect(stock.contains { $0.triggersRebuild }, "no write in the stock plan fires a rebuild")

        service.writeLog.removeAll()
        applyPlan(stock, to: service)

        #expect(service.writeLog.contains(HIDKeys.pointerResolution))
        #expect(
            service.writeLog.contains(HIDKeys.mouseAcceleration),
            "acceleration already matched stock, so without a forced trigger the restored resolution is inert"
        )
        #expect(service.writeLog.last == HIDKeys.mouseAcceleration)
        #expect(service.stored[HIDKeys.pointerResolution] == .int(IOFixed.from(CurveModel.defaultResolution)))
    }

    /// Writing the pointer defaults to the scroll keys is far worse than leaving them: stock scroll
    /// resolution on this machine is 9, so 400 would be a 44× change to how fast the wheel scrolls.
    @Test("The stock plan never writes pointer defaults to scroll keys")
    func stockPlanOmitsScrollKeys() {
        let service = RecordingService()
        let plan = WritePlanner.plan(
            for: Profile(pointer: Self.axis(resolution: 1200), scroll: Self.axis(resolution: 9)),
            on: service
        )
        let stock = WritePlanner.stockPlan(for: plan, on: service)
        let keys = stock.map(\.key)

        #expect(keys.contains(HIDKeys.pointerResolution))
        #expect(keys.contains(HIDKeys.mouseAcceleration))
        // Neither scroll value has a knowable stock, so neither may be written.
        #expect(keys.contains(HIDKeys.scrollResolution) == false)
        #expect(keys.contains(HIDKeys.mouseScrollAcceleration) == false)

        // …and the command is able to tell the user what it skipped.
        let untouched = WritePlanner.unrestorableKeys(in: plan, on: service)
        #expect(untouched.contains(HIDKeys.scrollResolution))
        #expect(untouched.contains(HIDKeys.mouseScrollAcceleration))
    }

    @Test("The stock plan converges like every other plan")
    func stockPlanConverges() {
        let service = RecordingService()
        let plan = WritePlanner.pointerPlan(Self.axis(resolution: 400), on: service)
        let stock = WritePlanner.stockPlan(for: plan, on: service)

        applyPlan(stock, to: service)
        service.writeLog.removeAll()
        applyPlan(stock, to: service)
        #expect(service.writeLog.isEmpty, "reapplying the stock plan wrote \(service.writeLog)")
    }

    @Test("A changed curve alone also carries the trigger")
    func curveChangeTriggersRebuild() {
        let service = RecordingService()
        applyPlan(WritePlanner.pointerPlan(Self.axis(resolution: 400, gainLinear: 1.0), on: service), to: service)

        service.writeLog.removeAll()
        applyPlan(WritePlanner.pointerPlan(Self.axis(resolution: 400, gainLinear: 2.0), on: service), to: service)

        #expect(service.writeLog.contains(HIDKeys.userPointerAccelCurves))
        #expect(service.writeLog.last == HIDKeys.mouseAcceleration)
    }
}
