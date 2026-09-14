import Foundation

/// App identity / version, sourced from the bundle when packaged, or a
/// compiled fallback for `swift run` / test builds.
public enum AppInfo {
    /// GitHub "owner/repo" the updater queries.
    public static let repository = "baudehlo/SimpleSpread"

    /// Fallback when there is no Info.plist version (unbundled dev/test runs).
    /// A real release build reports its injected CFBundleShortVersionString.
    public static let fallbackVersion = "0.0.0"

    public static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? fallbackVersion
    }
}

/// A release discovered on GitHub.
public struct UpdateRelease: Equatable, Sendable {
    /// Version without a leading "v" (e.g. "1.2.3").
    public let version: String
    /// The original tag (e.g. "v1.2.3").
    public let tag: String
    public let name: String
    public let notes: String
    public let htmlURL: URL
    /// The .dmg asset download URL, if the release ships one.
    public let downloadURL: URL?
    public let publishedAt: String?
}

public enum UpdateCheckOutcome: Equatable, Sendable {
    /// No newer release than `current`. `latest` may equal `current`.
    case upToDate(current: String, latest: String)
    case updateAvailable(UpdateRelease)
}

public enum UpdateError: Error, Equatable {
    case http(Int)
    case malformed(String)
    case network(String)
}

/// Queries GitHub Releases and decides whether a newer version exists.
/// The parsing and version comparison are pure and unit-tested; `check()`
/// wraps them with a URLSession fetch.
public struct UpdateChecker: Sendable {
    public let repository: String
    public let currentVersion: String

    public init(repository: String = AppInfo.repository,
                currentVersion: String = AppInfo.currentVersion) {
        self.repository = repository
        self.currentVersion = currentVersion
    }

    public var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    // MARK: Networking

    public func check(using session: URLSession = .shared) async throws -> UpdateCheckOutcome {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SimpleSpread-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try evaluate(responseData: data, statusCode: status)
    }

    // MARK: Pure evaluation (tested)

    public func evaluate(responseData: Data, statusCode: Int) throws -> UpdateCheckOutcome {
        // 404 from /releases/latest means the repo has no published release yet.
        if statusCode == 404 {
            return .upToDate(current: currentVersion, latest: currentVersion)
        }
        guard (200..<300).contains(statusCode) else {
            throw UpdateError.http(statusCode)
        }
        let release = try UpdateChecker.parseLatestRelease(responseData)
        if UpdateChecker.isNewer(release.version, than: currentVersion) {
            return .updateAvailable(release)
        }
        return .upToDate(current: currentVersion, latest: release.version)
    }

    // MARK: Release JSON

    private struct ReleaseJSON: Decodable {
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String
        let draft: Bool?
        let prerelease: Bool?
        let published_at: String?
        let assets: [Asset]?

        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
            let content_type: String?
        }
    }

    public static func parseLatestRelease(_ data: Data) throws -> UpdateRelease {
        let decoded: ReleaseJSON
        do {
            decoded = try JSONDecoder().decode(ReleaseJSON.self, from: data)
        } catch {
            throw UpdateError.malformed("release JSON: \(error.localizedDescription)")
        }
        guard let htmlURL = URL(string: decoded.html_url) else {
            throw UpdateError.malformed("bad html_url")
        }
        let dmg = decoded.assets?.first {
            $0.name.lowercased().hasSuffix(".dmg")
                || $0.content_type == "application/x-apple-diskimage"
        }
        let downloadURL = dmg.flatMap { URL(string: $0.browser_download_url) }
        return UpdateRelease(
            version: normalize(decoded.tag_name),
            tag: decoded.tag_name,
            name: decoded.name?.isEmpty == false ? decoded.name! : decoded.tag_name,
            notes: decoded.body ?? "",
            htmlURL: htmlURL,
            downloadURL: downloadURL,
            publishedAt: decoded.published_at)
    }

    // MARK: Semantic version comparison

    /// Strip a leading v/V.
    public static func normalize(_ version: String) -> String {
        var v = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("v") || v.hasPrefix("V") { v = String(v.dropFirst()) }
        return v
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    /// Semver-lite comparison: numeric core components, then prerelease
    /// ordering (a release outranks the same core's prerelease; numeric
    /// identifiers rank below alphanumeric ones).
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let (aCore, aPre) = split(a)
        let (bCore, bPre) = split(b)
        let coreCount = max(aCore.count, bCore.count)
        for i in 0..<coreCount {
            let x = i < aCore.count ? aCore[i] : 0
            let y = i < bCore.count ? bCore[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        if aPre.isEmpty && bPre.isEmpty { return .orderedSame }
        if aPre.isEmpty { return .orderedDescending } // release > prerelease
        if bPre.isEmpty { return .orderedAscending }
        let preCount = max(aPre.count, bPre.count)
        for i in 0..<preCount {
            if i >= aPre.count { return .orderedAscending }  // fewer fields = lower precedence
            if i >= bPre.count { return .orderedDescending }
            let x = aPre[i], y = bPre[i]
            switch (Int(x), Int(y)) {
            case let (m?, n?):
                if m != n { return m < n ? .orderedAscending : .orderedDescending }
            case (.some, nil):
                return .orderedAscending   // numeric < alphanumeric
            case (nil, .some):
                return .orderedDescending
            case (nil, nil):
                if x != y { return x < y ? .orderedAscending : .orderedDescending }
            }
        }
        return .orderedSame
    }

    private static func split(_ version: String) -> (core: [Int], prerelease: [String]) {
        let v = normalize(version)
        let dash = v.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let coreStr = String(dash[0])
        let preStr = dash.count > 1 ? String(dash[1]) : ""
        var core = coreStr.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        if core.isEmpty { core = [0] }
        let pre = preStr.isEmpty ? [] : preStr.split(separator: ".").map(String.init)
        return (core, pre)
    }
}
