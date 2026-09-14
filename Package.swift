// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "SimpleSpread",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SimpleSpread", targets: ["SimpleSpread"]),
        .library(name: "SpreadsheetCore", targets: ["SpreadsheetCore"]),
        .library(name: "SpreadsheetFiles", targets: ["SpreadsheetFiles"]),
    ],
    dependencies: [
        // Software updates (in-place, signed) — see docs/UPDATES.md.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Model, formula engine, calculation graph, number formatting.
        .target(name: "SpreadsheetCore"),
        // File formats: minimal ZIP container, XLSX read/write, CSV import/export.
        .target(name: "SpreadsheetFiles", dependencies: ["SpreadsheetCore"]),
        // Document model, view models, AppKit grid view, SwiftUI chrome.
        .target(name: "SpreadsheetUI", dependencies: [
            "SpreadsheetCore",
            "SpreadsheetFiles",
            .product(name: "Sparkle", package: "Sparkle"),
        ]),
        // Thin app entry point.
        .executableTarget(name: "SimpleSpread", dependencies: ["SpreadsheetUI"]),

        .testTarget(name: "SpreadsheetCoreTests", dependencies: ["SpreadsheetCore"]),
        .testTarget(name: "SpreadsheetFilesTests", dependencies: ["SpreadsheetFiles"]),
        .testTarget(name: "SpreadsheetUITests", dependencies: ["SpreadsheetUI"]),
    ],
    swiftLanguageModes: [.v6]
)
