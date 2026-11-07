// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Noddle",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NoddleCore", targets: ["NoddleCore"]),
        .executable(name: "Noddle", targets: ["Noddle"]),
    ],
    targets: [
        // Pure logic: pose tracking, gestures, mapping, the figure. No AppKit, fully testable.
        .target(name: "NoddleCore"),
        // The AppKit menu bar app.
        .executableTarget(
            name: "Noddle",
            dependencies: ["NoddleCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Developer tool: renders the line figure to a PNG contact sheet.
        .executableTarget(name: "FigureSheet", dependencies: ["NoddleCore"]),
        .testTarget(name: "NoddleCoreTests", dependencies: ["NoddleCore"]),
    ]
)
