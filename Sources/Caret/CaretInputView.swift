import SwiftUI

struct ChatTurn: Identifiable, Equatable {
    let id = UUID()
    let userInstruction: String
    let assistantResponse: String
}

@MainActor
final class CaretViewModel: ObservableObject {
    @Published var prompt: String = ""
    @Published var response: String = ""
    @Published var status: Status = .idle
    /// The most recent instruction the user submitted. Shown as a small "↳ you said:" tag
    /// above the response so the user has a clear record of what they asked.
    @Published var lastInstruction: String = ""
    /// Toggled with Tab — expands the panel into a full chat view with all turns visible.
    @Published var expanded: Bool = false

    let context: TextContext
    let onDismiss: () -> Void
    let onResize: ((CGSize) -> Void)?
    private var streamTask: Task<Void, Never>?
    /// Prior (instruction, response) turns in this session — Claude sees these
    /// so refinements like "shorter" act on the latest output.
    private(set) var history: [(String, String)] = []

    /// All turns including the live current one. Used by the expanded chat view.
    var allTurns: [ChatTurn] {
        var turns = history.map { ChatTurn(userInstruction: $0.0, assistantResponse: $0.1) }
        if !lastInstruction.isEmpty {
            turns.append(ChatTurn(userInstruction: lastInstruction, assistantResponse: response))
        }
        return turns
    }

    func toggleExpanded() {
        // Only allow expand once we have a response to chat about
        if !expanded && !hasAnyTurn { return }
        expanded.toggle()
    }

    private var hasAnyTurn: Bool {
        !history.isEmpty || (!lastInstruction.isEmpty && !response.isEmpty)
    }

    enum Status: Equatable {
        case idle
        case thinking
        case streaming
        case done
        case error(String)
    }

    init(context: TextContext, onDismiss: @escaping () -> Void, onResize: ((CGSize) -> Void)? = nil) {
        self.context = context
        self.onDismiss = onDismiss
        self.onResize = onResize
    }

    var isRefining: Bool { !lastInstruction.isEmpty }

    func submit() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if case .streaming = status { return }
        if case .thinking = status { return }

        // Move the previous turn (if any) into the history before starting a new one.
        if !lastInstruction.isEmpty, !response.isEmpty {
            history.append((lastInstruction, response))
        }

        lastInstruction = trimmed
        prompt = ""           // clear input so the user can type their next refinement
        status = .thinking
        response = ""
        let ctx = context
        let priorHistory = history

        streamTask?.cancel()
        streamTask = Task {
            do {
                for try await chunk in LLMClient.stream(
                    instruction: trimmed,
                    context: ctx,
                    history: priorHistory
                ) {
                    if Task.isCancelled { return }
                    await MainActor.run {
                        if self.status == .thinking { self.status = .streaming }
                        self.response += chunk
                    }
                }
                await MainActor.run {
                    if self.response.isEmpty {
                        self.status = .error("No output")
                    } else if LLMClient.isRefusal(self.response) {
                        // The model pushed back instead of executing. Don't paste a lecture —
                        // clear the response and prompt the user to rephrase.
                        self.response = ""
                        self.status = .error("Couldn't execute that — try rephrasing.")
                    } else {
                        // Safety net: strip preamble/postamble models sometimes add
                        // despite the strict prompt.
                        let cleaned = LLMClient.cleanResponse(self.response)
                        if cleaned != self.response {
                            withAnimation(.easeOut(duration: 0.18)) {
                                self.response = cleaned
                            }
                        }
                        self.status = .done
                    }
                }
            } catch is CancellationError {
                // user canceled
            } catch {
                await MainActor.run {
                    self.status = .error(error.localizedDescription)
                }
            }
        }
    }

    /// ⌘↩ — wipe the field and drop in the response.
    func replaceAndDismiss() {
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onDismiss()
        TextInserter.replaceField(with: text, in: context)
    }

    /// ⌘↓ — keep what's there, add the response after it.
    func appendAndDismiss() {
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onDismiss()
        TextInserter.appendToField(text, in: context)
    }

    /// ⌘C — copy to pasteboard, keep panel open.
    func copyToPasteboard() {
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        TextInserter.copy(text)
    }

    func cancel() {
        streamTask?.cancel()
        onDismiss()
    }
}


