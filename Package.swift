// swift-tools-version: 6.1
import PackageDescription

/// The Mac App Store build leaves out Sparkle: the App Store updates the
/// app. `SIMPLESPREAD_APP_STORE=1 swift build …` (scripts/build-app-store.sh).
let appStore = Context.environment["SIMPLESPREAD_APP_STORE"] != nil

let package = Package(
    name: "SimpleSpread",
    platforms: [
        .macOS(.v14),
        // The iPad app (iOS/ holds its Xcode project; see docs/IPAD.md).
        .iOS("26.0"),
    ],
    products: [
        .executable(name: "SimpleSpread", targets: ["SimpleSpread"]),
        .library(name: "SpreadsheetCore", targets: ["SpreadsheetCore"]),
        .library(name: "SpreadsheetFiles", targets: ["SpreadsheetFiles"]),
        // Linked by the iPad app.
        .library(name: "SpreadsheetUI", targets: ["SpreadsheetUI"]),
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
        // Document model, grid rendering and interaction, SwiftUI chrome
        // (Shared/), plus each platform's shell: AppKit (Mac/) and UIKit
        // (iOS/). Platform files are wrapped whole in `#if os(...)`.
        .target(name: "SpreadsheetUI",
                dependencies: ["SpreadsheetCore", "SpreadsheetFiles"] + (appStore ? [] : [
                    .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
                ]),
                swiftSettings: appStore ? [.define("APP_STORE")] : []),
        // Thin app entry point.
        .executableTarget(name: "SimpleSpread", dependencies: ["SpreadsheetUI"]),
        // Big-file load timing (`swift run -c release spreadsheet-bench <file>`);
        // a developer tool, not shipped.
        .executableTarget(name: "spreadsheet-bench", dependencies: ["SpreadsheetCore", "SpreadsheetFiles"]),

        .testTarget(name: "SpreadsheetCoreTests", dependencies: ["SpreadsheetCore"]),
        .testTarget(name: "SpreadsheetFilesTests", dependencies: ["SpreadsheetFiles"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "SpreadsheetUITests", dependencies: ["SpreadsheetUI"]),
        // The Mac app's windows driven the way a person uses them (clicks,
        // keys, menus, reading the screen), over real-sized files. Slow:
        // run locally with scripts/ui-tests.sh (SIMPLESPREAD_UI_TESTS=1),
        // not in CI. See Tests/SpreadsheetAppUITests/README.md.
        .testTarget(name: "SpreadsheetAppUITests", dependencies: ["SpreadsheetUI", "SpreadsheetFiles", "SpreadsheetCore"],
                    exclude: ["README.md"]),
    ],
    swiftLanguageModes: [.v6]
)
