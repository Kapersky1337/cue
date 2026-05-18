import Cocoa
import ApplicationServices

struct CaretLocation {
    /// Cocoa-space point: bottom-left origin of the originating rect (field or window).
    let cocoaPoint: NSPoint
    /// Height of the originating rect.
    let height: CGFloat
    /// What kind of anchor we found — informs positioning policy.
    let kind: Kind

    enum Kind { case caret, fieldFrame, windowBottom, mouse }
}

final class CursorLocator {
    static let shared = CursorLocator()

    /// Returns the best screen-space anchor for placing the Caret panel.
    /// Priority:
    ///   1. AX caret rect (native AppKit text fields)
    ///   2. AX focused element frame (most native apps)
    ///   3. Bottom edge of the focused window (Slack/Discord/Electron — where AX gives garbage on the field)
    ///   4. Mouse position (last resort)
    func findAnchor() -> CaretLocation {
        if let rect = caretRect(), rect.width.isFinite, rect.height > 0 {
            NSLog("[Caret] anchor=caret rect=\(rect)")
            return cocoaLocation(from: rect, kind: .caret)
        }
        if let rect = focusedElementFrame(), rect.width > 20, rect.height > 4 {
            NSLog("[Caret] anchor=fieldFrame rect=\(rect)")
            return cocoaLocation(from: rect, kind: .fieldFrame)
        }
        if let rect = focusedWindowFrame() {
            // Synthesize an anchor at the bottom-center of the window so the panel
            // appears just above the area where compose boxes typically live.
            let anchor = CGRect(
                x: rect.midX - 100,
                y: rect.maxY - 60, // ~60px from the window's bottom (in Quartz)
                width: 200,
                height: 30
            )
            NSLog("[Caret] anchor=windowBottom window=\(rect) synthesized=\(anchor)")
            return cocoaLocation(from: anchor, kind: .windowBottom)
        }
        let mouse = NSEvent.mouseLocation
        NSLog("[Caret] anchor=mouse \(mouse)")
        return CaretLocation(cocoaPoint: NSPoint(x: mouse.x - 80, y: mouse.y - 24), height: 0, kind: .mouse)
    }

    // MARK: - AX queries

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let value = ref else { return nil }
        return (value as! AXUIElement)
    }

    private func caretRect() -> CGRect? {
        guard let el = focusedElement() else { return nil }
        var rangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let range = rangeRef else { return nil }
        var boundsRef: AnyObject?
        let err = AXUIElementCopyParameterizedAttributeValue(
            el, kAXBoundsForRangeParameterizedAttribute as CFString, range, &boundsRef
        )
        guard err == .success, let bounds = boundsRef else { return nil }
        var rect = CGRect.zero
        AXValueGetValue(bounds as! AXValue, .cgRect, &rect)
        return rect
    }

    private func focusedElementFrame() -> CGRect? {
        guard let el = focusedElement() else { return nil }
        return frame(of: el)
    }

    private func focusedWindowFrame() -> CGRect? {
        // Try the focused element's window first
        if let el = focusedElement() {
            var winRef: AnyObject?
            if AXUIElementCopyAttributeValue(el, kAXWindowAttribute as CFString, &winRef) == .success,
               let win = winRef {
                if let frame = frame(of: win as! AXUIElement) { return frame }
            }
        }
        // Fallback: frontmost app's focused window
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let appEl = AXUIElementCreateApplication(pid)
        var winRef: AnyObject?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let win = winRef else { return nil }
        return frame(of: win as! AXUIElement)
    }

    private func frame(of el: AXUIElement) -> CGRect? {
        var posRef: AnyObject?
        var sizeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posV = posRef, let sizeV = sizeRef else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posV as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeV as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// AX → Cocoa coords. Returns the rect's bottom-left in Cocoa space.
    private func cocoaLocation(from quartzRect: CGRect, kind: CaretLocation.Kind) -> CaretLocation {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let bottomQuartz = quartzRect.origin.y + quartzRect.height
        let cocoaY = primaryHeight - bottomQuartz
        return CaretLocation(
            cocoaPoint: NSPoint(x: quartzRect.origin.x, y: cocoaY),
            height: quartzRect.height,
            kind: kind
        )
    }
}
