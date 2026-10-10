// swift-tools-version: 5.9
import PackageDescription

// Only dependency metadata lives here. The SDK and its tests compile through
// swift_library and rules_apple, while Package.resolved remains authoritative.
let package = Package(
    name: "NuxieBazelDependencies",
    dependencies: [
        .package(url: "https://github.com/Quick/Quick.git", exact: "7.6.2"),
        .package(url: "https://github.com/Quick/Nimble.git", exact: "13.7.1"),
    ]
)
