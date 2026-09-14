import Foundation
import Testing
@testable import SpreadsheetUI

@Suite("Update version comparison")
struct UpdateVersionTests {
    @Test func ordering() {
        #expect(UpdateChecker.compare("1.0.0", "1.0.0") == .orderedSame)
        #expect(UpdateChecker.compare("1.2.0", "1.1.9") == .orderedDescending)
        #expect(UpdateChecker.compare("1.0.1", "1.0.10") == .orderedAscending)
        #expect(UpdateChecker.compare("2.0.0", "1.9.9") == .orderedDescending)
        // Leading v and different component counts.
        #expect(UpdateChecker.compare("v1.2", "1.2.0") == .orderedSame)
        #expect(UpdateChecker.compare("v1.2.1", "v1.2") == .orderedDescending)
    }

    @Test func prereleaseOrdering() {
        // A release outranks the same core's prerelease.
        #expect(UpdateChecker.compare("1.0.0", "1.0.0-beta.1") == .orderedDescending)
        #expect(UpdateChecker.compare("1.0.0-beta.1", "1.0.0-beta.2") == .orderedAscending)
        #expect(UpdateChecker.compare("1.0.0-alpha", "1.0.0-beta") == .orderedAscending)
        // Numeric identifiers rank below alphanumeric.
        #expect(UpdateChecker.compare("1.0.0-1", "1.0.0-alpha") == .orderedAscending)
        // Fewer prerelease fields = lower precedence.
        #expect(UpdateChecker.compare("1.0.0-beta", "1.0.0-beta.1") == .orderedAscending)
    }

    @Test func devVersionIsAlwaysBehindReleases() {
        // Fallback "0.0.0"/"dev" reads as the lowest version.
        #expect(UpdateChecker.isNewer("1.0.0", than: "0.0.0"))
        #expect(UpdateChecker.isNewer("0.1.0", than: "dev"))
        #expect(!UpdateChecker.isNewer("0.0.0", than: "1.0.0"))
    }

    @Test func isNewerConvenience() {
        #expect(UpdateChecker.isNewer("1.2.0", than: "1.1.0"))
        #expect(!UpdateChecker.isNewer("1.1.0", than: "1.1.0"))
        #expect(!UpdateChecker.isNewer("1.0.0", than: "1.0.1"))
    }
}

@Suite("Update release parsing & evaluation")
struct UpdateReleaseTests {
    static let sampleJSON = """
    {
      "tag_name": "v1.2.0",
      "name": "SimpleSpread 1.2.0",
      "body": "## What's new\\n- Faster recalculation\\n- Bug fixes",
      "html_url": "https://github.com/baudehlo/SimpleSpread/releases/tag/v1.2.0",
      "draft": false,
      "prerelease": false,
      "published_at": "2026-09-14T10:00:00Z",
      "assets": [
        {
          "name": "SimpleSpread-v1.2.0.dmg",
          "browser_download_url": "https://github.com/baudehlo/SimpleSpread/releases/download/v1.2.0/SimpleSpread-v1.2.0.dmg",
          "content_type": "application/x-apple-diskimage"
        },
        {
          "name": "notes.txt",
          "browser_download_url": "https://example.com/notes.txt",
          "content_type": "text/plain"
        }
      ]
    }
    """

    @Test func parsesRelease() throws {
        let release = try UpdateChecker.parseLatestRelease(Data(Self.sampleJSON.utf8))
        #expect(release.version == "1.2.0")
        #expect(release.tag == "v1.2.0")
        #expect(release.name == "SimpleSpread 1.2.0")
        #expect(release.notes.contains("Faster recalculation"))
        #expect(release.downloadURL?.lastPathComponent == "SimpleSpread-v1.2.0.dmg")
        #expect(release.htmlURL.absoluteString.hasSuffix("tag/v1.2.0"))
    }

    @Test func parsesReleaseWithoutDMG() throws {
        let json = """
        {"tag_name":"v1.0.0","html_url":"https://github.com/x/y/releases/tag/v1.0.0","assets":[]}
        """
        let release = try UpdateChecker.parseLatestRelease(Data(json.utf8))
        #expect(release.downloadURL == nil)
        #expect(release.name == "v1.0.0") // falls back to the tag
    }

    @Test func malformedJSONThrows() {
        #expect(throws: UpdateError.self) {
            _ = try UpdateChecker.parseLatestRelease(Data("not json".utf8))
        }
    }

    @Test func evaluateUpdateAvailable() throws {
        let checker = UpdateChecker(repository: "baudehlo/SimpleSpread", currentVersion: "1.0.0")
        let outcome = try checker.evaluate(responseData: Data(Self.sampleJSON.utf8), statusCode: 200)
        guard case .updateAvailable(let release) = outcome else {
            Issue.record("expected update available"); return
        }
        #expect(release.version == "1.2.0")
    }

    @Test func evaluateUpToDate() throws {
        let checker = UpdateChecker(repository: "r", currentVersion: "1.2.0")
        let outcome = try checker.evaluate(responseData: Data(Self.sampleJSON.utf8), statusCode: 200)
        #expect(outcome == .upToDate(current: "1.2.0", latest: "1.2.0"))
    }

    @Test func evaluateNewerThanRelease() throws {
        let checker = UpdateChecker(repository: "r", currentVersion: "2.0.0")
        let outcome = try checker.evaluate(responseData: Data(Self.sampleJSON.utf8), statusCode: 200)
        #expect(outcome == .upToDate(current: "2.0.0", latest: "1.2.0"))
    }

    @Test func noReleasesYieldsUpToDate() throws {
        let checker = UpdateChecker(repository: "r", currentVersion: "1.0.0")
        // GitHub returns 404 from /releases/latest when there are no releases.
        let outcome = try checker.evaluate(responseData: Data("{}".utf8), statusCode: 404)
        #expect(outcome == .upToDate(current: "1.0.0", latest: "1.0.0"))
    }

    @Test func httpErrorThrows() {
        let checker = UpdateChecker(repository: "r", currentVersion: "1.0.0")
        #expect(throws: UpdateError.self) {
            _ = try checker.evaluate(responseData: Data(), statusCode: 500)
        }
    }

    @Test func notesAreTrimmedForDisplay() {
        let notes = "## Heading\n- one\n- two\n\nmore text"
        let plain = UpdateController.plainNotes(notes)
        #expect(plain.contains("Heading"))
        #expect(plain.contains("• one"))
        #expect(!plain.contains("##"))
        // Long bodies get truncated.
        let long = String(repeating: "line\n", count: 100)
        #expect(UpdateController.plainNotes(long, maxLines: 5).split(separator: "\n").count <= 5)
    }
}

@MainActor
@Suite("Update controller preferences & throttle")
struct UpdateControllerTests {
    func makeDefaults() -> UserDefaults {
        let suite = "simplespread-tests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test func automaticCheckDefaultsOn() {
        let controller = UpdateController(defaults: makeDefaults())
        #expect(controller.automaticallyChecksForUpdates)
    }

    @Test func togglePersists() {
        let defaults = makeDefaults()
        let controller = UpdateController(defaults: defaults)
        controller.automaticallyChecksForUpdates = false
        #expect(defaults.bool(forKey: "SSAutomaticallyChecksForUpdates") == false)
        // A fresh controller reads the stored preference.
        let reloaded = UpdateController(defaults: defaults)
        #expect(!reloaded.automaticallyChecksForUpdates)
    }
}
