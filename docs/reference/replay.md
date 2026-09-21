---
title: Replay step types and output
mode: reference
---

# Replay step types and output

Step types `replay` executes, its options, and the result document.

## Supported Step Types

| Step Type | Description |
|-----------|-------------|
| `navigate` | Go to a URL |
| `click` | Click an element |
| `doubleClick` | Double-click an element |
| `change` | Fill in a form field |
| `keyDown` / `keyUp` | Keyboard input |
| `scroll` | Scroll page or element |
| `hover` | Hover over element |
| `waitForElement` | Wait for element to appear |
| `waitForExpression` | Wait for JS condition |
| `setViewport` | Set browser viewport size |

## Replay Options

| Option | Description |
|--------|-------------|
| `-v, --verbose` | Show step execution details |
| `-o, --output FILE` | Save result to JSON file |

## Output Format

The replay result includes:

```json
{
  "data": [{
    "content": "<html>...</html>",
    "url": "https://example.com/dashboard",
    "title": "Dashboard",
    "links": ["..."]
  }],
  "recording": {
    "title": "Login Flow",
    "stepsExecuted": 5,
    "stepResults": [
      {"index": 0, "type": "navigate", "success": true, "duration": 1234},
      {"index": 1, "type": "click", "success": true, "duration": 56}
    ]
  },
  "metadata": {
    "method": "playwright-replay",
    "totalTime": 3456
  }
}
```
