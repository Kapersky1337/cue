import Cocoa
import SwiftUI
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var hotkeyMonitor: HotkeyMonitor!
    private var panelController: CaretPanelController!
    private var onboardingController: OnboardingWindowController?

    /// Cue is a menubar-only (accessory) app — closing windows is never a quit signal.
    /// macOS's default for this varies across versions; pinning it to false ensures the
    /// menubar icon stays alive even when the user clicks × on the onboarding window or
    /// dismisses any other panel.
    @objc func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        NSLog("[Cue] applicationShouldTerminateAfterLastWindowClosed → returning false (keep alive)")
        return false
    }

    /// If we ever see this log line on × click, something is explicitly terminating us.
    /// Without an explicit terminate call, accessory apps stay alive when windows close.
    func applicationWillTerminate(_ notification: Notification) {
        NSLog("[Cue] applicationWillTerminate — app is about to die")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let trusted = AccessibilityCheck.isReallyGranted()
        NSLog("[Cue] launched. AX granted=\(trusted)  onboarded=\(Settings.hasCompletedOnboarding)  provider=\(Settings.provider.rawValue)")

        setupStatusItem()
        panelController = CaretPanelController()
        hotkeyMonitor = HotkeyMonitor { [weak self] in
            NSLog("[Cue] hotkey fired")
            self?.flashStatusItem()
            self?.panelController.toggle()
        }

        // Onboarding posts this the moment accessibility flips to granted, so the hotkey
        // works during the "try it" step instead of only after finishing.
        NotificationCenter.default.addObserver(
            forName: .cueAccessibilityGranted, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                NSLog("[Cue] accessibility granted mid-onboarding — starting hotkey monitor")
                self?.hotkeyMonitor.start()
            }
        }

        // Onboarding shows once, ever — based on the persisted flag. We never re-trigger
        // it on launch or pop the system AX dialog out of context. Returning users who
        // need to repair permissions can use the menubar's "Show Onboarding…" item.
        if !Settings.hasCompletedOnboarding {
            presentOnboarding()
            if trusted { hotkeyMonitor.start() } // re-running onboarding on a granted machine
        } else {
            hotkeyMonitor.start()
        }
    }

    private func presentOnboarding() {
        onboardingController = OnboardingWindowController { [weak self] in
            Settings.hasCompletedOnboarding = true
            self?.hotkeyMonitor.start()
            NSLog("[Cue] onboarding complete; hotkey monitor active")
        }
        onboardingController?.show()
    }

    /// Launches a fresh Cue instance via launchd and terminates the current one.
    /// Uses NSWorkspace (not Process) so the new instance is detached from our lifetime.
    /// Exposed in the menubar as "Relaunch Cue" for users who hit the rare case where
    /// the global hotkey monitor was registered in a process that didn't yet see AX trust.
    /// If launchd refuses for any reason, falls back to starting the monitor in-place so
    /// the user is never left with a non-functional app.
    @objc func relaunchCue() {
        let url = URL(fileURLWithPath: Bundle.main.bundlePath)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = false
        config.addsToRecentItems = false
        NSLog("[Cue] requesting launchd relaunch of \(url.path)")
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error = error {
                    NSLog("[Cue] launchd relaunch FAILED: \(error.localizedDescription) — falling back to in-place start")
                    self?.hotkeyMonitor.start()
                    return
                }
                NSLog("[Cue] new instance launched; terminating current in 400ms")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: - Menubar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let icon = loadMenubarIcon() {
                button.image = icon
                button.imagePosition = .imageOnly
            } else {
                NSLog("[Cue] menubar icon FAILED — falling back to ◐")
                button.title = "◐"
            }
            button.toolTip = "Cue — double-tap right ⌘"
        }
        let menu = NSMenu()
        menu.delegate = self // rebuild on every open so provider detection stays fresh
        statusItem.menu = menu
    }

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            rebuildMenu(menu)
        }
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let summon = NSMenuItem(title: "Summon Cue", action: #selector(summon), keyEquivalent: "")
        summon.target = self
        menu.addItem(summon)

        menu.addItem(.separator())

        let engineHeader = NSMenuItem()
        engineHeader.attributedTitle = NSAttributedString(
            string: "Engine",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        engineHeader.isEnabled = false
        menu.addItem(engineHeader)

        let detected = Provider.detected()
        let active = Settings.provider

        for provider in Provider.allCases {
            let isDetected = detected.contains(provider)
            let item = NSMenuItem(
                title: isDetected ? provider.displayName : "\(provider.displayName)  ·  not installed",
                action: isDetected ? #selector(selectProvider(_:)) : nil,
                keyEquivalent: ""
            )
            item.representedObject = provider.rawValue
            item.target = isDetected ? self : nil
            item.isEnabled = isDetected
            item.state = (isDetected && active == provider) ? .on : .off

            if isDetected, let submenu = modelSubmenu(for: provider) {
                item.submenu = submenu
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let fixPermsItem = NSMenuItem(title: "Fix Permissions…", action: #selector(fixPermissions), keyEquivalent: "")
        fixPermsItem.target = self
        menu.addItem(fixPermsItem)

        let onboardingItem = NSMenuItem(title: "Show Onboarding…", action: #selector(showOnboardingAgain), keyEquivalent: "")
        onboardingItem.target = self
        menu.addItem(onboardingItem)

        let relaunchItem = NSMenuItem(title: "Relaunch Cue", action: #selector(relaunchCue), keyEquivalent: "r")
        relaunchItem.target = self
        menu.addItem(relaunchItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Cue", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Model picker submenu. Claude gets its three tiers; Ollama lists installed models;
    /// Codex and Gemini run their CLI-default model, so no submenu.
    private func modelSubmenu(for provider: Provider) -> NSMenu? {
        switch provider {
        case .claude:
            let submenu = NSMenu()
            for model in Provider.claudeModels {
                let item = NSMenuItem(
                    title: "\(model.name)  ·  \(model.subtitle)",
                    action: #selector(selectClaudeModel(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = model.id
                item.target = self
                item.state = (Settings.claudeModel == model.id) ? .on : .off
                submenu.addItem(item)
            }
            return submenu
        case .ollama:
            let models = Provider.ollamaModels()
            guard !models.isEmpty else { return nil }
            let submenu = NSMenu()
            for model in models {
                let item = NSMenuItem(title: model, action: #selector(selectOllamaModel(_:)), keyEquivalent: "")
                item.representedObject = model
                item.target = self
                item.state = (Settings.ollamaModel == model) ? .on : .off
                submenu.addItem(item)
            }
            return submenu
        case .codex, .gemini:
            return nil
        }
    }

    /// Renders the Caret symbol (no rounded-square background) as a template NSImage
    /// so the menubar handles light/dark inversion. Falls back to the full bundled icns
    /// if rendering fails for any reason.
    private func loadMenubarIcon() -> NSImage? {
        let renderer = ImageRenderer(
            content: CaretMark(color: .black)
                .frame(width: 18, height: 18)
                .padding(1)
        )
        renderer.scale = 2.0
        if let nsImage = renderer.nsImage {
            nsImage.isTemplate = true
            return nsImage
        }
        if let url = Bundle.main.url(forResource: "Caret", withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            img.size = NSSize(width: 18, height: 18)
            return img
        }
        return nil
    }

    private func flashStatusItem() {
        guard let button = statusItem.button else { return }
        let originalAlpha = button.alphaValue
        button.alphaValue = 0.35
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            button.alphaValue = originalAlpha
        }
    }

    // MARK: - Actions

    @objc private func summon() {
        panelController.toggle()
    }

    @objc private func selectProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let provider = Provider(rawValue: raw) else { return }
        Settings.provider = provider
        NSLog("[Cue] provider set to \(provider.rawValue)")
    }

    @objc private func selectClaudeModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.provider = .claude
        Settings.claudeModel = id
        NSLog("[Cue] claude model set to \(id)")
    }

    @objc private func selectOllamaModel(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? String else { return }
        Settings.provider = .ollama
        Settings.ollamaModel = model
        NSLog("[Cue] ollama model set to \(model)")
    }

    @objc private func showOnboardingAgain() {
        presentOnboarding()
    }

    /// Walks the user through repairing accessibility access — handles the stale-TCC-binding
    /// case that happens with ad-hoc-signed apps after a rebuild. Shows a clear explanation,
    /// opens the Accessibility pane, and triggers the macOS consent dialog so a fresh entry
    /// can be added.
    @objc private func fixPermissions() {
        let alert = NSAlert()
        alert.messageText = "Repair Cue's Accessibility access"
        alert.informativeText = """
        Cue's permission can go stale after a rebuild. To repair:

        1. In the Accessibility list, find Cue and click the – (minus) button to remove it.
        2. Click Continue below — Cue will trigger a fresh permission prompt.
        3. Toggle Cue on when it appears, then relaunch Cue from the menubar.
        """
        alert.addButton(withTitle: "Open Settings & Continue")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
}
