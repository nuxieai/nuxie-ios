// swift-tools-version: 5.9
import Foundation
import PackageDescription

let localRuntimePath = ".artifacts/NuxieRuntime.xcframework"
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let localRuntimeURL = packageRoot.appendingPathComponent(localRuntimePath)
let releasedRuntimeBaseURL = "https://github.com/nuxieai/nuxie-runtime/releases/download"
let releasedRuntimeURL = releasedRuntimeBaseURL + "/apple-runtime-v1.2.0/NuxieRuntime.xcframework.zip"
let releasedRuntimeChecksum = "d2e87522c1954ddcd456cf0f8b112b0ed49b56998322a169692b42a051d66e81"
let unstagedRuntimeMessage = "No NuxieRuntime xcframework is staged at .artifacts/NuxieRuntime.xcframework. Stage one with `make stage-runtime-xcframework NUXIE_RUNTIME_XCFRAMEWORK=<path to a built NuxieRuntime.xcframework>`. NUXIE_RUNTIME_USE_LOCAL=0 selects the pinned release runtime instead."

func makeNuxieRuntimeBinaryTarget() -> Target {
    // Unset: a staged runtime wins when one exists (development); otherwise the
    // pinned release (SwiftPM customers never stage one). 1 requires the stage;
    // 0 always selects the pinned release.
    let localRuntimeSelection = ProcessInfo.processInfo.environment["NUXIE_RUNTIME_USE_LOCAL"]
    let runtimeIsStaged = FileManager.default.fileExists(atPath: localRuntimeURL.path)
    switch localRuntimeSelection {
    case "1":
        guard runtimeIsStaged else {
            fatalError(unstagedRuntimeMessage)
        }
        return .binaryTarget(name: "NuxieRuntimeBinary", path: localRuntimePath)
    case nil where runtimeIsStaged:
        return .binaryTarget(name: "NuxieRuntimeBinary", path: localRuntimePath)
    case nil, "0":
        break
    default:
        fatalError("NUXIE_RUNTIME_USE_LOCAL must be unset, 1 or 0")
    }

    return .binaryTarget(
        name: "NuxieRuntimeBinary",
        url: releasedRuntimeURL,
        checksum: releasedRuntimeChecksum
    )
}

let nuxieRuntimeBinaryTarget = makeNuxieRuntimeBinaryTarget()

// The Nux machine's library is for tests only: it carries the .nux compiler
// and a fixed stand-in world. Its module exists only while the library is
// staged, is not a product, and nothing in Nuxie depends on it.
let localMachinePath = ".artifacts/NuxMachine.xcframework"
let machineTargets: [Target] = FileManager.default.fileExists(
    atPath: packageRoot.appendingPathComponent(localMachinePath).path
) ? [
    .binaryTarget(name: "NuxMachineBinary", path: localMachinePath),
    .target(
        name: "NuxieMachine",
        dependencies: [
            "NuxieRuntime",
            .target(name: "NuxMachineBinary", condition: .when(platforms: [.iOS])),
        ],
        path: "Sources/NuxieMachine",
        exclude: ["BUILD.bazel"],
        swiftSettings: [
            .enableExperimentalFeature("StrictConcurrency")
        ]
    ),
] : []

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
                "NuxieRuntime",
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
    ] + machineTargets
)
