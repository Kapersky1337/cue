import Foundation

enum ClaudeError: LocalizedError {
    case notInstalled
    case nonZeroExit(Int32, String)
    case emptyOutput
    case timeout

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "claude CLI not found. Install: npm i -g @anthropic-ai/claude-code"
        case .nonZeroExit(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "claude exited \(code)" : trimmed.prefix(160).description
        case .emptyOutput: return "Claude returned no output."
        case .timeout: return "Timed out. Try again."
        }
    }
}

enum ClaudeClient {
    private static let timeoutSeconds: Double = 25

    /// Cached successful lookup. Failures are NOT cached — next call retries.
    private static var cachedBinary: String?

    /// Resolves the `claude` binary, trying common install paths directly first,
    /// then a login shell `command -v` as a fallback. macOS GUI apps do not inherit
    /// the user's shell PATH automatically, so direct paths are the most reliable.
    private static var resolvedBinary: String? {
        if let cached = cachedBinary { return cached }
        let found = locateBinary()
        if let found = found {
            NSLog("[Cue] resolved claude at \(found)")
            cachedBinary = found
        } else {
            NSLog("[Cue] could NOT find claude on disk or via shell")
        }
        return found
    }

    /// Public lookup for setup checks. Always re-checks (no caching).
    static func binaryPath() -> String? {
        return locateBinary()
    }

    /// Returns the current process environment with PATH augmented to include every
    /// directory where node, npm, and claude commonly live. Needed because GUI apps
    /// launched via macOS get a bare PATH, which breaks `#!/usr/bin/env node` shebangs.
    private static func augmentedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()

