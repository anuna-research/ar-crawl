---
title: How to record a demo
mode: how-to
---

# How to record a demo

This guide covers filming an agent-driven session as a demo bundle, for a reader who can already drive a session.

`session --record DIR` films the session as a **demo bundle**: the raw browser
screencast plus the structured data a video editor needs. The same flag on
`replay` re-films a committed recording. WHEN the app changes, re-run the replay
instead of re-driving the browser.

```bash
# Agent films a demo while driving (1280x720 viewport, 2x capture, demo pacing)
ar-crawl session --record demo/
{"type": "goto", "url": "https://app.example.com", "title": "Open the dashboard"}
{"type": "marker", "title": "Projects are sorted by last activity"}
{"type": "click", "selector": "button:has-text('New')", "title": "Create a project"}
{"type": "type", "selector": "#name", "text": "Q4 launch", "title": "Name it"}
{"type": "press", "key": "Enter", "pause": 1200}
commit
{"status":"committed","bundle":{"dir":"demo","video":"demo/video.webm","durationMs":9800,...}}

# Re-film the same flow later, at phone size
ar-crawl replay demo/recording.json --record demo-mobile/ --viewport 390x844
```

## Write for the camera

- Give every step a `"title"`: it is the narration, and the caption downstream.
- Use `type`, not `fill`, for text the viewer watches being entered.
- Add `{"type": "marker", "title": "..."}` to narrate what is on screen without acting.
- Set `"pause"` on a step to hold longer than the profile's 500 ms.

## Result

DIR holds `video.webm`, `cursor.json`, `manifest.json` and `recording.json`. The bundle layout, flags and pacing rules are in the [demo bundle reference](../reference/demo-bundle.md). ar-edit imports the bundle with `ar-edit demo import DIR`.
