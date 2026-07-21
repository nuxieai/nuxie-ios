// swift-tools-version: 6.0
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

let sdkSwiftSettings: [SwiftSetting] = [
    // Phase 10: Swift 6 language mode — strict concurrency violations are
    // compile errors. Plain v6 semantics, no approachable-concurrency
    // upcoming features: the current CI toolchain (Xcode 26.2) rejects
    // actor witnesses for [String: Any] protocols under those features
    // even with @preconcurrency, so the codebase targets the portable
    // baseline that every supported compiler accepts.
    .swiftLanguageMode(.v6),
]

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
            swiftSettings: sdkSwiftSettings,
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
            path: "Tests/NuxieTestSupport",
            swiftSettings: sdkSwiftSettings
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
            ],
            swiftSettings: sdkSwiftSettings
        ),
        .testTarget(
            name: "NuxieIntegrationTests",
            dependencies: [
                "Nuxie",
                "NuxieTestSupport",
                "Quick",
                "Nimble",
            ],
            path: "Tests/NuxieIntegrationTests",
            swiftSettings: sdkSwiftSettings
        ),
        nuxieRuntimeTarget,
    ]
)
