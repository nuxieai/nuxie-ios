// swift-tools-version: 5.9
import Foundation
import PackageDescription

let localRuntimePath = ".artifacts/NuxieRuntime.xcframework"
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let localRuntimeURL = packageRoot.appendingPathComponent(localRuntimePath)
let releasedRuntimeBaseURL = "https://github.com/nuxieai/nuxie-runtime/releases/download"
let releasedRuntimeURL = releasedRuntimeBaseURL + "/apple-runtime-v0.3.1/NuxieRuntime.xcframework.zip"
let releasedRuntimeChecksum = "081c96aa7cbb64048f1bbf32b9bd0d7db858e2d125de701f433fcde7cc6527fa"

func makeNuxieRuntimeFFITarget() -> Target {
    let forceReleasedRuntime = ProcessInfo.processInfo.environment["NUXIE_RUNTIME_USE_RELEASE"] == "1"
    if !forceReleasedRuntime && FileManager.default.fileExists(atPath: localRuntimeURL.path) {
        return .binaryTarget(
            name: "NuxieRuntimeFFI",
            path: localRuntimePath
        )
    }

    return .binaryTarget(
        name: "NuxieRuntimeFFI",
        url: releasedRuntimeURL,
        checksum: releasedRuntimeChecksum
    )
}

let nuxieRuntimeFFITarget = makeNuxieRuntimeFFITarget()

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
                    name: "NuxieRuntimeFFI",
                    condition: .when(platforms: [.iOS])
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
                "NuxieRuntime"
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
                "NuxieRuntime",
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
        nuxieRuntimeFFITarget,
    ]
)
