import Testing
@testable import GoodMouseKit

@Suite("DeviceMatcher")
struct DeviceMatcherTests {
    /// The Karabiner virtual device as it actually appears: no transport at all.
    static let virtualDevice = DeviceInfo(
        registryID: 0x100000a8a,
        product: "Karabiner DriverKit VirtualHIDPointing 1.8.0",
        vendorID: 0x16C0,
        productID: 0x27DA,
        primaryUsagePage: 1,
        primaryUsage: 2,
        transport: nil
    )

    static let trackball = DeviceInfo(
        registryID: 0x100000c8b,
        product: "DEFT Pro TrackBall",
        vendorID: 1390, productID: 306,
        primaryUsagePage: 1, primaryUsage: 2,
        transport: "USB"
    )

    @Test("A product glob matches the virtual device across version bumps")
    func productGlob() {
        let match = DeviceMatch(product: "Karabiner DriverKit VirtualHIDPointing*")
        #expect(DeviceMatcher.matches(match, Self.virtualDevice))
        #expect(DeviceMatcher.matches(match, Self.trackball) == false)
    }

    @Test("Criteria are ANDed")
    func criteriaAreAnded() {
        let right = DeviceMatch(product: "DEFT*", vendorID: 1390)
        let wrongVendor = DeviceMatch(product: "DEFT*", vendorID: 9999)
        #expect(DeviceMatcher.matches(right, Self.trackball))
        #expect(DeviceMatcher.matches(wrongVendor, Self.trackball) == false)
    }

    /// This is the whole reason the project exists. A transport criterion can never reach the
    /// virtual device, because it publishes no Transport property to compare against.
    @Test("A transport criterion can never match the virtual device")
    func transportCannotReachTheVirtualDevice() {
        #expect(DeviceMatcher.matches(DeviceMatch(transport: "USB"), Self.virtualDevice) == false)
        #expect(DeviceMatcher.matches(DeviceMatch(transport: "*"), Self.virtualDevice) == false)
        // But usage does reach it.
        #expect(DeviceMatcher.matches(DeviceMatch(usagePage: 1, usage: 2), Self.virtualDevice))
    }

    @Test("An empty matcher matches nothing")
    func emptyMatcherMatchesNothing() {
        #expect(DeviceMatcher.matches(DeviceMatch(), Self.virtualDevice) == false)
        #expect(DeviceMatcher.matches(DeviceMatch(), Self.trackball) == false)
    }

    @Test("A criterion naming an absent property is a non-match, never a pass")
    func absentPropertyIsNotAPass() {
        let noProduct = DeviceInfo(registryID: 1, product: nil, vendorID: 1)
        #expect(DeviceMatcher.matches(DeviceMatch(product: "*"), noProduct) == false)
    }

    @Test("Rules are tried in order and the first match wins")
    func firstRuleWins() {
        let rules = [
            DeviceRule(match: DeviceMatch(product: "Karabiner*"), profile: "specific"),
            DeviceRule(match: DeviceMatch(usagePage: 1, usage: 2), profile: "catchall"),
        ]
        #expect(DeviceMatcher.firstRule(in: rules, for: Self.virtualDevice)?.profile == "specific")
        #expect(DeviceMatcher.firstRule(in: rules, for: Self.trackball)?.profile == "catchall")
    }

    @Test("Globs support ? and are case-sensitive")
    func globSemantics() {
        #expect(DeviceMatcher.glob("DEFT Pro TrackBal?", matches: "DEFT Pro TrackBall"))
        #expect(DeviceMatcher.glob("deft*", matches: "DEFT Pro TrackBall") == false)
        #expect(DeviceMatcher.glob("*TrackBall", matches: "DEFT Pro TrackBall"))
        #expect(DeviceMatcher.glob("DEFT Pro TrackBall", matches: "DEFT Pro TrackBall"))
    }

    /// The Corne keyboard turns up as a GenericDesktop Mouse over BLE even though it is a keyboard,
    /// so a usage-only rule would sweep it in. Product matching is what keeps rules honest.
    @Test("A usage-only rule claims every pointing service, including surprising ones")
    func usageOnlyIsBroad() {
        let corne = DeviceInfo(registryID: 3, product: "Corne", vendorID: 7504, productID: 24926,
                               primaryUsagePage: 1, primaryUsage: 2, transport: "Bluetooth Low Energy")
        let usageOnly = DeviceMatch(usagePage: 1, usage: 2)
        #expect(DeviceMatcher.matches(usageOnly, corne))
        #expect(DeviceMatcher.matches(DeviceMatch(product: "Karabiner*"), corne) == false)
    }

    @Test("displayName falls back to the registry ID when there is no product string")
    func displayNameFallback() {
        let unnamed = DeviceInfo(registryID: 0xabc)
        #expect(unnamed.displayName.contains("abc"))
        #expect(Self.trackball.displayName == "DEFT Pro TrackBall")
    }
}
