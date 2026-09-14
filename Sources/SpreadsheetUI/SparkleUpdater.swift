import Foundation
import Combine
import Sparkle

/// App identity used by the updater and elsewhere.
public enum AppInfo {
    public static let repository = "baudehlo/SimpleSpread"

    public static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0"
    }
}

/// Thin wrapper around Sparkle's standard updater controller.
///
/// Sparkle performs the full in-place update: it downloads the signed DMG from
/// the appcast, verifies the EdDSA signature (and, on notarized builds, the
/// Apple code signature), replaces the running `.app` after it quits, and
/// relaunches it. Configuration (SUFeedURL, SUPublicEDKey, automatic-check
/// settings) lives in the bundle Info.plist, injected by the build scripts.
@MainActor
public final class SparkleUpdater: ObservableObject {
    public static let shared = SparkleUpdater()

    private let controller: SPUStandardUpdaterController

    /// True once Sparkle is configured and idle enough to start a check
    /// (drives the menu item's enabled state).
    @Published public private(set) var canCheckForUpdates = false

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// Manual "Check for Updates…" — shows Sparkle's standard UI (progress,
    /// release notes, install & relaunch, or an up-to-date/error alert).
    public func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// The "Automatically Check for Updates" preference (persisted by Sparkle).
    public var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}
