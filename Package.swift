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
    // nuxie-ios owns Apple runtime packaging and release hosting. The runtime
    // carries no version of its own: each SDK release (vX.Y.Z) builds the
    // XCFramework from the crate and engine state at that commit, and the
    // release workflow rewrites this pin to that release's asset and checksum.
    // Until the first SDK release is cut, the immutable legacy
    // apple-runtime-v0.3.0 asset remains the pinned fallback.
    .binaryTarget(
        name: "NuxieRuntime",
        url: "https://github.com/nuxieai/nuxie-ios/releases/download/apple-runtime-v0.3.0/NuxieRuntime.xcframework.zip",
        checksum: "8bfb82c5da220cf7c2184f14e19941b962924a010493452a0cea1d58cb8fee54"
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
    ],
    targets: [
        .target(
            name: "Nuxie",
            dependencies: [
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
            ],
            path: "Tests/NuxieIntegrationTests"
        ),
        nuxieRuntimeTarget,
    ]
)
