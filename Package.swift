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
    targets: [
        // Model, formula engine, calculation graph, number formatting.
        .target(name: "SpreadsheetCore"),
        // File formats: minimal ZIP container, XLSX read/write, CSV import/export.
        .target(name: "SpreadsheetFiles", dependencies: ["SpreadsheetCore"]),
        // Document model, view models, AppKit grid view, SwiftUI chrome.
        .target(name: "SpreadsheetUI", dependencies: ["SpreadsheetCore", "SpreadsheetFiles"]),
        // Thin app entry point.
        .executableTarget(name: "SimpleSpread", dependencies: ["SpreadsheetUI"]),

        .testTarget(name: "SpreadsheetCoreTests", dependencies: ["SpreadsheetCore"]),
        .testTarget(name: "SpreadsheetFilesTests", dependencies: ["SpreadsheetFiles"]),
        .testTarget(name: "SpreadsheetUITests", dependencies: ["SpreadsheetUI"]),
    ],
    swiftLanguageModes: [.v6]
)
