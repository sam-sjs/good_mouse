import Foundation

/// A snapshot of the identifying properties of one HID service.
///
/// Deliberately a plain value type with no IOKit in it, so matching is testable without hardware.
public struct DeviceInfo: Equatable, Sendable {
    public var registryID: UInt64
    public var product: String?
    public var vendorID: Int?
    public var productID: Int?
    public var primaryUsagePage: Int?
    public var primaryUsage: Int?
    /// Absent on the Karabiner virtual device — the whole reason transport-keyed tools cannot
    /// address it.
    public var transport: String?

    public init(
        registryID: UInt64,
        product: String? = nil,
        vendorID: Int? = nil,
        productID: Int? = nil,
        primaryUsagePage: Int? = nil,
        primaryUsage: Int? = nil,
        transport: String? = nil
    ) {
        self.registryID = registryID
        self.product = product
        self.vendorID = vendorID
        self.productID = productID
        self.primaryUsagePage = primaryUsagePage
        self.primaryUsage = primaryUsage
        self.transport = transport
    }

    /// How the device is labelled in `goodmouse devices`.
    public var displayName: String {
        product ?? String(format: "(unnamed service 0x%llx)", registryID)
    }
}

public enum DeviceMatcher {
    /// True when every criterion the matcher states is satisfied.
    ///
    /// A criterion naming a property the device does not publish is a non-match, never a pass.
    public static func matches(_ match: DeviceMatch, _ device: DeviceInfo) -> Bool {
        if match.isEmpty { return false }

        if let pattern = match.product {
            guard let product = device.product, glob(pattern, matches: product) else { return false }
        }
        if let pattern = match.transport {
            guard let transport = device.transport, glob(pattern, matches: transport) else { return false }
        }
        if let vendorID = match.vendorID, device.vendorID != vendorID { return false }
        if let productID = match.productID, device.productID != productID { return false }
        if let usagePage = match.usagePage, device.primaryUsagePage != usagePage { return false }
        if let usage = match.usage, device.primaryUsage != usage { return false }
        return true
    }

    /// The first rule whose matcher accepts the device. Order in the config is precedence.
    public static func firstRule(in rules: [DeviceRule], for device: DeviceInfo) -> DeviceRule? {
        rules.first { matches($0.match, device) }
    }

    /// Shell-style glob: `*` for any run of characters, `?` for exactly one. Case-sensitive.
    static func glob(_ pattern: String, matches subject: String) -> Bool {
        pattern.withCString { p in
            subject.withCString { s in
                fnmatch(p, s, 0) == 0
            }
        }
    }
}
