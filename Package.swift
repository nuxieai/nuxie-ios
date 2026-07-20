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
        checksum: "02f1083cfe7490c5d2d06f2fbd5aeb7e589ece42ce33ccc99ecd84166447f717"
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
        .library(
            name: "NuxieRevenueCat",
            targets: ["NuxieRevenueCat"]
        ),
        .library(
            name: "NuxieSuperwall",
            targets: ["NuxieSuperwall"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/Quick/Quick.git", from: "7.0.0"),
        .package(url: "https://github.com/Quick/Nimble.git", from: "13.0.0"),
        .package(url: "https://github.com/hmlongco/Factory.git", from: "2.5.0"),
        .package(url: "https://github.com/RevenueCat/purchases-ios.git", branch: "main"),
        .package(url: "https://github.com/superwall/Superwall-iOS.git", branch: "develop"),
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
        .target(
            name: "NuxieRevenueCat",
            dependencies: [
                "Nuxie",
                .product(name: "RevenueCat", package: "purchases-ios")
            ],
            path: "Sources/NuxieRevenueCat"
        ),
        .target(
            name: "NuxieSuperwall",
            dependencies: [
                "Nuxie",
                .product(
                    name: "SuperwallKit",
                    package: "Superwall-iOS",
                    condition: .when(platforms: [.iOS])
                )
            ],
            path: "Sources/NuxieSuperwall"
        ),
        nuxieRuntimeTarget,
    ]
)
