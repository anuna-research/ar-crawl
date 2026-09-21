---
title: Session commands and actions
mode: reference
---

# Session commands and actions

The stdin protocol of `ar-crawl session`: commands, the recording it commits, and every Playwright action it accepts.

## Commands

| Command | Description |
|---------|-------------|
| `{"type": "goto", "url": "..."}` | Navigate to URL |
| `{"type": "click", "selector": "..."}` | Click element |
| `{"type": "fill", "selector": "...", "value": "..."}` | Fill input field |
| `{"type": "type", "selector": "...", "text": "..."}` | Type text (with key events) |
| `{"type": "hover", "selector": "..."}` | Hover over element |
| `{"type": "press", "key": "Enter"}` | Press keyboard key |
| `{"type": "screenshot"}` | Take screenshot (base64) |
| `{"type": "evaluate", "expression": "..."}` | Run JavaScript |
| `state` | Get current page state |
| `commit [file]` | End session, save recording |
| `exit` | Close without saving |

## Recording Format

Sessions produce Chrome DevTools Recorder compatible JSON with UTC timestamps:

```json
{
  "title": "LLM Agent Session",
  "steps": [
    {"type": "goto", "url": "https://...", "timestamp": "2026-01-08T01:24:38.230Z"},
    {"type": "click", "selector": "...", "timestamp": "2026-01-08T01:24:39.100Z"}
  ]
}
```

Recordings can be replayed with `ar-crawl replay my-session.json`.

## All Supported Actions

The session supports the full Playwright API:

**Navigation:** `goto`, `goBack`, `goForward`, `reload`

**Interaction:** `click`, `dblclick`, `fill`, `type`, `hover`, `focus`, `press`, `check`, `uncheck`, `selectOption`

**Waiting:** `waitForSelector`, `waitForNavigation`, `waitForLoadState`, `waitForTimeout`

**Capture:** `screenshot`, `evaluate`

**Viewport:** `setViewport`, `emulateMedia`
