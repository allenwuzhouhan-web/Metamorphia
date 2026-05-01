// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MetamorphiaAgentKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MetamorphiaAgentKit",
            targets: ["MetamorphiaAgentKit"]
        ),
    ],
    dependencies: [
        .package(path: "../MetamorphiaToolProtocol"),
    ],
    targets: [
        .target(
            name: "MetamorphiaAgentKit",
            dependencies: [
                .product(name: "MetamorphiaToolProtocol", package: "MetamorphiaToolProtocol"),
            ],
            path: "Sources/MetamorphiaAgentKit"
        ),
        .testTarget(
            name: "MetamorphiaAgentKitTests",
            dependencies: ["MetamorphiaAgentKit"],
            path: "Tests/MetamorphiaAgentKitTests"
        ),
    ]
)
