import Cocoa
import Carbon.HIToolbox

/// Summons Cue. Two independent activation paths, because "the hotkey didn't work"
/// is the one bug this product cannot have:
///
/// 1. **Double-tap Right ⌘** — a listen-only CGEventTap on flagsChanged. Chosen over
///    NSEvent global monitors because a tap's creation *fails loudly* without
///    Accessibility (monitors return a live-looking object that never fires), it sees
///    events in our own windows, and when macOS disables it on timeout we get told
///    and re-enable. Right ⌘ is detected via its device bit (0x10), not the generic
///    .command flag, so holding left ⌘ can't wedge the state machine.
/// 2. **⇧⌥Space** — a Carbon RegisterEventHotKey, which needs *no permissions at all*.
///    Even a user who never grants Accessibility can summon Cue (capture/paste stay
///    degraded until they do, but the app is alive and visibly working).
///    ⇧⌥ specifically because plain ⌥Space is Raycast's and Alfred's default, and
///    ⌃Space / ⌃⌥Space are macOS input-source switching.
///
/// `health` reports which path is live so the menubar can say so instead of looking
/// fine and doing nothing.
final class HotkeyMonitor {
    enum Health {
        /// CGEventTap live — the double-tap works everywhere.
        case active
        /// Tap creation failed but NSEvent monitors are in (rare; AX present but tap denied).
        case fallback
        /// No Accessibility — only ⇧⌥Space works.
        case noPermission
    }

    private static let rightCommandKeyCode: UInt16 = 54
    private static let rightCommandDeviceBit: UInt64 = 0x10 // NX_DEVICERCMDKEYMASK

    private let onTrigger: () -> Void
    private let doubleTapWindow: TimeInterval = 0.35
    private var lastPressAt: Date = .distantPast
    private var rightCommandDown = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var carbonHotKey: EventHotKeyRef?
    private var carbonHandler: EventHandlerRef?

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        registerFallbackHotkey()
    }

    var health: Health {
        if eventTap != nil { return .active }
        if globalMonitor != nil { return .fallback }
        return .noPermission
    }

    /// (Re)install the double-tap listener. Safe to call repeatedly — the trust
    /// watchdog calls this whenever Accessibility state changes.
    func start() {
        stop()
        if AXIsProcessTrusted(), installTap() {
            NSLog("[Cue] hotkey: CGEventTap installed")
            return
        }
        installMonitors()
        NSLog("[Cue] hotkey: tap unavailable (AX trusted=\(AXIsProcessTrusted())) — NSEvent fallback \(globalMonitor == nil ? "FAILED" : "installed"); ⇧⌥Space always live")
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    // MARK: - CGEventTap path

    private func installTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                // macOS pauses taps it thinks are slow. Ours does no work, so resume.
                monitor.reenableTap()
            case .flagsChanged:
                monitor.handleFlagsChanged(
                    keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                    rightCommandIsDown: event.flags.rawValue & HotkeyMonitor.rightCommandDeviceBit != 0
                )
            default:
                break
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        return true
    }

    private func reenableTap() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("[Cue] hotkey: tap was disabled by macOS — re-enabled")
    }

    // MARK: - NSEvent fallback path

    private func installMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleNSEvent(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleNSEvent(event)
            return event
        }
    }

    private func handleNSEvent(_ event: NSEvent) {
        handleFlagsChanged(
            keyCode: event.keyCode,
            rightCommandIsDown: event.modifierFlags.rawValue & UInt(Self.rightCommandDeviceBit) != 0
        )
    }

    // MARK: - Carbon ⇧⌥Space path (no permissions required)

    private func registerFallbackHotkey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handler: EventHandlerUPP = { _, _, refcon in
            guard let refcon = refcon else { return noErr }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async { monitor.fire() }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(), handler, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &carbonHandler
        )
        let hotKeyID = EventHotKeyID(signature: OSType(0x4355_4521) /* 'CUE!' */, id: 1)
        let status = RegisterEventHotKey(
            UInt32(kVK_Space), UInt32(optionKey | shiftKey), hotKeyID,
            GetApplicationEventTarget(), 0, &carbonHotKey
        )
        // eventHotKeyExistsErr (-9878) = another app owns this combo — worth knowing in logs.
        NSLog("[Cue] hotkey: ⇧⌥Space registered (status=\(status)\(status == -9878 ? " — TAKEN by another app" : ""))")
    }

    // MARK: - Double-tap detection

    private func handleFlagsChanged(keyCode: UInt16, rightCommandIsDown: Bool) {
        guard keyCode == Self.rightCommandKeyCode else { return }
        defer { rightCommandDown = rightCommandIsDown }
        guard rightCommandIsDown, !rightCommandDown else { return }

        let now = Date()
        if now.timeIntervalSince(lastPressAt) < doubleTapWindow {
            lastPressAt = .distantPast
            NSLog("[Cue] double-tap right ⌘ detected")
            DispatchQueue.main.async { [weak self] in self?.fire() }
        } else {
            lastPressAt = now
        }
    }

    private func fire() {
        onTrigger()
    }
}
