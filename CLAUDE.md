# Cue

An inline AI assistant for every text field on macOS. Double-tap Right Command anywhere.

## Architecture

```
main.swift           → App entry, accessory mode
AppDelegate.swift    → Status item, engine/model menus, hotkey setup, trust watchdog
HotkeyMonitor.swift  → CGEventTap double-tap Right ⌘ (keyCode 54) + Carbon ⇧⌥Space
CursorLocator.swift  → AX API → caret rect → fallback element → fallback mouse
CaretPanel.swift     → Borderless NSPanel, SwiftUI hosted
CaretInputView.swift → TextField + status mark + app badge, glass material
Providers.swift      → Engine enum (claude/codex/gemini/ollama), detection, models
LLMClient.swift      → Spawns the active engine's CLI; claude streams JSON,
                       gemini/ollama stream stdout, codex reads --output-last-message
Settings.swift       → Provider + per-engine model, UserDefaults
Setup.swift          → Detection snapshot + install/sign-in actions
Onboarding.swift     → 3 steps: welcome → accessibility + engine → live try-it
TextInserter.swift   → Pasteboard stash → answer → ⌘V inject → restore
```

## Build & Run

```bash
./build.sh && open build/Cue.app
```

Grant Accessibility (System Settings → Privacy & Security → Accessibility → Cue).
The trust watchdog picks up the grant within 2 seconds — no relaunch needed.

## Design System

- **Material**: `.ultraThinMaterial` with 0.18 shadow, 14pt continuous corners
- **Type**: System 14pt regular input, 11pt medium badges, monospaced key hints
- **Status mark**: the brand caret doubles as status (dim=idle, orange=thinking, green=done, red=error)
- **Spacing**: 4/8/12/16/24 ladder
- **Motion**: springs, response 0.28–0.42, dampingFraction 0.78–0.85

## Development Notes

- Engines are local CLIs — Cue inherits their auth. Detection is filesystem-first;
  the login-shell fallback runs only at stream time, never in pollers.
- The paste-contract prompt is short and positively framed on purpose: small local
  models follow 4 rules + 2 examples far better than a wall of forbidden phrases.
  `LLMClient.cleanResponse` is the safety net behind it.
- Hotkey reliability is the product's one unforgivable bug. The CGEventTap fails
  loudly without permission, re-enables itself after macOS timeout-disables it,
  and the ⇧⌥Space Carbon hotkey needs no permissions at all. Keep it that way.
- Panel: `.nonactivatingPanel` keeps focus in original app
- Insertion: Universal ⌘V works everywhere — Slack, browsers, terminal, Electron apps
- Coordinate conversion: AX returns Quartz (top-left origin) → convert to Cocoa (bottom-left)
- AX APIs are fragile — always have fallbacks. Respect the user's clipboard: always restore it.
- Errors are recoverable, never crashes. No dead code, no commented-out code.

## Releasing

```bash
./release.sh 0.x.y   # Developer ID sign → notarize → staple → DMG
```

Requires a Developer ID Application cert and a notarytool keychain profile
named `cue-notarize` (see release.sh header).