        var extras: [String] = [
            "\(home)/.npm-global/bin",
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.bun/bin",
        ]
        // Newest nvm node version, if present
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            for v in entries.sorted(by: >) {
                let bin = "\(nvmRoot)/\(v)/bin"
                if FileManager.default.fileExists(atPath: bin) {
                    extras.insert(bin, at: 0) // prefer the newest node first
                    break
                }
            }
        }

        let existing = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extras + [existing]).joined(separator: ":")
        env["HOME"] = home
        return env
    }

    static func locateBinary() -> String? {
        let home = NSHomeDirectory()
        // 1. Direct paths — fast and reliable, no shell needed.
        let candidates = [
            "\(home)/.npm-global/bin/claude",
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // 2. Glob common nvm location: ~/.nvm/versions/node/*/bin/claude
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            for v in entries.sorted(by: >) {
                let p = "\(nvmRoot)/\(v)/bin/claude"
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        // 3. Shell fallback — login shell with explicit PATH augmentation
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-l", "-c",
            "export PATH=\"$HOME/.npm-global/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"; command -v claude"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let path = path, !path.isEmpty,
               FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {
            NSLog("[Cue] shell PATH lookup failed: \(error)")
        }
        return nil
    }

    /// Streams Claude's response as text deltas via stream-json + partial messages.
    /// Each yielded String is the next chunk of assistant text. Order preserved.
    /// `history` is prior (instruction, response) pairs in this refinement session — used
    /// so Claude knows what it's iterating on.
    static func stream(
        instruction: String,
        context: TextContext,
        history: [(String, String)] = []
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let binary = resolvedBinary else {
                continuation.finish(throwing: ClaudeError.notInstalled)
                return
            }

            let full = buildPrompt(instruction: instruction, context: context, history: history)

            DispatchQueue.global(qos: .userInitiated).async {
                let model = Settings.model.rawValue
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = [
                    "-p",
                    "--model", model,
                    "--output-format", "stream-json",
                    "--include-partial-messages",
                    "--verbose",
                    full
                ]

                // CRITICAL: macOS GUI apps inherit a bare PATH (just /usr/bin:/bin), so the
                // `claude` script's `#!/usr/bin/env node` shebang can't find node. Inject all
                // the directories where node + claude typically live before spawning.
                process.environment = augmentedEnvironment()

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                var lineBuffer = Data()
                let bufferLock = NSLock()
                // Track whether we've seen any partial deltas. If yes, ignore the
                // final aggregated assistant message (which would otherwise duplicate the body).
                var sawPartials = false

                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    bufferLock.lock()
                    lineBuffer.append(data)
                    while let nl = lineBuffer.firstIndex(of: 0x0A) {
                        let lineData = lineBuffer.prefix(upTo: nl)
                        lineBuffer.removeSubrange(0...nl)
                        bufferLock.unlock()
                        let parsed = parseLine(lineData, sawPartials: sawPartials)
                        if let text = parsed.text {
                            if parsed.isPartial { sawPartials = true }
                            continuation.yield(text)
                        }
                        bufferLock.lock()
                    }
                    bufferLock.unlock()
                }

                let timeoutItem = DispatchWorkItem {
                    if process.isRunning {
                        process.terminate()
                        continuation.finish(throwing: ClaudeError.timeout)
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutItem)

                do {
                    try process.run()
                    process.waitUntilExit()
                    timeoutItem.cancel()
                    outPipe.fileHandleForReading.readabilityHandler = nil

                    // Flush any remaining buffered line
                    bufferLock.lock()
                    if !lineBuffer.isEmpty {
                        let parsed = parseLine(lineBuffer, sawPartials: sawPartials)
                        if let text = parsed.text { continuation.yield(text) }
                    }
                    bufferLock.unlock()

                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderr = String(data: errData, encoding: .utf8) ?? ""

                    if process.terminationStatus != 0 {
                        continuation.finish(throwing: ClaudeError.nonZeroExit(process.terminationStatus, stderr))
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Detects when Claude refused the instruction and tried to lecture / offer alternatives
    /// instead of executing. We treat those as errors so the user gets a clear failure rather
    /// than a paste-able lecture.
    static func isRefusal(_ raw: String) -> Bool {
        let head = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(300)
            .lowercased()
        let refusalSignatures = [
            "i apologize, but",
            "i need to clarify",
            "i need to push back",
            "i'm designed to",
            "i can't do that",
            "i would recommend",
            "i'd recommend",
            "i won't do that",
            "which direction do you",
            "let me push back"
        ]
        return refusalSignatures.contains { head.contains($0) }
    }

    /// Strip common preamble/postamble patterns Claude sometimes adds despite the system prompt.
    /// Also strips markdown formatting (```, **, _, #) which renders literally in most text fields.
    /// This is the safety net behind the strict prompt. Runs after streaming completes.
    static func cleanResponse(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 0. Strip markdown formatting that doesn't render in standard text fields.

        // 0a. Drop any line that's purely a code fence (``` or ```language).
        let nonFenceLines = s.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("```")
        }
        s = nonFenceLines.joined(separator: "\n")

        // 0b. Strip leading "#"/"##"/"###"… markdown headers — keep the heading text.
        s = s.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let hashCount = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashCount), trimmed.count > hashCount, trimmed.dropFirst(hashCount).first == " " {
                return String(trimmed.dropFirst(hashCount + 1))
            }
            return line
        }.joined(separator: "\n")

        // 0c. Strip **bold** markers.
        s = s.replacingOccurrences(of: #"\*\*([^*\n]+?)\*\*"#, with: "$1", options: .regularExpression)

        // 0d. Strip __bold__ markers.
        s = s.replacingOccurrences(of: #"__([^_\n]+?)__"#, with: "$1", options: .regularExpression)

        // 0e. Strip _italic_ markers — but leave snake_case identifiers alone.
        s = s.replacingOccurrences(
            of: #"(?<![A-Za-z0-9_])_([^_\n]+?)_(?![A-Za-z0-9_])"#,
            with: "$1",
            options: .regularExpression
        )

        // 0f. Strip leading "> " blockquote markers from each line.
        s = s.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("> ") { return String(trimmed.dropFirst(2)) }
            if trimmed == ">" { return "" }
            return line
        }.joined(separator: "\n")

        // 0g. Collapse any 3+ consecutive newlines (left over from stripped fence lines)
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Strip leading preamble line if it looks like one.
        // Pattern: first line is short (<120 chars), ends with ":" or starts with a known affirmation,
        // AND there's actual content on subsequent lines.
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
        // Run twice to catch "Absolutely.\nHere's a sharper version:\n<text>"
        s = dropLeadingPreamble(s)

        // 2. Strip trailing meta-commentary lines.
        let trailingPatterns: [String] = [
            "let me know", "hope this", "want me to", "tell me if",
            "happy to ", "feel free to", "anything else"
        ]
        let lines = s.components(separatedBy: "\n")
        var keep = lines
        while let last = keep.last?.trimmingCharacters(in: .whitespaces).lowercased(), !last.isEmpty {
            if trailingPatterns.contains(where: { last.hasPrefix($0) }) && last.count < 200 {
                keep.removeLast()
                continue
            }
            break
        }
        s = keep.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        // 3. Strip a pair of wrapping quotes if the whole thing is quoted.
        if s.count >= 2 {
            let first = s.first!
            let last = s.last!
            let quotePairs: [(Character, Character)] = [
                ("\"", "\""), ("\u{201C}", "\u{201D}"), ("\u{2018}", "\u{2019}"), ("'", "'")
            ]
            if quotePairs.contains(where: { $0.0 == first && $0.1 == last }) {
                let inner = String(s.dropFirst().dropLast())
                // Only unwrap if there's no other unescaped matching quote inside (avoid eating valid content).
                if !inner.contains(first) {
                    s = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        return s
    }

    /// Parse one JSONL line from `claude --output-format stream-json`.
    /// Returns either a partial text delta (preferred), or — if partials were never
    /// emitted in this run — the final aggregated assistant message as a fallback.
    private static func parseLine(_ line: Data, sawPartials: Bool) -> (text: String?, isPartial: Bool) {
        let trimmed = line.drop(while: { $0 == 0x20 || $0 == 0x0D })
        guard !trimmed.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any] else {
            return (nil, false)
        }

        let type = json["type"] as? String

        // Partial text delta: {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"…"}}}
        if type == "stream_event",
           let event = json["event"] as? [String: Any],
           event["type"] as? String == "content_block_delta",
           let delta = event["delta"] as? [String: Any],
           delta["type"] as? String == "text_delta",
           let text = delta["text"] as? String {
            return (text, true)
        }

        // Final aggregated assistant message — only use it if no partials were emitted.
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

    private static func buildPrompt(
        instruction: String,
        context: TextContext,
        history: [(String, String)]
    ) -> String {
        var lines: [String] = []
        lines.append("""
        You are Cue. Your output is MECHANICALLY PASTED into a macOS text field. Every character you write ends up in the user's draft.

        ABSOLUTE RULES (if you break these, the product is broken):
        1. Output ONLY the new field content. Nothing else.
        2. NEVER start with any of these phrases: "Absolutely", "Sure", "Got it", "Here's", "Here is", "Here you go", "I've", "I'll", "Let me", "No problem", "Of course", "Great", "Okay", "Done".
        3. NEVER end with meta-commentary like "Let me know if...", "Hope this helps", "Want me to...", "Tell me if...".
        4. NEVER add a label like "Refined:", "Updated version:", "Sharper:", "Final:".
        5. NEVER wrap the output in quotes (unless quotes belong in the actual field text).
        6. NEVER ask the user a question. Make the best interpretation; they can refine if wrong.
        7. PLAIN TEXT ONLY. NO markdown formatting anywhere. NO triple backticks (```), NO **bold** asterisks, NO _italic_ underscores, NO `inline code` backticks, NO # markdown headers, NO blockquote >. These render literally in Slack/iMessage/Telegram/Mail/Notes and ruin the paste.
        8. For lists, use plain "- " hyphens — these read fine everywhere. For emphasis, just write the words plainly; no formatting markers.
        9. NEVER refuse, decline, critique, or push back on the user's stylistic preferences. If they ask for more jargon, more buzzwords, longer, fluffier, more corporate, more casual, more flowery — give them exactly that. Their stylistic call is FINAL. You are not a writing teacher; you are an executor.
        10. NEVER offer alternatives, options, or ask "which direction." Pick the most literal reading of the instruction and execute it. They will hit refine or esc if they want something else.
        11. NEVER apologize, NEVER explain how you work, NEVER say things like "I apologize", "I need to clarify", "let me push back", "to be honest", "actually", "I'm designed to", or "I'd recommend". These are forbidden openings. Just produce the text.

        CORRECT (this is exactly what the user wants):
        - Instruction: "tighten for slack" / Field: "i think we should move the meeting to friday at 3pm"
          Your output: moving the meeting to friday at 3pm
        - Instruction: "47 * 39" / Field empty
          Your output: 1833
        - Instruction: "format these addresses as a list" / Field has addresses
          Your output:
          Relayer Addresses

          - Current Relayer: 0x1796a56b5446a4d7d32914aa645ba1d3730ae81d
          - Zeel: 0x39e7d53292893594828705622b2430e34e04a9d5
        - Instruction: "enlarge this and add jargon to sound more professional" / Field: "I borrowed your charger. Will return after my phone is done."
          Your output: I appropriated your power adapter following the unforeseen failure of my own peripheral. I will repatriate the device upon completion of the charging cycle for my mobile handset.

        WRONG (do NOT do this):
        - "```\\n**Relayer Addresses**\\n- 0x1796...\\n```"  ← markdown code fence + bold both ruin it
        - "Here's a tighter version: moving the meeting to friday at 3pm"  ← preamble
        - "**Refined:** moving the meeting to friday"  ← label + bold
        - "\\"moving the meeting to friday\\""  ← wrapping quotes
        - "I apologize, but I need to push back. The text is already professional enough. Here are better options: 1) ... 2) ... Which direction do you want?"  ← REFUSAL. NEVER. Just execute the instruction.

        When iterating (prior turns exist), the user is refining. Be even more ruthless — no acknowledgement, no commentary, just the new draft.

        Match the tone of whatever was in the field. Be tight, high-signal. Plain text always.
        """)

        if let app = context.appName {
            lines.append("Host: \(app)\(context.windowTitle.map { " — \"\($0)\"" } ?? "")")
        }

        let nonEmpty: (String?) -> String? = { s in
            guard let s = s, !s.isEmpty else { return nil }
            return s
        }
        let fieldContent = nonEmpty(context.selectedText) ?? nonEmpty(context.fieldText)
        if let field = fieldContent {
            lines.append("CURRENT FIELD CONTENT (the original — you may be transforming/replacing it):\n\"\"\"\n\(field)\n\"\"\"")
        } else {
            lines.append("FIELD IS EMPTY. User is asking a fresh question — return the direct answer.")
        }

        if let win = context.windowText, !win.isEmpty, fieldContent == nil {
            lines.append("Surrounding visible text in the window (for reference only — don't echo unless asked):\n\"\"\"\n\(win.suffix(3000))\n\"\"\"")
        }

        // Prior conversation turns in this session — Claude is iterating with the user.
        for (i, turn) in history.enumerated() {
            lines.append("Earlier instruction #\(i + 1): \(turn.0)")
            lines.append("Your earlier output #\(i + 1):\n\"\"\"\n\(turn.1)\n\"\"\"")
        }

        if history.isEmpty {
            lines.append("Instruction: \(instruction)")
        } else {
            lines.append("New instruction (apply to your most recent output above): \(instruction)")
        }
        return lines.joined(separator: "\n\n")
    }
}

