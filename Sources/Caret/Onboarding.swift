import SwiftUI
import Cocoa
import ApplicationServices

// MARK: - Window

@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func show() {
        let root = OnboardingView { [weak self] in
            self?.dismiss()
            self?.onFinish()
        }
        let hosting = NSHostingController(rootView: root)

        // Note: we deliberately do NOT use `.fullSizeContentView` here.
        // With it on, the SwiftUI content extends under the titlebar and intercepts
        // clicks meant for the close button. Standard titlebar separation makes the
        // traffic-light buttons work correctly with zero hit-testing acrobatics.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 528),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.center()
        window.level = .floating
        // Do NOT release the window when closed — keeps the window object alive so
        // close → release → "no windows left" cascades can't fire.
        window.isReleasedWhenClosed = false

        let delegate = OnboardingWindowDelegate { [weak self] in
            NSLog("[Cue] OnboardingWindowDelegate.onClose fired — window dismissed")
            self?.window = nil
        }
        window.delegate = delegate
        self.windowDelegate = delegate

        window.makeKeyAndOrderFront(nil)
        // Intentionally NOT calling NSApp.activate(ignoringOtherApps:) — for an
        // accessory app, activating can confuse macOS's app lifecycle when the only
        // window is later closed.
        self.window = window
    }

    private func dismiss() {
        window?.close()
        window = nil
    }

    private var windowDelegate: OnboardingWindowDelegate?
}

/// Hooks the window's close button so that clicking the red X tears down the controller
/// cleanly. We don't mark onboarding complete on X-click — that would be premature.
/// User can re-open onboarding any time from the menubar.
@MainActor
final class OnboardingWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }
    nonisolated func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.onClose()
        }
    }
}

// MARK: - Root

struct OnboardingView: View {
    @State private var step: Int = 0
    @State private var setupState: SetupState = SetupChecks.current()
    let onComplete: () -> Void

    private let totalSteps = 3
    private let pollTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Vibrant blur backdrop, plus a subtle vertical gradient for depth.
            VisualEffectBackdrop()
            LinearGradient(
                colors: [
                    Color.white.opacity(0.06),
                    Color.clear,
                    Color.black.opacity(0.08)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 0) {
                Group {
                    switch step {
                    case 0: WelcomeStep(advance: advance)
                    case 1: SetupStep(state: setupState, advance: advance)
                    case 2: ReadyStep(complete: onComplete)
                    default: EmptyView()
                    }
                }
                .padding(.horizontal, 36)
                .padding(.top, 48)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(step)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(x: 12)),
                    removal: .opacity.combined(with: .offset(x: -12))
                ))

                ProgressDots(current: step, total: totalSteps)
                    .padding(.bottom, 14)

                CreditFooter()
                    .padding(.bottom, 14)
            }
        }
        .frame(width: 440, height: 528)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .onReceive(pollTimer) { _ in
            let next = SetupChecks.current()
            if next != setupState {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                    setupState = next
                }
            }
        }
    }

    private func advance() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
            step = min(step + 1, totalSteps - 1)
        }
    }
}

/// Authoritative AX trust check. Uses `AXIsProcessTrusted()` — the macOS API that
/// determines whether event taps and AX reads will actually succeed for this process.
/// We do NOT try to "verify with a real call" because that was returning false positives
/// (e.g. .success for the system-wide element even when permission was missing).
enum AccessibilityCheck {
    static func isReallyGranted() -> Bool {
        return AXIsProcessTrusted()
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    let advance: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            CaretLogo(size: 80)
                .shadow(color: .black.opacity(0.2), radius: 14, y: 6)

            VStack(spacing: 6) {
                Text("Cue")
                    .font(.system(size: 30, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundColor(.primary)
                Text("AI in every text field.")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.primary.opacity(0.55))
            }

            Text("Double-tap right ⌘ wherever you type. Ask Claude to refine, rewrite, summarize, or calculate. Paste with one keystroke.")
                .font(.system(size: 13))
                .foregroundColor(.primary.opacity(0.72))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 320)

            Spacer().frame(height: 4)
            PremiumButton(title: "Get started", action: advance)
        }
    }
}

private struct SetupStep: View {
    let state: SetupState
    let advance: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Setup")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.primary)
                Text("Three quick checks. Cue handles the rest.")
                    .font(.system(size: 12.5))
                    .foregroundColor(.primary.opacity(0.6))
            }

            VStack(spacing: 0) {
                SetupRow(
                    title: "Accessibility access",
                    subtitle: state.accessibilityGranted
                        ? "So Cue can read your text field and paste back."
                        : "In System Settings → Privacy → Accessibility, find Cue and toggle it ON. If it's already on, toggle OFF then ON to refresh.",
                    isComplete: state.accessibilityGranted,
                    actionTitle: "Open Settings",
                    action: SetupActions.openAccessibilityPane
                )
                divider()
                SetupRow(
                    title: "Claude CLI",
                    subtitle: state.nodeInstalled
                        ? "Cue uses your local Claude install."
                        : "Needs Node.js first.",
                    isComplete: state.claudeInstalled,
                    actionTitle: state.nodeInstalled ? "Install" : "Get Node",
                    action: {
                        if state.nodeInstalled {
                            SetupActions.installClaude()
                        } else {
                            SetupActions.openNodeInstall()
                        }
                    }
                )
                divider()
                SetupRow(
                    title: "Claude account",
                    subtitle: "Sign in to your Claude subscription if you haven't.",
                    isComplete: state.claudeAuthenticated,
                    actionTitle: "Sign in",
                    action: SetupActions.signInToClaude,
                    actionDisabled: !state.claudeInstalled,
                    optional: true
                )
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
            )

            Text("Auto-detects as each step completes.")
                .font(.system(size: 10.5))
                .foregroundColor(.primary.opacity(0.42))

            PremiumButton(title: "Continue", action: advance)
                .opacity(state.allReady ? 1.0 : 0.4)
                .disabled(!state.allReady)
                .animation(.easeOut(duration: 0.2), value: state.allReady)
        }
    }

    private func divider() -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.05))
            .frame(height: 0.5)
            .padding(.leading, 38)
    }
}

