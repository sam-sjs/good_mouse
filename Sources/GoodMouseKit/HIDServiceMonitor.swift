import Foundation
import GoodMouseC
import IOKit

/// Owns the HID event-system client and vends the pointing services it can see.
///
/// One-shot commands can just use `pointingServices()`. `watch` additionally starts the callbacks
/// that keep settings asserted across replug, dext reload, sleep/wake and Karabiner restarts.
public final class HIDServiceMonitor {
    /// `IOHIDEventSystemClientCreate` is the client type that can both read `HIDPointerResolution`
    /// and write it. The public `…CreateSimpleClient` sees the same services but reads nil for
    /// resolution, and the Admin type returns no services at all to an unprivileged process.
    private let client: IOHIDEventSystemClient
    private let queue = DispatchQueue(label: "dev.samiam.goodmouse.hid")

    /// Called with each pointing service as it appears — including those already present when the
    /// callbacks start, so this doubles as enumeration.
    private var onAppear: ((HIDService) -> Void)?
    private var onPropertyChange: (() -> Void)?

    /// Retains the wrappers for services we are tracking, keyed by registry ID.
    private var tracked: [UInt64: HIDService] = [:]
    private var scheduled = false

    public init?() {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return nil }
        self.client = client
    }

    deinit {
        if scheduled {
            IOHIDEventSystemClientUnregisterDeviceMatchingBlock(client)
            IOHIDEventSystemClientUnscheduleFromDispatchQueue(client, queue)
        }
    }

    // MARK: One-shot enumeration

    /// Every GenericDesktop Mouse or Pointer service currently known to the event system.
    public func pointingServices() -> [HIDService] {
        guard let raw = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else {
            return []
        }
        return raw
            .map { HIDService(service: $0, owner: client) }
            .filter(\.isPointing)
    }

    // MARK: Watching

    /// Restrict the client to pointing devices, then start delivering appearances on `queue`.
    ///
    /// `onAppear` fires for devices already present as well as new arrivals.
    public func start(
        onAppear: @escaping (HIDService) -> Void,
        onRemove: @escaping (UInt64) -> Void,
        onPropertyChange: @escaping () -> Void
    ) {
        self.onAppear = onAppear
        self.onPropertyChange = onPropertyChange

        let matching: [CFDictionary] = [
            [HIDKeys.deviceUsagePage: 0x01, HIDKeys.deviceUsage: 0x02] as CFDictionary,
            [HIDKeys.deviceUsagePage: 0x01, HIDKeys.deviceUsage: 0x01] as CFDictionary,
        ]
        IOHIDEventSystemClientSetMatchingMultiple(client, matching as CFArray)

        IOHIDEventSystemClientRegisterDeviceMatchingBlock(client, { [weak self] _, _, service in
            guard let self, let service else { return }
            let wrapped = HIDService(service: service, owner: self.client)
            let id = wrapped.registryID
            self.tracked[id] = wrapped

            IOHIDServiceClientRegisterRemovalBlock(service, { _, _, _ in
                self.tracked[id] = nil
                onRemove(id)
            }, nil, nil)

            self.onAppear?(wrapped)
        }, nil, nil)

        // Reasserting on a property change is what makes the config, rather than the System
        // Settings slider, the source of truth. The callback also fires for our own writes, so
        // every caller must compare live against desired before writing or this spins.
        for key in [
            HIDKeys.mouseAcceleration,
            HIDKeys.pointerAcceleration,
            HIDKeys.mouseScrollAcceleration,
            HIDKeys.scrollAcceleration,
        ] {
            IOHIDEventSystemClientRegisterPropertyChangedCallback(
                client,
                key as CFString,
                { target, _, _, _ in
                    guard let target else { return }
                    Unmanaged<HIDServiceMonitor>.fromOpaque(target).takeUnretainedValue().onPropertyChange?()
                },
                Unmanaged.passUnretained(self).toOpaque(),
                nil
            )
        }

        IOHIDEventSystemClientScheduleWithDispatchQueue(client, queue)
        IOHIDEventSystemClientActivate(client)
        scheduled = true
    }

    /// The serial queue every callback is delivered on. Callers should confine their state to it.
    public var callbackQueue: DispatchQueue { queue }
}
