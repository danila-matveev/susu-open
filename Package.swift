// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Susu",
    defaultLocalization: "ru",
    platforms: [.macOS("14.4"), .iOS(.v17)],
    products: [
        .library(name: "SusuCore", targets: ["SusuCore"]),
        .library(name: "SusuApp", targets: ["SusuApp"]),
        .executable(name: "Susu", targets: ["Susu"]),
        .executable(name: "susu-bench", targets: ["susu-bench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        // GigaAM on the Mac (spec 2.1): official Microsoft package, CPU execution only.
        // ponytail: upstream microsoft repo removed ~2026-11-18; mirror pinned to the exact upstream commit (1.24.2). Own fork if this mirror goes too.
        .package(url: "https://github.com/thesagezm/onnxruntime-swift-package-manager", revision: "b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2"),
        // Snapshot tests only: linked into SusuAppSnapshotTests, never into a product or the app.
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.18.0"),
    ],
    targets: [
        .target(name: "SusuCore", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
        ]),
        // UI (windows, pill, menu). A library so Xcode previews and snapshot tests can import it.
        .target(name: "SusuApp", dependencies: ["SusuCore"], resources: [.process("Resources")]),
        .executableTarget(name: "Susu", dependencies: ["SusuApp", "SusuCore"]),
        .executableTarget(name: "susu-bench", dependencies: ["SusuCore"]),
        .testTarget(name: "SusuCoreTests", dependencies: ["SusuCore"]),
        .testTarget(
            name: "SusuAppSnapshotTests",
            dependencies: [
                "SusuApp", "SusuCore",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            exclude: ["__Snapshots__"]
        ),
    ]
)
