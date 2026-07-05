// swift-tools-version: 6.0
import PackageDescription

// ponytail: language mode .v5 for M0 — this is glue with AppKit main-thread and
// Carbon C-callback assumptions. Migrate the two protocol seams + engine to Swift 6
// strict-concurrency (actor-isolated) once the surface stabilizes (M2+).
let package = Package(
    name: "Sotto",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "Sotto",
            path: "Sources/Sotto",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // Under CommandLineTools, swift-testing isn't on the default search path,
        // so `import Testing` and the runner need extra -F/-rpath flags. Applying
        // them only to this target breaks SwiftPM's synthesized test-runner (it
        // discovers 0 tests and silently passes), so they're passed build-wide via
        // scripts/test.sh instead. Run tests with: bash scripts/test.sh
        .testTarget(
            name: "SottoTests",
            dependencies: ["Sotto"],
            path: "Tests/SottoTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
