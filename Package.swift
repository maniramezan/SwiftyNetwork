// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftyNetwork",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(
            name: "SwiftyNetwork",
            targets: ["SwiftyNetwork"])
    ],
    dependencies: [
        // No traits: SwiftyNetwork only uses the concurrency, logging, and error
        // helpers, so it opts out of SwiftCommons' SwiftData-backed APIs.
        .package(url: "https://github.com/maniramezan/SwiftCommons.git", from: "0.11.0", traits: [])
    ],
    targets: [
        .target(
            name: "SwiftyNetwork",
            dependencies: [
                .product(name: "SwiftCommons", package: "SwiftCommons")
            ],
            resources: [.process("SwiftyNetwork.docc")]
        ),
        .testTarget(
            name: "SwiftyNetworkTests",
            dependencies: ["SwiftyNetwork"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
