import Cocoa
import ApplicationServices

struct TextContext {
    let appName: String?
    let bundleID: String?
    let windowTitle: String?
    /// Full text of the focused field, if readable.
    let fieldText: String?
    /// Currently selected substring inside the focused field (if any).
    let selectedText: String?
    /// All visible text in the focused window, walked from the AX tree.
    /// Works in Slack/Discord/Electron where the focused field alone returns nothing.
    let windowText: String?
    let pid: pid_t?

    var hasMeaningfulContext: Bool {
        (fieldText?.isEmpty == false)
            || (selectedText?.isEmpty == false)
            || (windowText?.isEmpty == false)
    }

    /// Best single context string for showing the user what we captured (length).
    var contextLength: Int {
        selectedText?.count ?? fieldText?.count ?? windowText?.count ?? 0
    }
}

enum TextInserter {
    private static let maxFieldChars = 6_000
    private static let maxWindowChars = 10_000
    private static let maxTreeDepth = 14
    private static let maxTreeNodes = 4_000

    static func captureContext() -> TextContext {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let appName = frontApp?.localizedName
        let bundleID = frontApp?.bundleIdentifier
        let pid = frontApp?.processIdentifier

        // CRITICAL for Electron apps (Slack, Discord, VSCode, Cursor):
        // they only build a real accessibility tree once an a11y client signals
        // it wants one. Setting AXEnhancedUserInterface = true forces this.
        if let pid = pid {
            let appEl = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            // Give Electron a beat to actually build the tree.
            Thread.sleep(forTimeInterval: 0.06)
        }

        var windowTitle: String?
        var fieldText: String?
        var selectedText: String?
        var focusedWindow: AXUIElement?

        // Focused element (the text field/area the caret is in)
        let system = AXUIElementCreateSystemWide()
        var focusedRef: AnyObject?
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let value = focusedRef {
            let el = value as! AXUIElement

            // Full value of the field (works in native AppKit, sometimes in Electron)
            var valueRef: AnyObject?
            if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &valueRef) == .success,
               let raw = valueRef as? String, !raw.isEmpty {
                fieldText = raw.count > maxFieldChars
                    ? String(raw.suffix(maxFieldChars))
                    : raw
            }

            // Selected substring
            var selRef: AnyObject?
            if AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &selRef) == .success,
               let sel = selRef as? String, !sel.isEmpty {
                selectedText = sel
            }

