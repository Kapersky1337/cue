import Cocoa
import SwiftUI
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
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
        NSLog("[Cue] launched. AX granted=\(trusted)  onboarded=\(Settings.hasCompletedOnboarding)")

        setupStatusItem()
        panelController = CaretPanelController()
        hotkeyMonitor = HotkeyMonitor { [weak self] in
            NSLog("[Cue] hotkey fired")
            self?.flashStatusItem()
            self?.panelController.toggle()
        }

        // Onboarding shows once, ever — based on the persisted flag. We never re-trigger
        // it on launch or pop the system AX dialog out of context. Returning users who
        // need to repair permissions can use the menubar's "Show Onboarding…" item.
        if !Settings.hasCompletedOnboarding {
            presentOnboarding()
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

    private func promptAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - Menubar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let icon = loadMenubarIcon() {
                NSLog("[Cue] menubar icon loaded size=\(icon.size)")
                button.image = icon
                button.imagePosition = .imageOnly
            } else {
                NSLog("[Cue] menubar icon FAILED — falling back to ◐")
                button.title = "◐"
            }
            button.toolTip = "Cue — double-tap right ⌘"
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let summon = NSMenuItem(title: "Summon Cue", action: #selector(summon), keyEquivalent: "")
        summon.target = self
        menu.addItem(summon)

        menu.addItem(.separator())

        // Model picker
        let modelHeader = NSMenuItem()
        modelHeader.attributedTitle = NSAttributedString(
            string: "Model",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        modelHeader.isEnabled = false
        menu.addItem(modelHeader)

        for model in CueModel.allCases {
            let title = "\(model.displayName)  ·  \(model.subtitle)"
            let item = NSMenuItem(title: title, action: #selector(selectModel(_:)), keyEquivalent: "")
            item.representedObject = model.rawValue
            item.target = self
            item.state = (Settings.model == model) ? .on : .off
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

        statusItem.menu = menu
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

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let model = CueModel(rawValue: raw) else { return }
        Settings.model = model
        rebuildMenu()
        NSLog("[Cue] model set to \(model.rawValue)")
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

        // Open the Accessibility pane
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        // Trigger fresh AX prompt (adds Cue to the list if it's not there)
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
}
