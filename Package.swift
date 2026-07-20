// swift-tools-version: 5.9
import PackageDescription

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
        .package(url: "https://github.com/nuxieai/rive-ios.git", revision: "aa9be09f3cd995fcf826573e1ded605e545b5c44"),
    ],
    targets: [
        .target(
            name: "Nuxie",
            dependencies: [
                .product(name: "FactoryKit", package: "Factory"),
                .product(
                    name: "RiveRuntime",
                    package: "rive-ios",
                    condition: .when(platforms: [.iOS])
                )
            ],
            path: "Sources/Nuxie",
            swiftSettings: [
                // Phase 1 guardrail: surface data races as warnings now;
                // Phase 10 flips to Swift 6 language mode (errors).
                .enableExperimentalFeature("StrictConcurrency")
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
                .product(
                    name: "RiveRuntime",
                    package: "rive-ios",
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
    ]
)