// MARK: - View

struct CaretInputView: View {
    @ObservedObject var viewModel: CaretViewModel
    @FocusState private var focused: Bool
    @State private var appeared = false
    @State private var thinking = false
    /// Micro-interaction: subtle scale bump on the brand mark each keystroke.
    @State private var typingBump: CGFloat = 1.0

    private var hasResponse: Bool { !viewModel.response.isEmpty }

    private var isError: Bool {
        if case .error = viewModel.status { return true }
        return false
    }

    private var panelWidth: CGFloat {
        viewModel.expanded ? 600 : 520
    }

    private var panelHeight: CGFloat {
        let base: CGFloat = 44
        if viewModel.expanded {
            return 36 + maxChatHeight + 46 + 28
        }
        guard hasResponse || viewModel.status == .thinking || isError else { return base }
        let lines = max(1, viewModel.response.split(separator: "\n").count + viewModel.response.count / 70)
        let bodyH = min(CGFloat(lines) * 18 + 24, 220)
        let tagH: CGFloat = viewModel.lastInstruction.isEmpty ? 0 : 22
        return base + tagH + bodyH + 28
    }

    private let maxChatHeight: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.expanded {
                // Chat mode: bubbles fill the top, input + actions stick to the bottom.
                chatHeader
                Divider().opacity(0.18)
                chatView
                Divider().opacity(0.18)
                chatInputBar
                footerRow
            } else {
                // Compact mode: input at top, response + footer only appear after a response.
                inputRow
                if hasResponse || viewModel.status == .thinking || isError {
                    Divider().opacity(0.18)
                    responseArea
                    footerRow
                }
            }
        }
        .frame(width: panelWidth)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.28), radius: 30, x: 0, y: 12)
        .scaleEffect(appeared ? 1.0 : 0.97)
        .opacity(appeared ? 1.0 : 0.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: appeared)
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: viewModel.expanded)
        .animation(.easeOut(duration: 0.14), value: hasResponse)
        .onAppear {
            appeared = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { focused = true }
        }
        .onChange(of: viewModel.expanded) { _, _ in
            // Re-focus the TextField when toggling modes (the field instance
            // changes between layouts and would otherwise lose focus).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
        }
        .onChange(of: panelHeight) { _, _ in
            viewModel.onResize?(CGSize(width: panelWidth, height: panelHeight))
        }
        .onChange(of: panelWidth) { _, _ in
            viewModel.onResize?(CGSize(width: panelWidth, height: panelHeight))
        }
        .background(shortcutSurface)
    }

    // MARK: - Chat-mode header and input bar

    private var chatHeader: some View {
        HStack(spacing: 8) {
            CaretLogo(size: 16)
            Text("Cue")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary.opacity(0.92))
                .tracking(0.2)
            Text("· \(viewModel.allTurns.count) turn\(viewModel.allTurns.count == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(.secondary)
            if let app = viewModel.context.appName {
                Text("· \(app)")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.secondary.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer()
            closeButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var chatInputBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.7))
                .frame(width: 14)
            TextField(refinePlaceholder, text: $viewModel.prompt)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .regular))
                .focused($focused)
                .onSubmit { viewModel.submit() }
                .disabled(viewModel.status == .thinking || viewModel.status == .streaming)
            if viewModel.status == .thinking || viewModel.status == .streaming {
                ProgressView().controlSize(.small).scaleEffect(0.65)
            } else {
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.45))
                    .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            // Subtle inset background so the input clearly reads as "type here"
            Rectangle()
                .fill(Color.primary.opacity(0.03))
        )
    }

    private var refinePlaceholder: String {
        if case .error = viewModel.status { return "Try again…" }
        return "Refine — shorter, warmer, fix…"
    }

    /// Invisible buttons that own the keyboard shortcuts. SwiftUI routes them to here
    /// regardless of which inner view has focus, so they fire reliably with the TextField focused.
    private var shortcutSurface: some View {
        ZStack {
            Button("Replace") { viewModel.replaceAndDismiss() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!hasResponse)
            Button("Append") { viewModel.appendAndDismiss() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!hasResponse)
            Button("Copy") { viewModel.copyToPasteboard() }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!hasResponse)
            Button("Expand") { viewModel.toggleExpanded() }
                .keyboardShortcut("e", modifiers: .command)
            Button("Cancel", role: .cancel) { viewModel.cancel() }
                .keyboardShortcut(.cancelAction)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            statusDot
                .scaleEffect(typingBump)
            TextField(placeholder, text: $viewModel.prompt)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .regular))
                .focused($focused)
                .onSubmit { viewModel.submit() }
                .disabled(viewModel.status == .thinking || viewModel.status == .streaming)
                .onChange(of: viewModel.prompt) { _, _ in pulseMark() }
            contextBadge
            closeButton
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    /// Tiny premium micro-interaction. Each keystroke briefly scales the mark by 8%,
    /// returning to rest. Fast typing naturally chains into a sustained gentle bounce.
    private func pulseMark() {
        withAnimation(.spring(response: 0.18, dampingFraction: 0.55)) {
            typingBump = 1.08
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                typingBump = 1.0
            }
        }
    }

    private var closeButton: some View {
        Button(action: { viewModel.cancel() }) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
                .frame(width: 18, height: 18)
                .background(
                    Circle().fill(Color.primary.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .help("Cancel (esc)")
    }

    // MARK: - Expanded chat view

    @ViewBuilder
    private var chatView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(viewModel.allTurns.enumerated()), id: \.element.id) { index, turn in
                        chatTurnView(turn, isLatest: index == viewModel.allTurns.count - 1)
                            .id(turn.id)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .bottom)),
                                removal: .opacity
                            ))
                    }
                    if viewModel.status == .thinking {
                        thinkingDots
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 10)
                .animation(.spring(response: 0.32, dampingFraction: 0.82), value: viewModel.allTurns.count)
            }
            .frame(maxHeight: maxChatHeight)
            .onChange(of: viewModel.response) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.expanded) { _, expanded in
                if expanded {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private func chatTurnView(_ turn: ChatTurn, isLatest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // User bubble: right-aligned, tinted
            HStack {
                Spacer(minLength: 60)
                Text(turn.userInstruction)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(.primary.opacity(0.85))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.accentColor.opacity(0.18))
                    )
            }
            // Assistant bubble: left-aligned
            HStack(alignment: .top, spacing: 8) {
                Text(turn.assistantResponse.isEmpty ? " " : turn.assistantResponse)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.primary.opacity(0.94))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.primary.opacity(isLatest ? 0.08 : 0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(
                                isLatest ? Color.accentColor.opacity(0.35) : Color.clear,
                                lineWidth: 1
                            )
                    )
                Spacer(minLength: 40)
            }
        }
    }

    private var thinkingDots: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: 5, height: 5)
                    .scaleEffect(thinking ? 1.0 : 0.5)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.15),
                        value: thinking
                    )
            }
        }
        .padding(.leading, 12)
        .onAppear { thinking = true }
    }

    @ViewBuilder
    private var responseArea: some View {
        if case .error(let msg) = viewModel.status {
            Text(msg)
                .font(.system(size: 12))
                .foregroundColor(.red.opacity(0.9))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if !viewModel.lastInstruction.isEmpty {
                    instructionTag(viewModel.lastInstruction)
                }
                ScrollView {
                    Text(viewModel.response.isEmpty ? " " : viewModel.response)
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundColor(.primary.opacity(0.94))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.top, viewModel.lastInstruction.isEmpty ? 10 : 4)
                        .padding(.bottom, 12)
                }
                .frame(maxHeight: 220)
            }
        }
    }

    private func instructionTag(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.7))
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var footerRow: some View {
        HStack(spacing: 12) {
            if hasResponse {
                hint(label: "Replace", keys: "⌘↩")
                hint(label: "Append", keys: "⌘↓")
                hint(label: "Copy", keys: "⌘C")
                hint(label: viewModel.expanded ? "Collapse" : "Chat", keys: "⌘E")
                    .opacity(0.82)
            } else if viewModel.status == .thinking || viewModel.status == .streaming {
                Text("Thinking…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text("esc")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.7))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.06))
                )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.04))
    }

    private func hint(label: String, keys: String) -> some View {
        HStack(spacing: 5) {
            if !keys.isEmpty {
                Text(keys)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.primary.opacity(0.08))
                    )
            }
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var contextBadge: some View {
        // Only show in compact mode, idle/done state, when we have an app context.
        if !viewModel.expanded,
           viewModel.status == .idle || viewModel.status == .done,
           let app = viewModel.context.appName {
            HStack(spacing: 5) {
                Text(app)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.primary.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if viewModel.context.contextLength > 0 {
                    Text("·")
                        .font(.system(size: 9, weight: .light))
                        .foregroundColor(.primary.opacity(0.35))
                    Text(formatContextSize(viewModel.context.contextLength))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.5))
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.05), lineWidth: 0.5)
            )
            .fixedSize()
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
        }
    }

    /// Compact human-readable context size: 312, 5.2K, 12K, 184K.
    private func formatContextSize(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 10_000 {
            let k = Double(n) / 1000.0
            return String(format: "%.1fK", k)
        }
        return "\(n / 1000)K"
    }

    private var placeholder: String {
        if case .error = viewModel.status { return "Try again…" }
        if viewModel.isRefining {
            return "Refine — shorter, warmer, fix…"
        }
        if let sel = viewModel.context.selectedText, !sel.isEmpty {
            return "Transform selection…"
        }
        if viewModel.context.fieldText?.isEmpty == false {
            return "Edit, refine, ask…"
        }
        return "Ask anything…"
    }

    @ViewBuilder
    private var statusDot: some View {
        CaretStatusMark(status: viewModel.status)
    }

    private var borderColor: Color {
        switch viewModel.status {
        case .streaming, .thinking: return Color.orange.opacity(0.25)
        case .done: return Color.green.opacity(0.25)
        case .error: return Color.red.opacity(0.3)
        default: return Color.white.opacity(0.08)
        }
    }
}

struct PulsingDot: View {
    let color: Color
    @State private var on = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(on ? 1.0 : 0.45)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// The brand mark double-billed as a status indicator.
/// Idle: dim. Thinking/streaming: accent + slow pulse. Done: green. Error: red.
struct CaretStatusMark: View {
    let status: CaretViewModel.Status
    @State private var pulse: CGFloat = 1.0

    var body: some View {
        CaretMark(color: color)
            .frame(width: 14, height: 14)
            .opacity(pulse)
            .onAppear { refreshAnimation() }
            .onChange(of: status) { _, _ in refreshAnimation() }
    }

    private var color: Color {
        switch status {
        case .idle: return .primary.opacity(0.65)
        case .thinking, .streaming: return .orange
        case .done: return .green
        case .error: return .red
        }
    }

    private var isActive: Bool {
        switch status {
        case .thinking, .streaming: return true
        default: return false
        }
    }

    private func refreshAnimation() {
        if isActive {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                pulse = 0.45
            }
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                pulse = 1.0
            }
        }
    }
}
