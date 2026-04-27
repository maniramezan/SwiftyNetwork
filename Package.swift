// swift-tools-version: 6.0
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
    targets: [
        .target(
            name: "SwiftyNetwork",
            resources: [.process("SwiftyNetwork.docc")]
        ),
        .testTarget(
            name: "SwiftyNetworkTests",
            dependencies: ["SwiftyNetwork"]
        ),
    ],
    swiftLanguageModes: [.v6],
)
