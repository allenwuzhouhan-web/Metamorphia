// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MetamorphiaRemoteKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "MetamorphiaRemoteKit",
            targets: ["MetamorphiaRemoteKit"]
        ),
    ],
    targets: [
        .target(
            name: "MetamorphiaRemoteKit",
            path: "Sources/MetamorphiaRemoteKit"
        ),
        .testTarget(
            name: "MetamorphiaRemoteKitTests",
            dependencies: ["MetamorphiaRemoteKit"],
            path: "Tests/MetamorphiaRemoteKitTests"
        ),
    ]
)
