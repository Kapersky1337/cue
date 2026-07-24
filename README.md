# Cue

An inline AI assistant for every text field on macOS. Powered by the AI CLIs you already have.

## Install

**[Download Cue.dmg](https://github.com/Kapersky1337/cue/releases/latest)** — signed, notarized, universal (Apple Silicon + Intel), macOS 14+.

Drag to Applications, launch, and follow the 30-second onboarding.

## What it does

Double-tap **Right Command** anywhere (or press **⇧⌥Space**). A single input appears. Type. Hit enter. The answer pastes in.

- **Empty field**: ask anything, the answer streams in.
- **Selection or field content**: transform it (rewrite, shorten, sharpen, fix, translate).
- **Anywhere**: Slack, iMessage, Gmail, Notion, Linear, Cursor, terminal, browser.

Runs on whichever engine you have installed. Cue uses your existing CLI auth, so there are no API keys to manage:

| Engine | CLI | Notes |
| --- | --- | --- |
| Claude Code | `claude` | Streams; model picker (Haiku 4.5 / Sonnet 5 / Opus 4.8) |
| Codex | `codex` | Read-only sandbox, ephemeral sessions |
| Gemini CLI | `gemini` | CLI-default model |
| Ollama | `ollama` | Fully local; pick any installed model |

Cue inherits each CLI's auth. Switch engine and model from the menu bar.

## Build

```bash
./build.sh
open build/Cue.app
```

Grant Accessibility permission when prompted (System Settings → Privacy & Security → Accessibility), then quit and relaunch once.

## Requirements

- macOS 14+
- Swift 5.9+
- Any one of: `claude`, `codex`, `gemini`, or `ollama` on your machine

## Architecture

- `HotkeyMonitor` — CGEventTap double-tap detection on Right Command (keyCode 54), self-healing on macOS timeout-disable, plus a permissionless ⇧⌥Space Carbon hotkey.
- `CursorLocator` — AX API → focused element → `AXBoundsForRange` for caret rect, fallback to element frame, fallback to mouse.
- `CaretPanel` — borderless non-activating `NSPanel` with SwiftUI `TextField`, clamped to screen.
- `Providers` — engine detection, binary resolution, per-engine model lists.
- `LLMClient` — spawns the active engine's CLI with a tight paste-contract prompt; streams where the CLI can.
- `TextInserter` — stash pasteboard → set answer → reactivate prior app → synthesize ⌘V → restore pasteboard.

## Contributing

Issues and PRs welcome. Read `CLAUDE.md` for the architecture map and the taste rules the codebase follows — the short version: smallest diff that achieves the goal, no dead code, errors recover instead of crash, and hotkey reliability is sacred.

## License

[MIT](LICENSE) © Zeel Patel
