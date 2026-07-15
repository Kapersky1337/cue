import Foundation

/// UserDefaults-backed settings. Keys are namespaced under "cue.*".
enum Settings {
    private static let defaults = UserDefaults.standard

    /// Active AI engine. Defaults to the first detected provider so a Codex-only or
    /// Ollama-only machine works out of the box with zero configuration.
    static var provider: Provider {
        get {
            if let raw = defaults.string(forKey: "cue.provider"),
               let p = Provider(rawValue: raw) {
                return p
            }
            return Provider.detected().first ?? .claude
        }
        set { defaults.set(newValue.rawValue, forKey: "cue.provider") }
    }

    /// Claude model ID passed to `claude --model`. Key kept from v0.10 ("cue.model");
    /// stale IDs from old installs fall back to the first current model.
    static var claudeModel: String {
        get {
            let raw = defaults.string(forKey: "cue.model") ?? ""
            if Provider.claudeModels.contains(where: { $0.id == raw }) { return raw }
            return Provider.claudeModels[0].id
        }
        set { defaults.set(newValue, forKey: "cue.model") }
    }

    /// Ollama model name passed to `ollama run`. Empty string means "first installed model".
    static var ollamaModel: String {
        get {
            let saved = defaults.string(forKey: "cue.ollamaModel") ?? ""
            if !saved.isEmpty { return saved }
            return Provider.ollamaModels().first ?? ""
        }
        set { defaults.set(newValue, forKey: "cue.ollamaModel") }
    }

    static var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: "cue.onboarded") }
        set { defaults.set(newValue, forKey: "cue.onboarded") }
    }
}
