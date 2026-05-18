# Caret

A 200ms inline assistant for every text field on macOS. Powered by your local `claude` CLI.

## What it does

Double-tap **Right Option** anywhere. A single input appears at your cursor. Type. Hit enter. The answer pastes in.

- **Empty field**: ask anything, answer streams in at cursor.
- **Selection**: transform it (rewrite, shorten, sharpen, fix, translate).
- **Anywhere**: Slack, iMessage, Gmail, Notion, Linear, Cursor, terminal, browser.

Inherits your Claude Code auth, MCP servers, skills, and CLAUDE.md memory. No subscription. No cloud middleman. No accounts.

## Build

```bash
./build.sh
open build/Caret.app
```

Grant Accessibility permission when prompted (System Settings → Privacy & Security → Accessibility), then quit and relaunch once.

## Requirements

- macOS 13+
- Swift 5.9+
- `claude` CLI on PATH (`npm i -g @anthropic-ai/claude-code`)

## Architecture

- `HotkeyMonitor` — global double-tap detection on Right Option (keyCode 61).
- `CursorLocator` — AX API → focused element → `AXBoundsForRange` for caret rect, fallback to element frame, fallback to mouse.
- `CaretPanel` — borderless non-activating `NSPanel` with SwiftUI `TextField`, anchored just below caret, clamped to screen.
- `ClaudeClient` — shells `claude -p --model claude-haiku-4-5` with a tight system prompt; captures stdout.
- `TextInserter` — stash pasteboard → set answer → reactivate prior app → synthesize ⌘V → restore pasteboard. Works in every editable surface.

Model defaults to `claude-haiku-4-5` for sub-second latency. Swap in `ClaudeClient.swift`.
