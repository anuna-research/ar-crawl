---
title: Demo bundle format
mode: reference
---

# Demo bundle format

What `session --record` and `replay --record` write, and the flags and step fields that shape it.

## Bundle contents

| File | Contents |
|------|----------|
| `video.webm` | Raw screencast at `viewport × scale`. No cursor is drawn in-page. |
| `cursor.json` | Cursor event log — `move` (with `transitionMs` and `style`: pointer/text/default), `ripple`, `hide`, `show`. `tMs` is milliseconds from video start; `x`/`y` are viewport CSS pixels (multiply by `scale` for video pixels). |
| `manifest.json` | Per-step `startMs`/`endMs`, `title`, `selector`, `success`; plus viewport, scale, profile, `durationMs`. |
| `recording.json` | Chrome DevTools Recorder JSON, replayable. Titles and `pause` values are preserved. |

Compositing the cursor, zooms and captions onto the video is deliberately
**not** done here — ar-crawl's job is capture; the bundle is structured data for
an editor. `t=0` is the moment the page was created; screencast frames begin
within a frame of it.

## Options (identical on `session` and `replay`)

| Flag | Default | Meaning |
|------|---------|---------|
| `--record DIR` | — | Write the bundle to DIR |
| `--viewport WxH` | `1280x720` when recording | Browser viewport |
| `--scale N` | `2` | Device scale factor (2 = retina-quality capture) |
| `--no-cursor` | off | Skip cursor tracking |
| `--profile raw\|demo` | `demo` when recording | Action pacing (see below) |

## Pacing

Pacing lives in the recording, not in flags, so a committed `recording.json`
re-films identically. The `demo` profile applies human defaults — `type` at
80 ms/keystroke, a 500 ms hold after each action, cursor glides at 500 px/s
(clamped 100–600 ms) — and every action accepts:

- `"title"` — narration for the step (also the caption text downstream)
- `"pause"` — milliseconds to hold after the action, overriding the profile

Two demo-only actions: `{"type": "marker", "title": "..."}` is a narration-only
step with no browser action (a chapter marker downstream), and
`{"type": "cursor", "visible": false}` hides/shows the tracked cursor. Both are
stored as DevTools `customStep`s so the recording stays valid Recorder JSON.
`fill` teleports text in; `type` is the filming-friendly form.
