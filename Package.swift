// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftyNetwork",
    platforms: [.macOS(.v15), .iOS(.v15)],
    products: [
        .library(
            name: "SwiftyNetwork",
            targets: ["SwiftyNetwork"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-format.git", from: "602.0.0")
    ],
    targets: [
        .target(
            name: "SwiftyNetwork"
        ),
        .testTarget(
            name: "SwiftyNetworkTests",
            dependencies: ["SwiftyNetwork"]
        ),
    ],
    swiftLanguageModes: [.v6],
)
