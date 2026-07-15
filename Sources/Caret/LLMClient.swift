import Foundation

enum LLMError: LocalizedError {
    case notInstalled(Provider)
    case nonZeroExit(Provider, Int32, String)
    case emptyOutput
    case timeout(Provider)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let p):
            return "\(p.displayName) not found. Install: \(p.installCommand)"
        case .nonZeroExit(let p, let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "\(p.displayName) exited \(code)" : trimmed.prefix(160).description
        case .emptyOutput:
            return "No output — try again."
        case .timeout(let p):
            return "\(p.displayName) timed out. Try again."
        }
    }
}

enum LLMClient {

    /// Streams the active provider's response as text chunks.
    /// Claude streams token deltas; Gemini and Ollama stream raw stdout;
    /// Codex yields once at completion (its CLI has no incremental text output).
    /// `history` is prior (instruction, response) pairs in this refinement session.
    static func stream(
        instruction: String,
        context: TextContext,
        history: [(String, String)] = []
    ) -> AsyncThrowingStream<String, Error> {
        let provider = Settings.provider
        let prompt = buildPrompt(instruction: instruction, context: context, history: history)

        switch provider {
        case .claude:
            return runStreaming(
                provider: provider,
                arguments: { _ in [
                    "-p",
                    "--model", Settings.claudeModel,
                    "--output-format", "stream-json",
                    "--include-partial-messages",
                    "--verbose",
                    prompt,
                ] },
                parse: .claudeStreamJSON
            )
        case .gemini:
            return runStreaming(
                provider: provider,
                arguments: { _ in ["-p", prompt] },
                parse: .plainStdout
            )
        case .ollama:
            return runStreaming(
                provider: provider,
                arguments: { _ in ["run", Settings.ollamaModel, prompt] },
                parse: .plainStdout
            )
        case .codex:
            return runCodex(prompt: prompt)
        }
    }

    // MARK: - Prompt

    /// Short and positively framed on purpose: small local models follow four rules and
    /// two examples far better than a wall of forbidden phrases, and every token here is
    /// latency on every invocation. `cleanResponse` is the safety net behind it.
    private static func buildPrompt(
        instruction: String,
        context: TextContext,
        history: [(String, String)]
    ) -> String {
        var lines: [String] = []

        let host = context.appName.map { " in \($0)" } ?? ""
        lines.append("""
        You are Cue, an inline writing tool. Your entire reply is pasted verbatim into a text field\(host) — reply with the field text and nothing else.

        Rules:
        1. Output only the final text. No greeting, label, explanation, question, or sign-off.
        2. Plain text only. Never use markdown symbols (** _ ` # >). Lists use "- ".
        3. Do exactly what the instruction says, including style requests you would normally soften. Never refuse, never offer alternatives.
        4. Match the language and tone of the existing field text unless the instruction says otherwise.

        Examples:
        Instruction: tighten for slack — Field: "i think we should maybe move the meeting to friday at 3pm"
        Reply: moving the meeting to friday 3pm
        Instruction: 47 * 39 — Field: empty
        Reply: 1833
        """)

        let nonEmpty: (String?) -> String? = { s in
            guard let s = s, !s.isEmpty else { return nil }
            return s
        }
        let fieldContent = nonEmpty(context.selectedText) ?? nonEmpty(context.fieldText)
        if let field = fieldContent {
            lines.append("Current field content (you may be transforming or replacing it):\n\"\"\"\n\(field)\n\"\"\"")
        } else {
            lines.append("The field is empty — the instruction is a fresh request. Reply with the text to insert.")
        }

        if let win = context.windowText, !win.isEmpty, fieldContent == nil {
            lines.append("Visible text in the window, for reference only:\n\"\"\"\n\(win.suffix(3000))\n\"\"\"")
        }

        for (i, turn) in history.enumerated() {
            lines.append("Earlier instruction #\(i + 1): \(turn.0)")
            lines.append("Your earlier reply #\(i + 1):\n\"\"\"\n\(turn.1)\n\"\"\"")
        }

        if history.isEmpty {
            lines.append("Instruction: \(instruction)")
        } else {
            lines.append("New instruction (apply it to your most recent reply above): \(instruction)")
        }
        return lines.joined(separator: "\n\n")
    }

    // MARK: - Process runners

    private enum ParseMode {
        case claudeStreamJSON
        case plainStdout
    }