private struct SetupRow: View {
    let title: String
    let subtitle: String
    let isComplete: Bool
    let actionTitle: String
    let action: () -> Void
    var actionDisabled: Bool = false
    var optional: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            statusBadge

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary.opacity(isComplete ? 0.55 : 0.92))
                        .strikethrough(isComplete, color: .primary.opacity(0.35))
                    if optional, !isComplete {
                        Text("Optional")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.primary.opacity(0.45))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule().fill(Color.primary.opacity(0.08))
                            )
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.primary.opacity(0.45))
                    .lineLimit(isComplete ? 1 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if !isComplete {
                SmallActionButton(title: actionTitle, action: action, disabled: actionDisabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isComplete {
            ZStack {
                Circle().fill(Color.green.opacity(0.18))
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.green)
            }
            .frame(width: 20, height: 20)
            .transition(.scale.combined(with: .opacity))
        } else {
            Circle()
                .stroke(Color.primary.opacity(0.25), lineWidth: 1.2)
                .frame(width: 20, height: 20)
        }
    }
}

private struct SmallActionButton: View {
    let title: String
    let action: () -> Void
    var disabled: Bool = false
    @State private var hover = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(disabled
                    ? Color.primary.opacity(0.3)
                    : (scheme == .dark ? .black : .white))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(disabled
                            ? Color.primary.opacity(0.08)
                            : (scheme == .dark
                                ? Color.white.opacity(hover ? 1.0 : 0.9)
                                : Color.black.opacity(hover ? 1.0 : 0.85)))
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hover = $0 }
    }
}

private struct ReadyStep: View {
    let complete: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 8) {
                KeyCap(label: "⌘")
                Text("·")
                    .font(.system(size: 20, weight: .light))
                    .foregroundColor(.primary.opacity(0.4))
                KeyCap(label: "⌘")
            }

            VStack(spacing: 6) {
                Text("Double-tap right ⌘")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.primary)
                Text("In any text field. Cue appears. Type your instruction.")
                    .font(.system(size: 12.5))
                    .foregroundColor(.primary.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }

            VStack(alignment: .leading, spacing: 7) {
                shortcutRow("⌘↩",  "Replace field")
                shortcutRow("⌘↓",  "Append to field")
                shortcutRow("⌘C",  "Copy")
                shortcutRow("⌘E",  "Chat to iterate")
                shortcutRow("esc", "Dismiss")
            }
            .frame(maxWidth: 280)

            HStack(spacing: 6) {
                CaretLogo(size: 11)
                Text("Look top-right in your menu bar")
                    .font(.system(size: 10.5))
                    .foregroundColor(.primary.opacity(0.45))
            }

            Spacer().frame(height: 2)
            PremiumButton(title: "I'm ready", action: complete)
        }
    }

    private func shortcutRow(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 14) {
            Text(keys)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary.opacity(0.55))
                .frame(width: 42, alignment: .leading)
            Text(label)
                .font(.system(size: 12.5))
                .foregroundColor(.primary.opacity(0.78))
        }
    }
}

// MARK: - Primitives

/// Inverse-primary button: dark fill in light mode, light fill in dark mode.
/// White-on-black / black-on-white — same crisp premium look on either appearance.
private struct PremiumButton: View {
    let title: String
    let action: () -> Void
    @State private var hover = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(scheme == .dark ? .black : .white)
                .padding(.horizontal, 22)
                .padding(.vertical, 9)
                .background(
                    Capsule()
                        .fill(scheme == .dark
                              ? Color.white.opacity(hover ? 1.0 : 0.92)
                              : Color.black.opacity(hover ? 1.0 : 0.88))
                )
                .shadow(color: Color.black.opacity(hover ? 0.22 : 0.12),
                        radius: hover ? 10 : 6, y: 3)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .onHover { hover = $0 }
    }
}

private struct KeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 20, weight: .medium))
            .foregroundColor(.primary.opacity(0.85))
            .frame(width: 46, height: 46)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
    }
}

/// Tiny credit line at the bottom of the onboarding window.
private struct CreditFooter: View {
    @State private var hover = false

    var body: some View {
        Button(action: openTwitter) {
            (
                Text("Made with ")
                    .foregroundColor(.primary.opacity(0.35))
                + Text(Image(systemName: "heart.fill"))
                    .font(.system(size: 8))
                    .foregroundColor(.primary.opacity(0.42))
                + Text(" by ")
                    .foregroundColor(.primary.opacity(0.35))
                + Text("Zeel")
                    .foregroundColor(.primary.opacity(hover ? 0.85 : 0.55))
                    .underline(hover, color: .primary.opacity(0.4))
            )
            .font(.system(size: 10, weight: .regular))
            .tracking(0.1)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Open @patelzeel68 on X")
    }

    private func openTwitter() {
        if let url = URL(string: "https://x.com/patelzeel68") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct ProgressDots: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Color.primary.opacity(0.8) : Color.primary.opacity(0.18))
                    .frame(width: i == current ? 16 : 5, height: 5)
                    .animation(.spring(response: 0.32, dampingFraction: 0.82), value: current)
            }
        }
    }
}

/// NSVisualEffectView wrapper for a proper macOS blur backdrop.
private struct VisualEffectBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
