import Cocoa
import SwiftUI

/// A borderless panel that can still become key so its TextField can take focus.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CaretPanelController {
    private var panel: NSPanel?

    func toggle() {
        if panel != nil { hide() } else { show() }
    }

    private var currentAnchor: CaretLocation?

    func show() {
        let context = TextInserter.captureContext()
        let anchor = CursorLocator.shared.findAnchor()
        currentAnchor = anchor

        let vm = CaretViewModel(
            context: context,
            onDismiss: { [weak self] in self?.hide() },
            onResize: { [weak self] size in self?.resizePanel(to: size) }
        )
        let root = CaretInputView(viewModel: vm)
        let hosting = NSHostingController(rootView: root)
        hosting.view.setFrameSize(NSSize(width: 520, height: 44))

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.worksWhenModal = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentViewController = hosting

        let origin = panelOrigin(for: anchor, panelSize: NSSize(width: 520, height: 44))
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel
    }

    private func resizePanel(to size: CGSize) {
        guard let panel = panel, let anchor = currentAnchor else { return }
        let newSize = NSSize(width: size.width, height: size.height)
        let newOrigin = panelOrigin(for: anchor, panelSize: newSize)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(NSRect(origin: newOrigin, size: newSize), display: true)
        }
        panel.contentViewController?.view.setFrameSize(newSize)
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        // Return focus to the previous app — handled by the activation hop in TextInserter when needed.
    }

    /// Predictable home for the panel: horizontally centered, vertically slightly above the
    /// middle of the screen with a floor that keeps the panel clear of the field zone.
    ///
    /// The math:
    ///   - **Default**: panel TOP sits at 50% from screen bottom (just above center).
    ///     Short panels end up around 45–50% — close to the text field but not on top of it.
    ///   - **Floor**: panel BOTTOM never goes below 35% from screen bottom. So when the
    ///     response area expands or chat mode opens, the panel grows upward — never down
    ///     into the bottom 35% where compose boxes typically live.
    ///   - **Ceiling**: panel TOP clamps to `visible.maxY - 8`. Tall panels on small screens
    ///     stay on-screen.
    private func panelOrigin(for anchor: CaretLocation, panelSize: NSSize) -> NSPoint {
        let activeScreen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first!
        let visible = activeScreen.visibleFrame

        let x = visible.midX - panelSize.width / 2

        let preferredTopY = visible.minY + visible.height * 0.50
        let bottomFloor = visible.minY + visible.height * 0.35
        let topCeiling = visible.maxY - 8

        var y = preferredTopY - panelSize.height // panel's bottom-left origin
        if y < bottomFloor { y = bottomFloor }
        if y + panelSize.height > topCeiling { y = topCeiling - panelSize.height }
        y = max(visible.minY + 8, y)

        return NSPoint(x: x, y: y)
    }
}
