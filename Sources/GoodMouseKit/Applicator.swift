import Foundation

/// One property write, in the order it must happen.
public struct PropertyWrite: Equatable, Sendable {
    public let key: String
    public let value: PropertyValue
    /// Why this write is here — shown by `apply --dry-run`.
    public let note: String
    /// True for the write that fires the filter's `setupAcceleration()` rebuild: the acceleration
    /// key each axis plan ends on. Everything before it in the plan only takes effect once this
    /// lands, so `Applicator` re-writes it even when its value is unchanged.
    public let triggersRebuild: Bool

    public init(key: String, value: PropertyValue, note: String = "", triggersRebuild: Bool = false) {
        self.key = key
        self.value = value
        self.note = note
        self.triggersRebuild = triggersRebuild
    }
}

/// The little a `WritePlanner` needs to know about a service. Splitting it out keeps the write
/// ordering — the most fragile invariant in the project — testable without hardware.
public protocol ServiceKeys {
    /// The key that actually carries the pointer acceleration value for this service.
    var pointerAccelerationKey: String { get }
    /// The scroll counterpart.
    var scrollAccelerationKey: String { get }
    /// The per-axis scroll resolution keys the service publishes, which take precedence over the
    /// generic `HIDScrollResolution`.
    var publishedScrollResolutionAxisKeys: [String] { get }
}

/// A service whose properties can actually be read and written. `Applicator` is generic over this
/// so the trigger logic that took an on-device failure to find is covered by unit tests rather than
/// re-implemented in them.
public protocol PropertyStore: ServiceKeys {
    var registryID: UInt64 { get }
    func copyProperty(_ key: String) -> PropertyValue?
    @discardableResult
    func setProperty(_ key: String, _ value: PropertyValue) -> Bool
}

extension HIDService: PropertyStore {}

/// Builds the ordered write list for a profile against one service.
///
/// **The order matters and is not obvious.** The filter caches a fixed set of keys, and the arrival
/// of any cached key triggers a full `setupAcceleration()` rebuild. `HIDPointerResolution` is *not*
/// in that set: it is read fresh from the service during the rebuild, so it must already be in
/// place when the rebuild fires. The acceleration value is cached, so writing it last is what makes
/// everything before it take effect.
public enum WritePlanner {
    public static func plan(for profile: Profile, on service: some ServiceKeys) -> [PropertyWrite] {
        var writes: [PropertyWrite] = []
        if let pointer = profile.pointer {
            writes += pointerPlan(pointer, on: service)
        }
        if let scroll = profile.scroll {
            writes += scrollPlan(scroll, on: service)
        }
        return writes
    }

    // MARK: Pointer

    public static func pointerPlan(_ axis: AxisSettings, on service: some ServiceKeys) -> [PropertyWrite] {
        let accelKey = service.pointerAccelerationKey

        switch axis.mode {
        case .curve:
            guard let spec = axis.curve else { return [] }
            return [
                PropertyWrite(
                    key: HIDKeys.pointerResolution,
                    value: .int(IOFixed.from(axis.clampedResolution(for: .pointer))),
                    note: "read fresh during the rebuild, so it goes first"
                ),
                PropertyWrite(
                    key: HIDKeys.userPointerAccelCurves,
                    value: .curves([CurveBuilder.curveDictionary(spec)]),
                    note: "checked before the driver's own curves"
                ),
                PropertyWrite(
                    key: HIDKeys.pointerAccelerationAlgorithm,
                    value: .int(HIDKeys.Algorithm.parametric.rawValue),
                    note: "parametric"
                ),
                PropertyWrite(
                    key: HIDKeys.useLinearScalingMouseAcceleration,
                    value: .int(0),
                    note: "non-zero would short-circuit to a flat multiplier"
                ),
                PropertyWrite(
                    key: accelKey,
                    value: .int(IOFixed.from(axis.acceleration)),
                    note: "last — cached, so this fires the rebuild that picks up the rest",
                    triggersRebuild: true
                ),
            ]

        case .linear:
            // The short-circuit is taken before resolution or any curve is consulted, so writing
            // those here would be noise. It also requires the acceleration type to be
            // HIDMouseAcceleration — see `linearModeUnavailableReason`.
            var writes = [
                PropertyWrite(
                    key: HIDKeys.useLinearScalingMouseAcceleration,
                    value: .int(1),
                    note: "flat multiplier, no acceleration"
                )
            ]
            if let minimum = axis.accelerationMinimum {
                writes.append(PropertyWrite(
                    key: HIDKeys.pointerAccelerationMinimum,
                    value: .int(IOFixed.from(minimum)),
                    note: "floor, used when acceleration is 0"
                ))
            }
            writes.append(PropertyWrite(
                key: accelKey,
                value: .int(IOFixed.from(axis.acceleration)),
                note: "last — the multiplier, and the trigger for the rebuild",
                triggersRebuild: true
            ))
            return writes

        case .raw:
            // A negative acceleration makes the filter return before building any accelerator.
            // Resolution and curves become inert, so there is nothing else to write.
            return [
                PropertyWrite(
                    key: accelKey,
                    value: .int(IOFixed.from(-1)),
                    note: "negative — the filter builds no accelerator at all",
                    triggersRebuild: true
                )
            ]
        }
    }

