// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "good_mouse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "goodmouse", targets: ["goodmouse"]),
        .library(name: "GoodMouseKit", targets: ["GoodMouseKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // The Command Line Tools toolchain ships no bundled Testing module, so it comes from here.
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.12.0"),
    ],
    targets: [
        .target(name: "GoodMouseC"),
        .target(name: "GoodMouseKit", dependencies: ["GoodMouseC"]),
        .executableTarget(
            name: "goodmouse",
            dependencies: [
                "GoodMouseKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "GoodMouseKitTests",
            dependencies: [
                "GoodMouseKit",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
