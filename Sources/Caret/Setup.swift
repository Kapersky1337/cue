import Foundation
import Cocoa
import ApplicationServices

/// Snapshot of everything Cue needs to function. Polled by onboarding every 0.5s.
struct SetupState: Equatable {
    var accessibilityGranted: Bool
    var detectedProviders: [Provider]
    var claudeAuthenticated: Bool

    /// Cue is ready with accessibility plus any one engine. Claude auth stays optional —
    /// a sign-in problem surfaces as a clear inline error at first use.
    var allReady: Bool {
        accessibilityGranted && !detectedProviders.isEmpty
    }
}

enum SetupChecks {
    static func current() -> SetupState {
        SetupState(
            accessibilityGranted: AccessibilityCheck.isReallyGranted(),
            detectedProviders: Provider.allCases.filter { BinaryLocator.locateFresh($0) != nil },
            claudeAuthenticated: hasClaudeCredentials()
        )
    }

    /// Returns the path to `npm` if found, else nil.
    static func npmPath() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/npm",
            "/usr/local/bin/npm",
            "/usr/bin/npm",
            "\(home)/.npm-global/bin/npm",
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            for v in entries.sorted(by: >) {
                let p = "\(nvmRoot)/\(v)/bin/npm"
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    /// Heuristic: does the Claude CLI have stored credentials? Also accepts ANTHROPIC_API_KEY.
    static func hasClaudeCredentials() -> Bool {
        let home = NSHomeDirectory()
        let paths = [
            "\(home)/.claude/.credentials.json",
            "\(home)/.config/claude/.credentials.json",
            "\(home)/Library/Application Support/Claude/credentials.json",
        ]
        for p in paths where FileManager.default.fileExists(atPath: p) {
            return true
        }
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            return true
        }
        return false
    }
}

enum SetupActions {
    /// Opens Accessibility settings + registers Cue in TCC (so it appears in the list).
    static func openAccessibilityPane() {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Installs an npm-distributed provider in a Terminal window, or opens the download
    /// page for providers that ship as apps (Ollama).
    static func install(_ provider: Provider) {
        guard let package = provider.npmPackage else {
            if provider == .ollama, let url = URL(string: "https://ollama.com/download") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        guard SetupChecks.npmPath() != nil else {
            openNodeInstall()
            return
        }
        let npm = SetupChecks.npmPath() ?? "npm"
        let cmd = """
        clear
        echo "Installing \(provider.displayName)…"
        echo
        \"\(npm)\" install -g \(package)
        STATUS=$?
        if [ $STATUS -eq 0 ]; then
            echo
            echo "✓ Installed. You can close this window — Cue will detect it."
        else
            echo
            echo "Install failed. If permission was denied, run:"
            echo "  sudo \(npm) install -g \(package)"
        fi
        """
        runInTerminal(cmd, title: "Install \(provider.displayName)")
    }

    /// Opens Terminal to start the Claude CLI's interactive OAuth flow.
    static func signInToClaude() {
        let cmd = """
        clear
        echo "Sign in to Claude. Claude will open the browser to authenticate."
        echo
        claude
        """
        runInTerminal(cmd, title: "Sign in to Claude")
    }

    /// Opens the Node.js download page in the user's default browser.
    static func openNodeInstall() {
        if let url = URL(string: "https://nodejs.org/en/download") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Writes a temporary executable .command file and `open`s it. macOS launches
    /// Terminal with the script running. No AppleEvents permission needed.
    private static func runInTerminal(_ command: String, title: String) {
        let home = NSHomeDirectory()
        let pathAdditions = [
            "\(home)/.npm-global/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
        ]
        let script = """
        #!/bin/bash
        export PATH="\(pathAdditions.joined(separator: ":")):$PATH"
        echo -ne "\\033]0;\(title)\\007"
        \(command)
        """

        let dir = NSTemporaryDirectory()
        let file = "\(dir)cue-\(UUID().uuidString).command"
        do {
            try script.write(toFile: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: file
            )
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Terminal", file]
            try process.run()
            NSLog("[Cue] launched Terminal with \(file)")
        } catch {
            NSLog("[Cue] failed to launch Terminal: \(error)")
        }
    }
}
