// swift-tools-version: 6.2
// Builds FineTune with Swift Package Manager (no Xcode project), dependencies in ../deps.
import PackageDescription

let package = Package(
    name: "FineTune",
    platforms: [.macOS("15.4")],
    dependencies: [
        .package(path: "../deps/KeyboardShortcuts"),
        .package(path: "../deps/FluidMenuBarExtra"),
    ],
    targets: [
        .executableTarget(
            name: "FineTune",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "FluidMenuBarExtra", package: "FluidMenuBarExtra"),
            ],
            path: "FineTune",
            exclude: ["Assets.xcassets", "Info.plist", "FineTune.entitlements"],
            swiftSettings: [
                // Swift 5 mode: a newer compiler than upstream's turns some isolation warnings into errors
                .swiftLanguageMode(.v5),
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("MemberImportVisibility"),
                .define("ENABLE_TCC_SPI"),
            ]
        ),
    ]
)