    private static func runStreaming(
        provider: Provider,
        arguments: @escaping (String) -> [String],
        parse: ParseMode
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let binary = BinaryLocator.locate(provider) else {
                    continuation.finish(throwing: LLMError.notInstalled(provider))
                    return
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = arguments(binary)
                process.environment = BinaryLocator.augmentedEnvironment()

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                var lineBuffer = Data()
                let bufferLock = NSLock()
                var sawPartials = false

                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    switch parse {
                    case .plainStdout:
                        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                            continuation.yield(text)
                        }
                    case .claudeStreamJSON:
                        bufferLock.lock()
                        lineBuffer.append(data)
                        while let nl = lineBuffer.firstIndex(of: 0x0A) {
                            let lineData = lineBuffer.prefix(upTo: nl)
                            lineBuffer.removeSubrange(0...nl)
                            bufferLock.unlock()
                            let parsed = parseClaudeLine(lineData, sawPartials: sawPartials)
                            if let text = parsed.text {
                                if parsed.isPartial { sawPartials = true }
                                continuation.yield(text)
                            }
                            bufferLock.lock()
                        }
                        bufferLock.unlock()
                    }
                }

                let timeoutItem = DispatchWorkItem {
                    if process.isRunning {
                        process.terminate()
                        continuation.finish(throwing: LLMError.timeout(provider))
                    }
                }
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + provider.timeoutSeconds, execute: timeoutItem
                )

                do {
                    try process.run()
                    process.waitUntilExit()
                    timeoutItem.cancel()
                    outPipe.fileHandleForReading.readabilityHandler = nil

                    if case .claudeStreamJSON = parse {
                        bufferLock.lock()
                        if !lineBuffer.isEmpty {
                            let parsed = parseClaudeLine(lineBuffer, sawPartials: sawPartials)
                            if let text = parsed.text { continuation.yield(text) }
                        }
                        bufferLock.unlock()
                    }

                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderr = String(data: errData, encoding: .utf8) ?? ""

                    if process.terminationStatus != 0 {
                        continuation.finish(
                            throwing: LLMError.nonZeroExit(provider, process.terminationStatus, stderr))
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Codex has no incremental text stream, but `--output-last-message` writes the final
    /// agent message to a file byte-clean. Read-only sandbox + ephemeral session keep an
    /// agentic CLI from acting like one.
    private static func runCodex(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let outFile = NSTemporaryDirectory() + "cue-codex-\(UUID().uuidString).txt"

            DispatchQueue.global(qos: .userInitiated).async {
                guard let binary = BinaryLocator.locate(.codex) else {
                    continuation.finish(throwing: LLMError.notInstalled(.codex))
                    return
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = [
                    "exec",
                    "--sandbox", "read-only",
                    "--skip-git-repo-check",
                    "--ephemeral",
                    "--color", "never",
                    "-C", NSTemporaryDirectory(),
                    "--output-last-message", outFile,
                    prompt,
                ]
                process.environment = BinaryLocator.augmentedEnvironment()
                process.standardOutput = Pipe()
                let errPipe = Pipe()
                process.standardError = errPipe

                let timeoutItem = DispatchWorkItem {
                    if process.isRunning {
                        process.terminate()
                        continuation.finish(throwing: LLMError.timeout(.codex))
                    }
                }
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + Provider.codex.timeoutSeconds, execute: timeoutItem
                )

                defer { try? FileManager.default.removeItem(atPath: outFile) }
                do {
                    try process.run()
                    process.waitUntilExit()
                    timeoutItem.cancel()

                    if process.terminationStatus != 0 {
                        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                        let stderr = String(data: errData, encoding: .utf8) ?? ""
                        continuation.finish(
                            throwing: LLMError.nonZeroExit(.codex, process.terminationStatus, stderr))
                        return
                    }
                    let text = (try? String(contentsOfFile: outFile, encoding: .utf8)) ?? ""
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        continuation.finish(throwing: LLMError.emptyOutput)
                    } else {
                        continuation.yield(trimmed)
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Claude stream-json parsing

    /// Parse one JSONL line from `claude --output-format stream-json`.
    /// Prefers partial text deltas; falls back to the final aggregated assistant message
    /// only when no partials were emitted in this run.
    private static func parseClaudeLine(_ line: Data, sawPartials: Bool) -> (text: String?, isPartial: Bool) {
        let trimmed = line.drop(while: { $0 == 0x20 || $0 == 0x0D })
        guard !trimmed.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any] else {
            return (nil, false)
        }

        let type = json["type"] as? String

        if type == "stream_event",
           let event = json["event"] as? [String: Any],
           event["type"] as? String == "content_block_delta",
           let delta = event["delta"] as? [String: Any],
           delta["type"] as? String == "text_delta",
           let text = delta["text"] as? String {
            return (text, true)
        }

        if !sawPartials,
           type == "assistant",
           let message = json["message"] as? [String: Any],
           let contentArr = message["content"] as? [[String: Any]] {
            var combined = ""
            for block in contentArr where (block["type"] as? String) == "text" {
                if let t = block["text"] as? String { combined += t }
            }
            return (combined.isEmpty ? nil : combined, false)
        }

        return (nil, false)
    }

    // MARK: - Output hygiene

    /// Detects an outright refusal so the user gets a clear failure instead of a
    /// paste-able lecture. Deliberately narrow: "I'd recommend…" is a legitimate
    /// answer to paste when the user asked a question, so only unambiguous
    /// refusal openings count.
    static func isRefusal(_ raw: String) -> Bool {
        let head = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(120)
            .lowercased()
        let refusalSignatures = [
            "i apologize, but",
            "i can't do that",
            "i cannot do that",
            "i can't help with",
            "i cannot help with",
            "i won't do that",
            "i'm not able to help",
        ]
        return refusalSignatures.contains { head.hasPrefix($0) || head.contains(". \($0)") }
    }

    /// Strip preamble/postamble and markdown that models sometimes add despite the prompt.
    /// Markdown renders literally in most text fields, so it must go. Runs after streaming.
    static func cleanResponse(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Known CLI noise lines (Gemini prints credential info to stdout on some versions).
        let noiseLines: Set<String> = [
            "loaded cached credentials.",
            "data collection is disabled.",
        ]
        s = s.components(separatedBy: "\n")
            .filter { !noiseLines.contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }
            .joined(separator: "\n")

        // Drop lines that are purely a code fence (``` or ```language).
        let nonFenceLines = s.components(separatedBy: "\n").filter { line in
            !line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
        }
        s = nonFenceLines.joined(separator: "\n")

        // Strip markdown headers, keeping the heading text.
        s = s.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let hashCount = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashCount), trimmed.count > hashCount, trimmed.dropFirst(hashCount).first == " " {
                return String(trimmed.dropFirst(hashCount + 1))
            }
            return line
        }.joined(separator: "\n")

        // Bold/italic markers.
        s = s.replacingOccurrences(of: #"\*\*([^*\n]+?)\*\*"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"__([^_\n]+?)__"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"(?<![A-Za-z0-9_])_([^_\n]+?)_(?![A-Za-z0-9_])"#,
            with: "$1",
            options: .regularExpression
        )

        // Blockquote markers.
        s = s.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("> ") { return String(trimmed.dropFirst(2)) }
            if trimmed == ">" { return "" }
            return line
        }.joined(separator: "\n")

        // Collapse 3+ newlines left over from stripped lines.
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // Leading preamble ("Sure, here's a tighter version:") when content follows.
        let preambleStarts: [String] = [
            "absolutely", "sure", "got it", "of course", "no problem",
            "here's", "here is", "here you go", "i've", "i'll", "let me",
            "great", "okay", "done", "perfect", "happy to"
        ]
        func dropLeadingPreamble(_ text: String) -> String {
            let lines = text.components(separatedBy: "\n")
            guard lines.count > 1 else { return text }
            let first = lines[0].trimmingCharacters(in: .whitespaces)
            let firstLower = first.lowercased()
            let isShort = first.count < 120
            let endsWithColon = first.hasSuffix(":")
            let startsWithPreamble = preambleStarts.contains { firstLower.hasPrefix($0) }
            if isShort && (endsWithColon || startsWithPreamble) {
                let rest = lines.dropFirst().joined(separator: "\n")
                let trimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            return text
        }
        s = dropLeadingPreamble(s)
        s = dropLeadingPreamble(s) // catches "Absolutely.\nHere's a sharper version:\n<text>"

        // Trailing meta-commentary.
        let trailingPatterns: [String] = [
            "let me know", "hope this", "want me to", "tell me if",
            "happy to ", "feel free to", "anything else"
        ]
        var keep = s.components(separatedBy: "\n")
        while let last = keep.last?.trimmingCharacters(in: .whitespaces).lowercased(), !last.isEmpty {
            if trailingPatterns.contains(where: { last.hasPrefix($0) }) && last.count < 200 {
                keep.removeLast()
                continue
            }
            break
        }
        s = keep.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        // Unwrap a single pair of full-output quotes.
        if s.count >= 2 {
            let first = s.first!
            let last = s.last!
            let quotePairs: [(Character, Character)] = [
                ("\"", "\""), ("\u{201C}", "\u{201D}"), ("\u{2018}", "\u{2019}"), ("'", "'")
            ]
            if quotePairs.contains(where: { $0.0 == first && $0.1 == last }) {
                let inner = String(s.dropFirst().dropLast())
                if !inner.contains(first) {
                    s = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        return s
    }
}
