// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PocketQueueCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "PocketQueueCore", targets: ["PocketQueueCore"])],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", exact: "2.55.6"),
        // Keep Auth's transitive graph compatible with CI's Swift 6.1 toolchain.
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.7.4"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
        .package(url: "https://github.com/apple/swift-http-types.git", exact: "1.8.0"),
        .package(url: "https://github.com/pointfreeco/swift-clocks", exact: "1.0.6"),
        .package(url: "https://github.com/pointfreeco/swift-concurrency-extras", exact: "1.3.2"),
        .package(url: "https://github.com/pointfreeco/xctest-dynamic-overlay", exact: "1.8.1"),
    ],
    targets: [
        .target(
            name: "PocketQueueCore",
            dependencies: [.product(name: "Auth", package: "supabase-swift")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "PocketQueueCoreTests", dependencies: ["PocketQueueCore"]),
    ]
)
