import Foundation

/// A local CLI-backed AI engine Cue can drive. Every provider is a binary on the
/// user's machine — Cue inherits its auth, so there are no keys to manage.
enum Provider: String, CaseIterable {
    case claude
    case codex
    case gemini
    case ollama

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .ollama: return "Ollama"
        }
    }

    var binaryName: String { rawValue }

    /// Shell one-liner that installs this provider. Shown in error copy and onboarding.
    var installCommand: String {
        switch self {
        case .claude: return "npm i -g @anthropic-ai/claude-code"
        case .codex: return "npm i -g @openai/codex"
        case .gemini: return "npm i -g @google/gemini-cli"
        case .ollama: return "Download from ollama.com"
        }
    }

    /// npm package for terminal-driven install, nil when the provider isn't npm-distributed.
    var npmPackage: String? {
        switch self {
        case .claude: return "@anthropic-ai/claude-code"
        case .codex: return "@openai/codex"
        case .gemini: return "@google/gemini-cli"
        case .ollama: return nil
        }
    }

    /// Local models load into memory on first call; give them room. Cloud CLIs fail fast.
    var timeoutSeconds: Double {
        switch self {
        case .claude: return 45
        case .codex: return 120
        case .gemini: return 60
        case .ollama: return 180
        }
    }

    /// Extra non-PATH locations this provider's binary can live in.
    var extraBinaryPaths: [String] {
        switch self {
        case .ollama: return ["/Applications/Ollama.app/Contents/Resources/ollama"]
        default: return []
        }
    }

    // MARK: - Detection

    /// All providers with a working binary on this machine, in menu order.
    /// Filesystem checks only — safe to call from the main thread and from pollers.
    static func detected() -> [Provider] {
        allCases.filter { BinaryLocator.locateFresh($0) != nil }
    }

    // MARK: - Models

    /// Claude models exposed in the picker. IDs must match `claude --model` values.
    static let claudeModels: [(id: String, name: String, subtitle: String)] = [
        ("claude-haiku-4-5", "Haiku 4.5", "Fastest, default"),
        ("claude-sonnet-5", "Sonnet 5", "Balanced"),
        ("claude-opus-4-8", "Opus 4.8", "Deepest"),
    ]

    /// Installed Ollama models, parsed from `ollama list`. Synchronous but fast (local daemon).
    static func ollamaModels() -> [String] {
        guard let bin = BinaryLocator.locate(.ollama) else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = ["list"]
        process.environment = BinaryLocator.augmentedEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        guard let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return []
        }
        return out
            .components(separatedBy: "\n")
            .dropFirst() // header row: NAME ID SIZE MODIFIED
            .compactMap { line in
                let name = line.split(separator: " ").first.map(String.init)
                return (name?.isEmpty ?? true) ? nil : name
            }
    }
}

/// Finds provider binaries. macOS GUI apps get a bare PATH (/usr/bin:/bin), so we check
/// the places CLIs actually live, then fall back to a login-shell `command -v`.
enum BinaryLocator {
    /// Session cache of successful lookups. Failures are never cached — next call retries.
    private static var cache: [Provider: String] = [:]
    private static let cacheLock = NSLock()

    /// Full lookup including the login-shell fallback. Can take ~100ms+ on a miss —
    /// call it off the main thread (the stream runners do).
    static func locate(_ provider: Provider) -> String? {
        cacheLock.lock()
        if let hit = cache[provider] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        guard let found = search(provider) ?? shellSearch(provider) else { return nil }
        cacheLock.lock()
        cache[provider] = found
        cacheLock.unlock()
        return found
    }

    /// Uncached, filesystem-only lookup for detection UI and pollers — newly installed
    /// binaries appear immediately, and no shells are spawned on the main thread.
    static func locateFresh(_ provider: Provider) -> String? {
        guard let found = search(provider) else {
            cacheLock.lock()
            cache[provider] = nil
            cacheLock.unlock()
            return nil
        }
        cacheLock.lock()
        cache[provider] = found
        cacheLock.unlock()
        return found
    }

    private static func search(_ provider: Provider) -> String? {
        let home = NSHomeDirectory()
        let name = provider.binaryName

        var candidates = [
            "\(home)/.npm-global/bin/\(name)",
            "\(home)/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.bun/bin/\(name)",
        ]
        candidates.append(contentsOf: provider.extraBinaryPaths)

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        // nvm keeps binaries per node version: ~/.nvm/versions/node/<v>/bin/<name>
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            for v in entries.sorted(by: >) {
                let p = "\(nvmRoot)/\(v)/bin/\(name)"
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    /// Login-shell `command -v` for exotic installs. Slow (sources the user's shell
    /// profile) — only used by `locate`, never by detection polling.
    private static func shellSearch(_ provider: Provider) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "command -v \(provider.binaryName)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let path = path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {
            NSLog("[Cue] shell lookup for \(provider.binaryName) failed: \(error)")
        }
        return nil
    }

    /// PATH augmented with every directory where node/npm/CLIs commonly live — needed so
    /// `#!/usr/bin/env node` shebangs resolve when Cue spawns a provider binary.
    static func augmentedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()

        var extras: [String] = [
            "\(home)/.npm-global/bin",
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.bun/bin",
        ]
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            for v in entries.sorted(by: >) {
                let bin = "\(nvmRoot)/\(v)/bin"
                if FileManager.default.fileExists(atPath: bin) {
                    extras.insert(bin, at: 0)
                    break
                }
            }
        }

        let existing = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extras + [existing]).joined(separator: ":")
        env["HOME"] = home
        return env
    }
}
