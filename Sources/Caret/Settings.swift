import Foundation

/// Models the user can pick from. Maps to `--model` flag values for `claude -p`.
enum CueModel: String, CaseIterable {
    case haiku = "claude-haiku-4-5"
    case sonnet = "claude-sonnet-4-5"
    case opus = "claude-opus-4-5"

    var displayName: String {
        switch self {
        case .haiku: return "Haiku 4.5"
        case .sonnet: return "Sonnet 4.5"
        case .opus: return "Opus 4.5"
        }
    }

    var subtitle: String {
        switch self {
        case .haiku: return "Fastest, default"
        case .sonnet: return "Balanced"
        case .opus: return "Deepest"
        }
    }
}

/// Simple UserDefaults-backed settings. Keys are namespaced under "cue.*".
enum Settings {
    private static let defaults = UserDefaults.standard

    static var model: CueModel {
        get {
            let raw = defaults.string(forKey: "cue.model") ?? CueModel.haiku.rawValue
            return CueModel(rawValue: raw) ?? .haiku
        }
        set { defaults.set(newValue.rawValue, forKey: "cue.model") }
    }

    static var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: "cue.onboarded") }
        set { defaults.set(newValue, forKey: "cue.onboarded") }
    }
}
