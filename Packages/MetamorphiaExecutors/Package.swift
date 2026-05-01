// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MetamorphiaExecutors",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MetamorphiaExecutors",
            targets: ["MetamorphiaExecutors"]
        ),
    ],
    dependencies: [
        .package(path: "../MetamorphiaToolProtocol"),
        .package(path: "../MetamorphiaAgentKit"),
        .package(path: "../Computer"),
    ],
    targets: [
        .target(
            name: "MetamorphiaExecutors",
            dependencies: [
                .product(name: "MetamorphiaToolProtocol", package: "MetamorphiaToolProtocol"),
                .product(name: "MetamorphiaAgentKit", package: "MetamorphiaAgentKit"),
                .product(name: "MetamorphiaPerception", package: "Computer"),
            ],
            path: "Sources/MetamorphiaExecutors",
            resources: [
                .copy("Resources/Skills"),
            ]
        ),
        .testTarget(
            name: "MetamorphiaExecutorsTests",
            dependencies: [
                "MetamorphiaExecutors",
                .product(name: "MetamorphiaToolProtocol", package: "MetamorphiaToolProtocol"),
                .product(name: "MetamorphiaAgentKit", package: "MetamorphiaAgentKit"),
                .product(name: "MetamorphiaPerception", package: "Computer"),
            ],
            path: "Tests/MetamorphiaExecutorsTests"
        ),
    ]
)