    /// `mode: "linear"` only works when the filter classes the device's acceleration as *mouse*
    /// acceleration. Returns a reason string when it will not, or nil when it will.
    public static func linearModeUnavailableReason(on service: some ServiceKeys) -> String? {
        let key = service.pointerAccelerationKey
        guard key != HIDKeys.mouseAcceleration else { return nil }
        return """
        this device's acceleration type is "\(key)", not "\(HIDKeys.mouseAcceleration)". The \
        filter takes the linear-scaling short-circuit only for mouse acceleration, so mode \
        "linear" will be ignored here.
        """
    }

    // MARK: Scroll

    public static func scrollPlan(_ axis: AxisSettings, on service: some ServiceKeys) -> [PropertyWrite] {
        let accelKey = service.scrollAccelerationKey

        switch axis.mode {
        case .curve:
            guard let spec = axis.curve else { return [] }
            return resolutionWrites(axis, on: service) + [
                PropertyWrite(
                    key: HIDKeys.userScrollAccelCurves,
                    value: .curves([CurveBuilder.curveDictionary(spec)]),
                    note: "checked before the driver's own curves"
                ),
                PropertyWrite(
                    key: HIDKeys.scrollAccelerationAlgorithm,
                    value: .int(HIDKeys.Algorithm.parametric.rawValue),
                    note: "parametric"
                ),
                PropertyWrite(
                    key: accelKey,
                    value: .int(IOFixed.from(axis.acceleration)),
                    note: "last — cached, so this fires the rebuild",
                    triggersRebuild: true
                ),
            ]

        case .linear:
            // Scroll has no linear-scaling short-circuit of its own. The closest equivalent is the
            // default algorithm with no user curves, which is what the system does untouched.
            return resolutionWrites(axis, on: service) + [
                PropertyWrite(
                    key: HIDKeys.userScrollAccelCurves,
                    value: .curves([]),
                    note: "cleared, so the default algorithm applies"
                ),
                PropertyWrite(
                    key: HIDKeys.scrollAccelerationAlgorithm,
                    value: .int(HIDKeys.Algorithm.default.rawValue),
                    note: "system default"
                ),
                PropertyWrite(
                    key: accelKey,
                    value: .int(IOFixed.from(axis.acceleration)),
                    note: "last — cached, so this fires the rebuild",
                    triggersRebuild: true
                ),
            ]

        case .raw:
            return [
                PropertyWrite(
                    key: accelKey,
                    value: .int(IOFixed.from(-1)),
                    note: "negative — no scroll accelerator at all",
                    triggersRebuild: true
                )
            ]
        }
    }

    /// The filter reads `HIDScrollResolutionX/Y/Z` per axis and only falls back to the generic
    /// `HIDScrollResolution`. Writing just the generic key would leave any published axis key in
    /// force, so both are written — but the axis keys only where the service already has them,
    /// since creating one where the device published none would change how the filter reads it.
    static func resolutionWrites(_ axis: AxisSettings, on service: some ServiceKeys) -> [PropertyWrite] {
        let value = PropertyValue.int(IOFixed.from(axis.clampedResolution(for: .scroll)))
        var writes = [
            PropertyWrite(key: HIDKeys.scrollResolution, value: value, note: "fallback for axes with no per-axis key")
        ]
        for key in service.publishedScrollResolutionAxisKeys {
            writes.append(PropertyWrite(key: key, value: value, note: "takes precedence over \(HIDKeys.scrollResolution)"))
        }
        return writes
    }

    // MARK: Stock values

