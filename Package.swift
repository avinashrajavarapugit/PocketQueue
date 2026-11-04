// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PocketQueueCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "PocketQueueCore", targets: ["PocketQueueCore"])],
    targets: [
        .target(name: "PocketQueueCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "PocketQueueCoreTests", dependencies: ["PocketQueueCore"]),
    ]
)
