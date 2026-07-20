// swift-tools-version: 5.9
import Foundation
import PackageDescription

let localRuntimePath = ".artifacts/NuxieRuntime.xcframework"
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let localRuntimeURL = packageRoot.appendingPathComponent(localRuntimePath)
let nuxieRuntimeTarget: Target = if FileManager.default.fileExists(atPath: localRuntimeURL.path) {
    .binaryTarget(
        name: "NuxieRuntime",
        path: localRuntimePath
    )
} else {
    .binaryTarget(
        name: "NuxieRuntime",
        url: "https://github.com/nuxieai/nuxie-runtime/releases/download/apple-runtime-v0.1.0/NuxieRuntime.xcframework.zip",
        checksum: "5ada29f067a278c80b199cf6b95587103a6e12d62a2fb002283fd107d784c0d8"
    )
}

let package = Package(
    name: "Nuxie",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "Nuxie",
            targets: ["Nuxie"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/Quick/Quick.git", from: "7.0.0"),
        .package(url: "https://github.com/Quick/Nimble.git", from: "13.0.0"),
        .package(url: "https://github.com/hmlongco/Factory.git", from: "2.5.0"),
    ],
    targets: [
        .target(
            name: "Nuxie",
            dependencies: [
                .product(name: "FactoryKit", package: "Factory"),
                .target(
                    name: "NuxieRuntime",
                    condition: .when(platforms: [.iOS])
                )
            ],
            path: "Sources/Nuxie",
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ],
            swiftSettings: [
                // Phase 1 guardrail: surface data races as warnings now;
                // Phase 10 flips to Swift 6 language mode (errors).
                .enableExperimentalFeature("StrictConcurrency")
            ],
            linkerSettings: [
                .linkedFramework("Foundation", .when(platforms: [.iOS])),
                .linkedFramework("QuartzCore", .when(platforms: [.iOS])),
                .linkedFramework("Metal", .when(platforms: [.iOS])),
                .linkedFramework("CoreGraphics", .when(platforms: [.iOS])),
                .linkedFramework("Security", .when(platforms: [.iOS])),
            ]
        ),
        .target(
            name: "NuxieTestSupport",
            dependencies: [
                "Nuxie",
                "Quick",
                "Nimble",
                .product(name: "FactoryKit", package: "Factory"),
            ],
            path: "Tests/NuxieTestSupport"
        ),
        .testTarget(
            name: "NuxieUnitTests",
            dependencies: [
                "Nuxie",
                "NuxieTestSupport",
                "Quick",
                "Nimble",
                .product(name: "FactoryKit", package: "Factory"),
                .target(
                    name: "NuxieRuntime",
                    condition: .when(platforms: [.iOS])
                ),
            ],
            path: "Tests/NuxieUnitTests",
            resources: [
                .process("Fixtures")
            ]
        ),
        .testTarget(
            name: "NuxieIntegrationTests",
            dependencies: [
                "Nuxie",
                "NuxieTestSupport",
                "Quick",
                "Nimble",
                .product(name: "FactoryKit", package: "Factory"),
            ],
            path: "Tests/NuxieIntegrationTests"
        ),
        nuxieRuntimeTarget,
    ]
)
