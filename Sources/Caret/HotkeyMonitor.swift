import Cocoa

/// Detects a double-tap of the **Right Command** key globally.
/// keyCode 54 = Right Command. Chosen because:
///  - No common macOS app binds it (avoids Cursor / Raycast / Spotlight collisions).
///  - Present on every Apple keyboard.
///  - Right Option (61) collides with Cursor's AI panel; Left Option (58) does too.
final class HotkeyMonitor {
    private static let triggerKeyCodes: Set<UInt16> = [54] // right Command only
    private let onTrigger: () -> Void
    private let doubleTapWindow: TimeInterval = 0.35
    private var lastPressAt: Date = .distantPast
    private var modifierDown = false
    private var monitor: Any?

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
    }

    func start() {
        // Tear down any prior monitor so we don't leak when restarting.
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
        NSLog("[Cue] hotkey monitor start: \(monitor == nil ? "NIL (no AX permission)" : "INSTALLED")")
    }

    func stop() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        // Uncomment for verbose event tracing:
        // NSLog("[Cue] flagsChanged keyCode=\(event.keyCode) flags=0x\(String(event.modifierFlags.rawValue, radix: 16))")
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
