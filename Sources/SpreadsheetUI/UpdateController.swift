import AppKit
import SwiftUI

/// Drives update checks and their standard macOS UI: a manual
/// "Check for Updates…" command, a throttled silent check on launch, the
/// update-available dialog (Download / Skip / Later), and the preference to
/// check automatically. GitHub Releases is the source of truth.
@MainActor
public final class UpdateController: ObservableObject {
    public static let shared = UpdateController()

    private let defaults: UserDefaults
    private let checker: UpdateChecker

    private let autoKey = "SSAutomaticallyChecksForUpdates"
    private let lastCheckKey = "SSLastUpdateCheckAt"
    private let skipVersionKey = "SSSkippedUpdateVersion"
    private let minimumAutoInterval: TimeInterval = 24 * 60 * 60

    @Published public var isChecking = false
    @Published public var automaticallyChecksForUpdates: Bool {
        didSet { defaults.set(automaticallyChecksForUpdates, forKey: autoKey) }
    }

    public init(defaults: UserDefaults = .standard,
                checker: UpdateChecker = UpdateChecker()) {
        self.defaults = defaults
        self.checker = checker
        // Default ON, like Sparkle's post-first-launch default.
        if defaults.object(forKey: autoKey) == nil {
            defaults.set(true, forKey: autoKey)
        }
        self.automaticallyChecksForUpdates = defaults.bool(forKey: autoKey)
    }

    // MARK: Entry points

    /// Manual "Check for Updates…". Always reports the result (including
    /// up-to-date and errors).
    public func checkForUpdates() {
        runCheck(userInitiated: true)
    }

    /// Called once at launch. Silent unless a (non-skipped) update is found,
    /// and only if automatic checks are enabled and one is due.
    public func checkOnLaunchIfDue() {
        guard automaticallyChecksForUpdates else { return }
        let last = defaults.double(forKey: lastCheckKey)
        if last > 0 {
            let elapsed = Date().timeIntervalSince1970 - last
            if elapsed < minimumAutoInterval { return }
        }
        runCheck(userInitiated: false)
    }

    // MARK: Check

    private func runCheck(userInitiated: Bool) {
        guard !isChecking else { return }
        isChecking = true
        Task { @MainActor in
            defer { isChecking = false }
            do {
                let outcome = try await checker.check()
                defaults.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
                handle(outcome, userInitiated: userInitiated)
            } catch {
                if userInitiated { presentError(error) }
            }
        }
    }

    private func handle(_ outcome: UpdateCheckOutcome, userInitiated: Bool) {
        switch outcome {
        case .upToDate(let current, _):
            if userInitiated { presentUpToDate(current: current) }
        case .updateAvailable(let release):
            // Background checks respect a skipped version; manual checks always show.
            if !userInitiated, defaults.string(forKey: skipVersionKey) == release.version {
                return
            }
            presentUpdateAvailable(release)
        }
    }

    // MARK: Dialogs

    private func presentUpToDate(current: String) {
        let alert = NSAlert()
        alert.messageText = "You’re up to date!"
        alert.informativeText = "SimpleSpread \(current) is the latest version available."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentUpdateAvailable(_ release: UpdateRelease) {
        let alert = NSAlert()
        alert.messageText = "A new version of SimpleSpread is available!"
        var info = "SimpleSpread \(release.version) is now available"
        let current = checker.currentVersion
        if current != "0.0.0" { info += "—you have \(current)." } else { info += "." }
        let notes = Self.plainNotes(release.notes)
        if !notes.isEmpty {
            info += "\n\nRelease notes:\n\(notes)"
        }
        alert.informativeText = info
        alert.alertStyle = .informational
        alert.addButton(withTitle: release.downloadURL != nil ? "Download Update" : "View Release")
        alert.addButton(withTitle: "Skip This Version")
        alert.addButton(withTitle: "Remind Me Later")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(release.downloadURL ?? release.htmlURL)
        case .alertSecondButtonReturn:
            defaults.set(release.version, forKey: skipVersionKey)
        default:
            break // Remind Me Later
        }
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t check for updates"
        switch error {
        case UpdateError.http(let code):
            alert.informativeText = "The update server responded with an error (HTTP \(code)). Please try again later."
        case UpdateError.network(let message):
            alert.informativeText = "A network error occurred: \(message)"
        default:
            alert.informativeText = error.localizedDescription
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Trim markdown release notes to a short, readable excerpt for the alert.
    nonisolated static func plainNotes(_ body: String, maxLines: Int = 12, maxChars: Int = 900) -> String {
        let lines = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var s = String(line)
                // Strip leading markdown heading/bullet markers.
                s = s.replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
                s = s.replacingOccurrences(of: #"^\s*[-*]\s+"#, with: "• ", options: .regularExpression)
                return s
            }
        var excerpt = lines.prefix(maxLines).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if excerpt.count > maxChars {
            excerpt = String(excerpt.prefix(maxChars)) + "…"
        }
        return excerpt
    }
}
