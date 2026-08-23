import Foundation
import GoodMouseC
import IOKit

/// A value that can live in a HID service property.
public enum PropertyValue: Equatable, Sendable {
    case int(Int)
    case string(String)
    /// A `UserPointerAccelCurvesKey` / `UserScrollAccelCurvesKey` array. All values IOFixed.
    case curves([[String: Int]])

    var cfValue: CFTypeRef {
        switch self {
        case .int(let v): return v as CFNumber
        case .string(let v): return v as CFString
        case .curves(let v): return v as CFArray
        }
    }

    static func from(_ value: CFTypeRef?) -> PropertyValue? {
        guard let value else { return nil }
        if let n = value as? NSNumber { return .int(n.intValue) }
        if let s = value as? String { return .string(s) }
        if let a = value as? [[String: Int]] { return .curves(a) }
        return nil
    }

    /// How the value reads in `apply --dry-run` and `status`, given the key it belongs to.
    ///
    /// The key is required because it decides the rendering: almost every number in this API is
    /// 16.16 fixed point, but the algorithm and flag keys are plain integers, and printing `2` as
    /// `3.05e-05` makes the algorithm field unreadable.
    public func displayString(forKey key: String) -> String {
        switch self {
        case .int(let v):
            if key == HIDKeys.pointerAccelerationAlgorithm || key == HIDKeys.scrollAccelerationAlgorithm {
                let label = HIDKeys.Algorithm(rawValue: v)?.label ?? "unknown — builds no accelerator"
                return "\(v) (\(label))"
            }
            guard HIDKeys.isFixedPoint(key) else { return "\(v)" }
            return "\(v) (= \(Format.number(IOFixed.toDouble(v))))"

        case .string(let v):
            return "\"\(v)\""

        case .curves(let curves):
            if curves.isEmpty { return "[] (empty — no user curve)" }
            return curves
                .map { dict in
                    let c = CurveBuilder.curve(from: dict)
                    return "{index \(Format.number(c.index)), "
                        + "gains \(Format.number(c.gainLinear))/\(Format.number(c.gainParabolic))/"
                        + "\(Format.number(c.gainCubic))/\(Format.number(c.gainQuartic)), "
                        + "knee \(Format.number(c.tangentSpeedLinear)), "
                        + "taper \(Format.number(c.tangentSpeedParabolicRoot))}"
                }
                .joined(separator: ", ")
        }
    }
}

/// One HID service, wrapped for typed property access.
///
/// The event-system client that vended the service is held here on purpose. If it is released, the
/// service object survives but is inert: every read returns nil and every write silently fails.
public final class HIDService {
    let service: IOHIDServiceClient
    private let owner: IOHIDEventSystemClient

    init(service: IOHIDServiceClient, owner: IOHIDEventSystemClient) {
        self.service = service
        self.owner = owner
    }

    // MARK: Raw access

    public func copyProperty(_ key: String) -> PropertyValue? {
        PropertyValue.from(IOHIDServiceClientCopyProperty(service, key as CFString))
    }

    @discardableResult
    public func setProperty(_ key: String, _ value: PropertyValue) -> Bool {
        IOHIDServiceClientSetProperty(service, key as CFString, value.cfValue)
    }

    public func int(_ key: String) -> Int? {
        if case .int(let v)? = copyProperty(key) { return v }
        return nil
    }

    public func string(_ key: String) -> String? {
        if case .string(let v)? = copyProperty(key) { return v }
        return nil
    }

    public func fixed(_ key: String) -> Double? {
        int(key).map(IOFixed.toDouble)
    }

    public func hasProperty(_ key: String) -> Bool {
        IOHIDServiceClientCopyProperty(service, key as CFString) != nil
    }

    // MARK: Identity

    public var registryID: UInt64 {
        (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value ?? 0
    }

    public var info: DeviceInfo {
        DeviceInfo(
            registryID: registryID,
            product: string(HIDKeys.product),
            vendorID: int(HIDKeys.vendorID),
            productID: int(HIDKeys.productID),
            primaryUsagePage: int(HIDKeys.primaryUsagePage),
            primaryUsage: int(HIDKeys.primaryUsage),
            transport: string(HIDKeys.transport)
        )
    }

    public func conformsTo(usagePage: UInt32, usage: UInt32) -> Bool {
        IOHIDServiceClientConformsTo(service, usagePage, usage) != 0
    }

    /// GenericDesktop Mouse or Pointer — what "a pointing device" means here.
    public var isPointing: Bool {
        conformsTo(usagePage: 0x01, usage: 0x02) || conformsTo(usagePage: 0x01, usage: 0x01)
    }

    // MARK: Acceleration key resolution

    /// The key that actually carries the pointer acceleration value for this service.
    ///
    /// This mirrors `IOHIDPointerScrollFilter::setupPointerAcceleration`: the value of
    /// `HIDPointerAccelerationType` names the key; failing that the filter reads
    /// `HIDMouseAcceleration`, and only then `HIDPointerAcceleration`. Writing to any other key
    /// has no effect, so the device's own type key is authoritative.
    public var pointerAccelerationKey: String {
        if let type = string(HIDKeys.pointerAccelerationType), !type.isEmpty { return type }
        if hasProperty(HIDKeys.mouseAcceleration) { return HIDKeys.mouseAcceleration }
        return HIDKeys.pointerAcceleration
    }

    /// The scroll counterpart, resolved the same way by
    /// `IOHIDPointerScrollFilter::setupScrollAcceleration`.
    public var scrollAccelerationKey: String {
        if let type = string(HIDKeys.scrollAccelerationType), !type.isEmpty { return type }
        if hasProperty(HIDKeys.mouseScrollAcceleration) { return HIDKeys.mouseScrollAcceleration }
        return HIDKeys.scrollAcceleration
    }

    /// The per-axis scroll resolution keys this service actually publishes.
    ///
    /// The filter reads `HIDScrollResolutionX/Y/Z` first and only falls back to
    /// `HIDScrollResolution` per axis, so writing the generic key alone leaves any published axis
    /// key in force.
    public var publishedScrollResolutionAxisKeys: [String] {
        HIDKeys.scrollResolutionAxisKeys.filter(hasProperty)
    }
}
