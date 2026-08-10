// swift-tools-version: 5.9
import Foundation
import PackageDescription

let localRuntimePath = ".artifacts/NuxieRuntime.xcframework"
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let localRuntimeURL = packageRoot.appendingPathComponent(localRuntimePath)
let releasedRuntimeBaseURL = "https://github.com/nuxieai/nuxie-runtime/releases/download"
let releasedRuntimeURL = releasedRuntimeBaseURL + "/apple-runtime-v0.5.0/NuxieRuntime.xcframework.zip"
let releasedRuntimeChecksum = "58def1d5e37322c3290e550c65d3535e3bc4b3c5dc03445037b0ac32f97b46cb"

func makeNuxieRuntimeBinaryTarget() -> Target {
    let localRuntimeSelection = ProcessInfo.processInfo.environment["NUXIE_RUNTIME_USE_LOCAL"]
    if localRuntimeSelection == "1" {
        guard FileManager.default.fileExists(atPath: localRuntimeURL.path) else {
            fatalError("NUXIE_RUNTIME_USE_LOCAL=1 requires \(localRuntimePath)")
        }
        return .binaryTarget(
            name: "NuxieRuntimeBinary",
            path: localRuntimePath
        )
    }
    guard localRuntimeSelection == nil else {
        fatalError("NUXIE_RUNTIME_USE_LOCAL must be unset or 1")
    }

    return .binaryTarget(
        name: "NuxieRuntimeBinary",
        url: releasedRuntimeURL,
        checksum: releasedRuntimeChecksum
    )
}

let nuxieRuntimeBinaryTarget = makeNuxieRuntimeBinaryTarget()

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
            name: "NuxieRuntime",
            dependencies: [
                .target(
                    name: "NuxieRuntimeBinary",
                    condition: .when(platforms: [.iOS, .macOS])
                )
            ],
            path: "Sources/NuxieRuntime",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "Nuxie",
            dependencies: [
                "NuxieRuntime",
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
                "NuxieRuntime",
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
                "NuxieRuntime",
                "NuxieTestSupport",
                "Quick",
                "Nimble",
            ],
            path: "Tests/NuxieIntegrationTests"
        ),
        nuxieRuntimeBinaryTarget,
    ]
)