    /// The stock counterpart of a plan: the keys it would touch whose untouched value we can
    /// actually justify, set back to that value.
    ///
    /// This is what `goodmouse restore` writes. It cannot know what an earlier `apply` overwrote —
    /// that history lives only in the `Applicator` that made the writes — so it aims for stock.
    ///
    /// **Only pointer keys have a knowable stock value.** `kDefaultPointerResolutionFixed` (400) and
    /// the stock `HIDPointerAcceleration` (0.6875) are documented constants. The scroll equivalents
    /// are not: scroll resolution and scroll acceleration are published by the driver per device —
    /// this machine's virtual device reports 9 and 0.3125 — and no constant predicts them. Writing
    /// the pointer defaults there instead is far worse than leaving them alone: 400 is a 44× change
    /// to scroll resolution. So scroll keys are deliberately omitted; `unrestorableKeys` names them
    /// so the caller can say what it left behind.
    ///
    /// The acceleration write carries `triggersRebuild` for the same reason every other plan's does:
    /// without it, a restore whose only difference from stock is resolution would be stored, visible
    /// in `ioreg`, and ignored by the filter.
    public static func stockPlan(for plan: [PropertyWrite], on service: some ServiceKeys) -> [PropertyWrite] {
        plan.compactMap { write in
            if let neutral = Applicator.neutralValues[write.key] {
                return PropertyWrite(key: write.key, value: neutral, note: "stock")
            }
            if write.key == service.pointerAccelerationKey {
                return PropertyWrite(
                    key: write.key,
                    value: .int(IOFixed.from(AxisSettings.defaultAcceleration)),
                    note: "stock acceleration — written last, and fires the rebuild",
                    triggersRebuild: true
                )
            }
            if write.key == HIDKeys.pointerResolution {
                return PropertyWrite(
                    key: write.key,
                    value: .int(IOFixed.from(CurveModel.defaultResolution)),
                    note: "stock resolution"
                )
            }
            return nil
        }
    }

    /// Keys a plan writes that `stockPlan` deliberately leaves alone, because their untouched value
    /// is device-published and unknowable from outside. A replug or dext reload restores them.
    public static func unrestorableKeys(in plan: [PropertyWrite], on service: some ServiceKeys) -> [String] {
        let stock = Set(stockPlan(for: plan, on: service).map(\.key))
        return plan.map(\.key).filter { !stock.contains($0) }
    }
}

// MARK: - Applicator

/// Applies a profile to a service, remembers what was there first, and puts it back on request.
public final class Applicator {
    /// Neutral values for keys that had no original. HID service properties cannot be deleted, only
    /// overwritten, so "restore" for a key we introduced means writing the value that reproduces
    /// stock behaviour.
    public static let neutralValues: [String: PropertyValue] = [
        HIDKeys.userPointerAccelCurves: .curves([]),
        HIDKeys.userScrollAccelCurves: .curves([]),
        HIDKeys.pointerAccelerationAlgorithm: .int(HIDKeys.Algorithm.default.rawValue),
        HIDKeys.scrollAccelerationAlgorithm: .int(HIDKeys.Algorithm.default.rawValue),
        HIDKeys.useLinearScalingMouseAcceleration: .int(0),
    ]

    /// What each key held before we first wrote it, per service. An inner `nil` means the key was
    /// absent entirely, which `restore` handles with a neutral rather than by deleting.
    private var originals: [UInt64: [String: PropertyValue?]] = [:]
    private let log = Log.applicator

    public init() {}

    // MARK: Capture

    /// Records the pre-existing value of every key the plan will touch. Only the first capture for
    /// a given service counts, so repeated applies never overwrite the true originals.
    public func captureOriginals(for service: some PropertyStore, plan: [PropertyWrite]) {
        let id = service.registryID
        var captured = originals[id] ?? [:]
        for write in plan where captured[write.key] == nil {
            captured[write.key] = service.copyProperty(write.key)
        }
        originals[id] = captured
    }

    // MARK: Apply

    public struct ApplyResult: Sendable {
        public var written: [PropertyWrite] = []
        public var skipped: [PropertyWrite] = []
        public var failed: [PropertyWrite] = []
        /// Writes the service *accepted* — `setProperty` returned true — but which did not survive
        /// an immediate read-back. See `rejectedWrites` below for why this is worth its own case.
        public var rejected: [PropertyWrite] = []

        public var changedAnything: Bool { !written.isEmpty }
    }

