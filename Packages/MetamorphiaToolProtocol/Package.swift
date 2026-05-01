// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MetamorphiaToolProtocol",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "MetamorphiaToolProtocol",
            targets: ["MetamorphiaToolProtocol"]
        ),
    ],
    targets: [
        .target(
            name: "MetamorphiaToolProtocol",
            path: "Sources/MetamorphiaToolProtocol"
        ),
        .testTarget(
            name: "MetamorphiaToolProtocolTests",
            dependencies: ["MetamorphiaToolProtocol"],
            path: "Tests/MetamorphiaToolProtocolTests"
        ),
    ]
)
