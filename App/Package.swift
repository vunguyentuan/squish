// swift-tools-version: 6.2
import PackageDescription

// The Rust engine is built by `make core` into ../core/target/release/libsquish_core.a.
let coreLibDir = Context.packageDirectory + "/../core/target/release"

let package = Package(
    name: "Squish",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", .upToNextMinor(from: "2.9.6")),
    ],
    targets: [
        .systemLibrary(name: "CSquishCore", path: "Sources/CSquishCore"),
        .executableTarget(
            name: "Squish",
            dependencies: ["CSquishCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Squish",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ],
            linkerSettings: [
                .unsafeFlags(["-L", coreLibDir, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedLibrary("squish_core"),
                .linkedLibrary("iconv"),
            ]
        ),
        .testTarget(
            name: "SquishTests",
            dependencies: ["Squish"],
            path: "Tests/SquishTests",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
    ]
)
