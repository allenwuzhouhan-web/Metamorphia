// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Computer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MetamorphiaPerception", targets: ["MetamorphiaPerception"]),
    ],
    targets: [
        .target(
            name: "MetamorphiaPerception",
            path: "Sources/MetamorphiaPerception",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Vision"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "MetamorphiaPerceptionTests",
            dependencies: ["MetamorphiaPerception"],
            path: "Tests/MetamorphiaPerceptionTests"
        ),
    ]
)
