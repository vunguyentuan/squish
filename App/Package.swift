// swift-tools-version: 6.2
import PackageDescription

// The Rust engine is built by `make core` into ../core/target/release/libsquish_core.a.
let coreLibDir = Context.packageDirectory + "/../core/target/release"

let package = Package(
    name: "Squish",
    platforms: [.macOS(.v26)],
    targets: [
        .systemLibrary(name: "CSquishCore", path: "Sources/CSquishCore"),
        .executableTarget(
            name: "Squish",
            dependencies: ["CSquishCore"],
            path: "Sources/Squish",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ],
            linkerSettings: [
                .unsafeFlags(["-L", coreLibDir]),
                .linkedLibrary("squish_core"),
                .linkedLibrary("iconv"),
            ]
        ),
    ]
)