    /// Applies the plan in order, writing what differs — plus the rebuild trigger whenever anything
    /// before it changed.
    ///
    /// Skipping unchanged keys is the loop guard: our own writes come back through the
    /// property-changed callback, so writing everything unconditionally would make `watch` spin
    /// against itself.
    ///
    /// But the guard cannot be applied to the trigger write. `HIDPointerResolution` is not one of
    /// the filter's cached keys, so writing it does nothing on its own — the trailing acceleration
    /// write is what fires the rebuild that reads it. If the acceleration value happens to be
    /// unchanged, skipping it strands the new resolution: stored in the service, visible in `ioreg`,
    /// and completely ignored by the filter. So the trigger is re-written even when its value
    /// matches, whenever an earlier write in its axis actually changed.
    ///
    /// This still converges. The forced write only happens on a pass where something else changed;
    /// the next pass finds everything in place and writes nothing.
    @discardableResult
    public func apply(_ plan: [PropertyWrite], to service: some PropertyStore) -> ApplyResult {
        captureOriginals(for: service, plan: plan)

        var result = ApplyResult()
        var rebuildPending = false

        for write in plan {
            let matches = service.copyProperty(write.key) == write.value

            if write.triggersRebuild {
                guard !matches || rebuildPending else {
                    result.skipped.append(write)
                    continue
                }
                if matches {
                    log.debug("""
                    forcing \(write.key, privacy: .public) to fire a rebuild for earlier writes
                    """)
                }
                rebuildPending = false
            } else if matches {
                result.skipped.append(write)
                continue
            }

            guard service.setProperty(write.key, write.value) else {
                result.failed.append(write)
                log.error("failed to write \(write.key, privacy: .public)")
                continue
            }

            // A successful write is not the same as a write that took. Some keys are republished by
            // the driver and revert immediately — `HIDScrollResolution` on the Karabiner virtual
            // device is one. Reading back is the only way to tell, and this project has lost enough
            // time to silent no-ops to be worth the extra read.
            if service.copyProperty(write.key) != write.value {
                result.rejected.append(write)
                log.error("""
                \(write.key, privacy: .public) accepted the write but did not keep it — \
                the device is republishing its own value
                """)
                continue
            }

            result.written.append(write)
            if !write.triggersRebuild { rebuildPending = true }
            log.debug("""
            wrote \(write.key, privacy: .public) = \
            \(write.value.displayString(forKey: write.key), privacy: .public)
            """)
        }
        return result
    }

    // MARK: Restore

    /// Writes captured originals back, in plan order so the acceleration key still lands last.
    @discardableResult
    public func restore(_ service: some PropertyStore) -> ApplyResult {
        let id = service.registryID
        guard let captured = originals[id] else { return ApplyResult() }

        var result = ApplyResult()
        var rebuildPending = false
        // Restoring in the order the keys were captured keeps the acceleration write last, which
        // is what makes the rebuild pick up the restored resolution and curves.
        for (key, original) in captured.sorted(by: { restoreRank($0.key) < restoreRank($1.key) }) {
            let value: PropertyValue
            if let original {
                value = original
            } else if let neutral = Applicator.neutralValues[key] {
                value = neutral
            } else {
                // No original and no defined neutral: leave it rather than guess.
                continue
            }
            let isTrigger = restoreRank(key) == 1
            let write = PropertyWrite(
                key: key,
                value: value,
                note: original == nil ? "neutral (no original)" : "original",
                triggersRebuild: isTrigger
            )
            let matches = service.copyProperty(key) == value
            // Same hazard as `apply`: originals that differ only in resolution would be stored and
            // then ignored, because nothing cached was written to rebuild the accelerator.
            if matches, !(isTrigger && rebuildPending) {
                result.skipped.append(write)
            } else if service.setProperty(key, value) {
                result.written.append(write)
                if isTrigger { rebuildPending = false } else { rebuildPending = true }
            } else {
                result.failed.append(write)
            }
        }
        originals[id] = nil
        return result
    }

    /// Acceleration keys restore last, for the same reason they are written last.
    private func restoreRank(_ key: String) -> Int {
        let accelKeys = [
            HIDKeys.mouseAcceleration, HIDKeys.pointerAcceleration,
            HIDKeys.mouseScrollAcceleration, HIDKeys.scrollAcceleration,
        ]
        return accelKeys.contains(key) ? 1 : 0
    }
}
