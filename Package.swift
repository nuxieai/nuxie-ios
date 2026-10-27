// swift-tools-version: 5.9
import Foundation
import PackageDescription

let localRuntimePath = ".artifacts/NuxieRuntime.xcframework"
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let localRuntimeURL = packageRoot.appendingPathComponent(localRuntimePath)
let releasedRuntimeBaseURL = "https://github.com/nuxieai/nuxie-runtime/releases/download"
let releasedRuntimeURL = releasedRuntimeBaseURL + "/apple-runtime-v1.1.0/NuxieRuntime.xcframework.zip"
let releasedRuntimeChecksum = "56adb13e3e66ff3ab5a1fa60a2a874ee59033c3d02e80997c00219265ef59d93"
let unstagedRuntimeMessage = "No NuxieRuntime xcframework is staged at .artifacts/NuxieRuntime.xcframework. Stage one with `make stage-runtime-xcframework NUXIE_RUNTIME_XCFRAMEWORK=<path to a built NuxieRuntime.xcframework>`. NUXIE_RUNTIME_USE_LOCAL=0 selects the pinned release runtime instead."

func makeNuxieRuntimeBinaryTarget() -> Target {
    let localRuntimeSelection = ProcessInfo.processInfo.environment["NUXIE_RUNTIME_USE_LOCAL"]
    if localRuntimeSelection == nil || localRuntimeSelection == "1" {
        guard FileManager.default.fileExists(atPath: localRuntimeURL.path) else {
            fatalError(unstagedRuntimeMessage)
        }
        return .binaryTarget(
            name: "NuxieRuntimeBinary",
            path: localRuntimePath
        )
    }
    guard localRuntimeSelection == "0" else {
        fatalError("NUXIE_RUNTIME_USE_LOCAL must be unset, 1 or 0")
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
    defaultLocalization: "en",
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
                .process("PrivacyInfo.xcprivacy"),
                .process("Resources/timezone-bundle.json"),
                .process("Resources/presentation-schema.json"),
                .process("Resources/LICENSE-unicode.txt")
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
                .linkedFramework("CoreVideo", .when(platforms: [.iOS])),
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
            name: "NuxieRuntimeExecutorTests",
            dependencies: ["NuxieRuntime"],
            path: "Tests/NuxieRuntimeExecutorTests"
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
