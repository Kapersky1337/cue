import Foundation
import Cocoa
import ApplicationServices

/// Snapshot of everything Cue needs to function. Polled by onboarding every 0.5s.
struct SetupState: Equatable {
    var accessibilityGranted: Bool
    var nodeInstalled: Bool
    var claudeInstalled: Bool
    var claudeAuthenticated: Bool

    /// Required-only readiness. Auth is optional because many users either:
    ///   (a) already authenticated their local Claude CLI before installing Cue, or
    ///   (b) prefer to sign in later via the menubar.
    /// If they hit Continue without auth and `claude -p` fails at runtime, the inline
    /// error in the panel surfaces it clearly.
    var allReady: Bool {
        accessibilityGranted && claudeInstalled
    }
}

enum SetupChecks {
    static func current() -> SetupState {
        SetupState(
            accessibilityGranted: AccessibilityCheck.isReallyGranted(),
            nodeInstalled: nodePath() != nil,
            claudeInstalled: ClaudeClient.binaryPath() != nil,
            claudeAuthenticated: hasClaudeCredentials()
        )
    }

    /// Returns the path to `node` if found, else nil.
    static func nodePath() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
            "\(home)/.npm-global/bin/node",
            "\(home)/.bun/bin/node",
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        // NVM: ~/.nvm/versions/node/<version>/bin/node — pick newest
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            for v in entries.sorted(by: >) {
                let p = "\(nvmRoot)/\(v)/bin/node"
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
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

    /// Heuristic: does Claude have stored credentials? Looks at common locations.
    /// Also accepts ANTHROPIC_API_KEY as alternative auth.
    private static func hasClaudeCredentials() -> Bool {
        let home = NSHomeDirectory()
        let paths = [
            "\(home)/.claude/.credentials.json",
            "\(home)/.config/claude/.credentials.json",
            "\(home)/Library/Application Support/Claude/credentials.json",
        ]
        for p in paths where FileManager.default.fileExists(atPath: p) {
            return true
        }
        // Also check macOS Keychain via env var passthrough (some users export it)
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
           !key.isEmpty {
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

    /// Installs Claude CLI by running `npm install -g @anthropic-ai/claude-code`
    /// in a Terminal window. We use a .command file rather than AppleScript so
    /// we don't trigger an AppleEvents permission prompt.
    static func installClaude() {
        let npm = SetupChecks.npmPath() ?? "npm"
        let cmd = """
        clear
        echo "Installing Claude Code…"
        echo
        \"\(npm)\" install -g @anthropic-ai/claude-code
        STATUS=$?
        if [ $STATUS -eq 0 ]; then
            echo
            echo "✓ Installed. You can close this window — Cue will detect it."
        else
            echo
            echo "Install failed. If permission was denied, run:"
            echo "  sudo \(npm) install -g @anthropic-ai/claude-code"
        fi
        """
        runInTerminal(cmd, title: "Install Claude")
    }

    /// Opens Terminal to start Claude's interactive OAuth flow.
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
        // PATH augmentation so the script can find npm / claude wherever they live.
        let pathAdditions = [
            "\(home)/.npm-global/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
        ]
        let script = """
        #!/bin/bash
        export PATH="\(pathAdditions.joined(separator: ":")):$PATH"
        # Title the window
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
