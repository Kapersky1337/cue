import Cocoa

/// Detects a double-tap of the **Right Command** key globally.
/// keyCode 54 = Right Command. Chosen because:
///  - No common macOS app binds it (avoids Cursor / Raycast / Spotlight collisions).
///  - Present on every Apple keyboard.
///  - Right Option (61) collides with Cursor's AI panel; Left Option (58) does too.
///
/// Two monitors are required: the global monitor never receives events delivered to
/// our own app, so without the local one the hotkey is dead over Cue's own windows —
/// including the onboarding "try it" field.
final class HotkeyMonitor {
    private static let triggerKeyCodes: Set<UInt16> = [54] // right Command only
    private let onTrigger: () -> Void
    private let doubleTapWindow: TimeInterval = 0.35
    private var lastPressAt: Date = .distantPast
    private var modifierDown = false
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
    }

    func start() {
        stop() // tear down any prior monitors so restarts don't leak
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
        NSLog("[Cue] hotkey monitor start: global=\(globalMonitor == nil ? "NIL (no AX permission)" : "on") local=on")
    }

    func stop() {
        if let m = globalMonitor {
            NSEvent.removeMonitor(m)
            globalMonitor = nil
        }
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
            localMonitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        guard Self.triggerKeyCodes.contains(event.keyCode) else { return }
        let isDown = event.modifierFlags.contains(.command)
        defer { modifierDown = isDown }
        guard isDown, !modifierDown else { return }

        let now = Date()
        if now.timeIntervalSince(lastPressAt) < doubleTapWindow {
            lastPressAt = .distantPast
            NSLog("[Cue] double-tap right ⌘ detected")
            DispatchQueue.main.async { [weak self] in self?.onTrigger() }
        } else {
            lastPressAt = now
        }
    }
}
