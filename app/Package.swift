// swift-tools-version:5.10
// Cleaner for macOS: a SwiftUI front-end over the Rust `cleaner-engine` back-end.
// Build the full .app with `make app` from the repository root.
import PackageDescription

let package = Package(
    name: "Cleaner",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Cleaner",
            path: "Sources/Cleaner"
        ),
        .testTarget(
            name: "CleanerTests",
            dependencies: ["Cleaner"],
            path: "Tests/CleanerTests"
        ),
    ]
)
