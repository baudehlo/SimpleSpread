import Foundation

/// App identity used by the updater and elsewhere.
public enum AppInfo {
    public static let repository = "baudehlo/SimpleSpread"

    public static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0"
    }
}
