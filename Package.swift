// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftyNetwork",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(
            name: "SwiftyNetwork",
            targets: ["SwiftyNetwork"]),
        // Test doubles for apps that depend on SwiftyNetwork. Link it only from test targets and previews.
        .library(
            name: "SwiftyNetworkTesting",
            targets: ["SwiftyNetworkTesting"]),
    ],
    targets: [
        .target(
            name: "SwiftyNetwork",
            resources: [.process("SwiftyNetwork.docc")]
        ),
        .target(
            name: "SwiftyNetworkTesting",
            dependencies: ["SwiftyNetwork"]
        ),
        .testTarget(
            name: "SwiftyNetworkTests",
            dependencies: ["SwiftyNetwork", "SwiftyNetworkTesting"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
