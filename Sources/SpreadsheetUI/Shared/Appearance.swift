import Foundation

/// Light or dark, whatever the system uses (issue #2: a Mac in dark mode,
/// a spreadsheet wanted light, as Excel can be).
public enum AppearanceChoice: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Use System Setting"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// The app's appearance choice (View ▸ Appearance), remembered between
/// launches. Applying it is each platform's (AppearanceApplier).
@MainActor
public final class AppearanceSetting: ObservableObject {
    public static let shared = AppearanceSetting()
    static let defaultsKey = "SSAppearance"

    private let defaults: UserDefaults

    @Published public var choice: AppearanceChoice {
        didSet {
            defaults.set(choice.rawValue, forKey: Self.defaultsKey)
            apply()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        choice = defaults.string(forKey: Self.defaultsKey).flatMap(AppearanceChoice.init) ?? .system
    }

    /// Make the app look as chosen (at launch, and when a window opens).
    public func apply() {
        AppearanceApplier.apply(choice)
    }
}
