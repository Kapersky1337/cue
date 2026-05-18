# Caret

A 200ms inline assistant for every text field on macOS. Double-tap Right Option anywhere.

## Architecture

```
main.swift           → App entry, accessory mode
AppDelegate.swift    → Status item (◐), hotkey setup, panel controller
HotkeyMonitor.swift  → Global double-tap Right Option (keyCode 61)
CursorLocator.swift  → AX API → caret rect → fallback element → fallback mouse
CaretPanel.swift     → Borderless NSPanel, positioned at caret, SwiftUI hosted
CaretInputView.swift → TextField + status dot + app badge, glass material
ClaudeClient.swift   → Shells `claude -p --model claude-haiku-4-5`
TextInserter.swift   → Pasteboard stash → answer → ⌘V inject → restore
```

## Build & Run

```bash
./build.sh && open build/Caret.app
```

Grant Accessibility (System Settings → Privacy & Security → Accessibility → Caret), then quit and relaunch once.

## Design System

- **Material**: `.ultraThinMaterial` with 0.18 shadow, 14pt corners
- **Width**: 560pt fixed, 56pt height
- **Status dot**: 8pt circle (blue=idle, orange=thinking, red=error)
- **Typography**: System 15pt regular for input, 11pt medium for app badge
- **Spacing**: 16pt horizontal, 12pt vertical padding

## Development Notes

- Model: `claude-haiku-4-5` for sub-200ms latency. Swap in ClaudeClient.swift
- Panel: `.nonactivatingPanel` keeps focus in original app
- Insertion: Universal ⌘V works everywhere—Slack, browsers, terminal, Electron apps
- Coordinate conversion: AX returns Quartz (top-left origin) → convert to Cocoa (bottom-left)

---

# Claude Superpowers

## Who I'm Working With

**Zeel** — product builder at Layer3 (zeel@layer3.xyz). Values:
- Apple keynote energy: confident, minimal, every frame intentional
- World-class polish and attention to detail
- Things that "just work"
- High-signal, no fluff

## Execution Philosophy

### Be Relentless About Quality
- Every pixel matters. Every interaction should feel inevitable
- Test edge cases before claiming something works
- Don't ship "good enough"—ship "can't be better"
- If something feels off, it is off. Fix it

### Move Fast, Break Nothing
- Understand before changing. Read the code first
- Make surgical changes. Smallest diff that achieves the goal
- Preserve what works. Don't refactor unless asked
- Test the happy path AND the edge cases

### Product Thinking > Code Thinking
- Ask "what would a user expect?" before "what's technically correct?"
- Friction is failure. Reduce steps, reduce cognitive load
- Defaults should be perfect. Configuration is admission of defeat
- The best feature is the one users never notice because it just works

## Technical Standards

### Swift/macOS
- Use Swift 6 concurrency properly (@MainActor, async/await)
- AX APIs are fragile—always have fallbacks
- NSPanel tricks: `.nonactivatingPanel`, `.statusBar` level, `.transient` collection
- Respect the user's clipboard. Always restore it

### UI Polish Checklist
- [ ] Appears instantly (< 100ms)
- [ ] Positioned correctly at cursor
- [ ] Dismisses on Escape
- [ ] Keyboard focus is immediate
- [ ] Loading state is clear but not distracting
- [ ] Error state is helpful, not scary
- [ ] Works in every app (Electron, native, web)

### Code Quality
- No comments that describe what code does (code should be self-evident)
- Comments only for WHY, not WHAT
- Prefer clarity over cleverness
- Handle errors gracefully—never crash, always inform

## When I Get Stuck

1. **Re-read the code** — the answer is usually there
2. **Test with real data** — not just the happy path
3. **Ask a focused question** — "does X work when Y?" not "is this right?"
4. **Ship smaller** — if unsure, do less but do it perfectly

## Attention to Detail Triggers

When working on UI, always verify:
- Spacing matches design system (16pt, 12pt, 8pt increments)
- Colors use exact values, not approximations
- Animations are smooth (use spring damping 20-30)
- Text truncates gracefully with ellipsis
- Loading states prevent double-submission
- Errors are recoverable

## Git

- Name: zeelatLayer3
- Email: zeel@layer3.xyz
- Commits: Clear, imperative, focused
- PRs: Ship draft early, iterate fast

## Response Style

- Direct. No preamble, no "Great question!"
- Show, don't tell. Code > explanation
- If something won't work, say so immediately
- Acknowledge constraints, then solve anyway

---

# Polish Priorities for Caret

## Immediate Opportunities

1. **Haptic feedback** — Subtle tactile response on hotkey trigger
2. **Animation** — Panel slides in with spring, status dot pulses while thinking
3. **Keyboard shortcuts** — ⌘K to clear, ⌘↵ to submit, Esc to dismiss
4. **History** — Up arrow recalls last prompt
5. **Streaming** — Show response as it arrives, not just at end
6. **Sound** — Optional subtle chime on completion

## Visual Polish

1. **Panel entrance** — Scale from 0.95 + fade, 200ms spring
2. **Status dot** — Pulse animation while thinking
3. **Progress** — Typing indicator dots instead of spinner
4. **App icon** — Proper .icns with all sizes
5. **Dark/light** — Respect system appearance (already does via material)

## Reliability

1. **Retry logic** — Auto-retry on transient failures
2. **Timeout** — 30s max, show helpful message
3. **Offline detection** — Check before calling claude CLI
4. **AX edge cases** — Handle apps that don't report caret position

## Power User Features

1. **Slash commands** — /fix, /shorten, /translate
2. **Context memory** — Remember per-app preferences
3. **Model switching** — Hold Shift for Sonnet instead of Haiku
4. **Multi-select** — Transform multiple selections