            // Find the parent window
            var windowRef: AnyObject?
            if AXUIElementCopyAttributeValue(el, kAXWindowAttribute as CFString, &windowRef) == .success,
               let win = windowRef {
                focusedWindow = (win as! AXUIElement)
            }
        }

        // Fallback: app's focused window
        if focusedWindow == nil, let pid = pid {
            let appEl = AXUIElementCreateApplication(pid)
            var winRef: AnyObject?
            if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
               let win = winRef {
                focusedWindow = (win as! AXUIElement)
            }
        }

        // Window title
        if let win = focusedWindow {
            var titleRef: AnyObject?
            if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String, !title.isEmpty {
                windowTitle = title
            }
        }

        // Walk the focused window's AX tree to harvest visible text (best-effort for native apps).
        var windowText: String?
        if let win = focusedWindow {
            let collected = collectText(from: win)
            if !collected.isEmpty {
                windowText = collected.count > maxWindowChars
                    ? String(collected.suffix(maxWindowChars))
                    : collected
            }
        }

        // FALLBACK for Electron/Slack/Discord/etc. where AX returns nothing useful.
        // ⌘A + ⌘C universally works in any editable text surface on macOS.
        // We do this ONLY when AX has given us nothing, since it's mildly destructive
        // (selects all the text — which is actually a great visual confirmation of
        // "this is what I'm transforming" anyway).
        if (fieldText?.isEmpty ?? true) && (selectedText?.isEmpty ?? true) {
            if let captured = captureFieldViaSelection() {
                fieldText = captured.count > maxFieldChars
                    ? String(captured.suffix(maxFieldChars))
                    : captured
            }
        }

        NSLog("[Caret] context app=\(appName ?? "?") field=\(fieldText?.count ?? 0)c sel=\(selectedText?.count ?? 0)c window=\(windowText?.count ?? 0)c title=\(windowTitle ?? "?")")

        return TextContext(
            appName: appName,
            bundleID: bundleID,
            windowTitle: windowTitle,
            fieldText: fieldText,
            selectedText: selectedText,
            windowText: windowText,
            pid: pid
        )
    }

    /// Universal fallback: select-all + copy in the focused field, read the pasteboard,
    /// then restore the prior clipboard. Works in any app because every editable surface
    /// supports ⌘A and ⌘C. Leaves the field's text selected, which is desired — the
    /// user sees what's about to be transformed, and ⌘V on commit replaces it cleanly.
    private static func captureFieldViaSelection() -> String? {
        let pasteboard = NSPasteboard.general
        let savedString = pasteboard.string(forType: .string)
        let savedChangeCount = pasteboard.changeCount

        // Use a sentinel so we can detect "nothing was copied" reliably even when the
        // field was empty (changeCount won't increment if there was nothing to copy).
        let sentinel = "__caret_sentinel_\(UUID().uuidString)__"
        pasteboard.clearContents()
        pasteboard.setString(sentinel, forType: .string)
        let postSentinelChange = pasteboard.changeCount

        // ⌘A (keyCode 0 = 'a'), ⌘C (keyCode 8 = 'c')
        sendCmdKey(0x00)
        usleep(35_000) // 35ms
        sendCmdKey(0x08)
        usleep(80_000) // 80ms — let the app populate the pasteboard

        let captured = pasteboard.string(forType: .string)

        // Restore previous clipboard
        pasteboard.clearContents()
        if let saved = savedString {
            pasteboard.setString(saved, forType: .string)
        }
        _ = (savedChangeCount, postSentinelChange)

        if let captured = captured, captured != sentinel, !captured.isEmpty {
            return captured
        }
        return nil
    }

    private static func sendCmdKey(_ keyCode: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Recursively gather text from an AX subtree. Limits depth and node count so we
    /// don't burn time on huge web views. Preserves visual order via DFS.
    private static func collectText(from root: AXUIElement) -> String {
        var collected = ""
        var nodesVisited = 0

        func valueString(_ el: AXUIElement) -> String? {
            var ref: AnyObject?
            guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &ref) == .success else { return nil }
            if let s = ref as? String, !s.isEmpty { return s }
            return nil
        }
        func descriptionString(_ el: AXUIElement) -> String? {
            var ref: AnyObject?
            guard AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &ref) == .success else { return nil }
            if let s = ref as? String, !s.isEmpty { return s }
            return nil
        }
        func titleString(_ el: AXUIElement) -> String? {
            var ref: AnyObject?
            guard AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &ref) == .success else { return nil }
            if let s = ref as? String, !s.isEmpty { return s }
            return nil
        }

        func walk(_ el: AXUIElement, depth: Int) {
            if collected.count >= maxWindowChars { return }
            if depth > maxTreeDepth { return }
            nodesVisited += 1
            if nodesVisited > maxTreeNodes { return }

            var roleRef: AnyObject?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
            let role = (roleRef as? String) ?? ""

            // Roles that carry user-visible text we want
            let textRoles: Set<String> = [
                "AXStaticText", "AXTextField", "AXTextArea",
                "AXLink", "AXHeading", "AXCell", "AXRow"
            ]

            if textRoles.contains(role) {
                if let v = valueString(el) ?? descriptionString(el) ?? titleString(el) {
                    collected += v
                    if !collected.hasSuffix("\n") { collected += "\n" }
                }
            } else if role == "AXButton" || role == "AXMenuItem" {
                if let t = titleString(el), t.count > 2, t.count < 80 {
                    collected += t + "\n"
                }
            } else if role == "AXGroup" || role == "AXGenericElement" || role == "" {
                // Slack/Electron wraps text in generic groups. Try to pull a value/description
                // directly off the group if it carries one, in addition to recursing.
                if let v = valueString(el), v.count >= 2, v.count < 4000 {
                    collected += v
                    if !collected.hasSuffix("\n") { collected += "\n" }
                } else if let d = descriptionString(el), d.count >= 2, d.count < 4000 {
                    collected += d
                    if !collected.hasSuffix("\n") { collected += "\n" }
                }
            }

            var childrenRef: AnyObject?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for child in children {
                    walk(child, depth: depth + 1)
                    if collected.count >= maxWindowChars { return }
                    if nodesVisited > maxTreeNodes { return }
                }
            }
        }

        walk(root, depth: 0)
        return collected
    }

    /// Replace the entire field content with `text`.
    /// Refocus source app → ⌘A (select all) → ⌘V (paste). Clipboard restored after.
    /// Works in every editable surface because every text field supports ⌘A and ⌘V.
    static func replaceField(with text: String, in context: TextContext) {
        NSLog("[Caret] replaceField called, len=\(text.count) target=\(context.appName ?? "?") pid=\(context.pid.map { String($0) } ?? "?")")
        let pasteboard = NSPasteboard.general
        let savedString = pasteboard.string(forType: .string)
        let savedChangeCount = pasteboard.changeCount

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        if let pid = context.pid,
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [])
            NSLog("[Caret] activated source app pid=\(pid)")
        } else {
            NSLog("[Caret] WARNING: no pid to activate — paste will go to whatever has focus")
        }

        // Give the source app a beat to regain focus before we synthesize keys.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
            NSLog("[Caret] sending ⌘A")
            sendCmdKey(0x00) // ⌘A
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                NSLog("[Caret] sending ⌘V")
                sendCmdKey(0x09) // ⌘V
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if pasteboard.changeCount == savedChangeCount + 1 {
                        pasteboard.clearContents()
                        if let saved = savedString {
                            pasteboard.setString(saved, forType: .string)
                        }
                    }
                }
            }
        }
    }

    /// Append `text` to whatever is already in the field, with a single newline of separation.
    /// Refocus source app → right-arrow (collapses any selection to its end, putting cursor
    /// at the end of existing content) → ⌘V.
    static func appendToField(_ text: String, in context: TextContext) {
        NSLog("[Caret] appendToField called, len=\(text.count)")
        let pasteboard = NSPasteboard.general
        let savedString = pasteboard.string(forType: .string)
        let savedChangeCount = pasteboard.changeCount

        // Add a separating newline only if there was existing content.
        let hadContent = !(context.fieldText?.isEmpty ?? true) || !(context.selectedText?.isEmpty ?? true)
        let payload = hadContent ? "\n" + text : text

        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)

        if let pid = context.pid,
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [])
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
            // Right arrow with no modifier collapses selection to its end.
            // After our prior ⌘A+⌘C capture, this puts the cursor at the very end of the field.
            sendKey(0x7C, modifiers: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                sendCmdKey(0x09) // ⌘V
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if pasteboard.changeCount == savedChangeCount + 1 {
                        pasteboard.clearContents()
                        if let saved = savedString {
                            pasteboard.setString(saved, forType: .string)
                        }
                    }
                }
            }
        }
    }

    private static func sendKey(_ keyCode: CGKeyCode, modifiers: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        down?.flags = modifiers
        up?.flags = modifiers
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Copy without inserting (for ⌘C action from the panel).
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

}
