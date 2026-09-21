---
title: How to drive a browser session as an agent
mode: how-to
---

# How to drive a browser session as an agent

This guide covers driving a live browser from an LLM agent over JSON on stdin/stdout, for an agent that already runs shell commands.

## Basic Usage

```bash
# Start a session
ar-crawl session

# Session outputs JSON, accepts JSON commands via stdin
{"sessionId":"abc-123","status":"ready"}
{"type": "goto", "url": "https://example.com"}
{"success":true,"url":"https://example.com/","title":"Example Domain"}
state
{"url":"https://example.com/","title":"Example Domain"}
commit
{"status":"committed","recording":{...}}
```

## Step Annotations (LLM Reasoning)

Every action can include a `title` field to document the agent's reasoning. These annotations are preserved in the recording for debugging and auditing:

```bash
# Annotate each step with reasoning
{"type": "goto", "url": "https://example.com", "title": "Navigate to example domain to verify site is up"}
{"type": "click", "selector": "a", "title": "Click 'More Information' link to access documentation"}
{"type": "fill", "selector": "#search", "value": "query", "title": "Search for relevant content"}
```

The recording preserves these annotations:
```json
{
  "title": "LLM Agent Session",
  "steps": [
    {"type": "navigate", "url": "https://example.com", "title": "Navigate to example domain to verify site is up", "timestamp": "..."},
    {"type": "click", "selectors": [["a"]], "title": "Click 'More Information' link to access documentation", "timestamp": "..."}
  ]
}
```

## State Filtering (Reduce Context Window)

The `state` command supports filtering to minimize context window usage:

```bash
# Minimal state (default) - just URL and title
state
{"url":"...","title":"..."}

# Clickable elements only
state --actions
{"url":"...","title":"...","actions":[{"text":"Login","href":"..."},...]]}

# Form inputs only
state --forms
{"url":"...","title":"...","inputs":[{"type":"text","name":"email",...},...]]}

# XPath extraction (same syntax as extract command)
state --fields '{"title": "//h1", "links": "//a/@href"}'
{"url":"...","title":"...","results":{"title":"Page Title","links":["...",...]}}

# Extract repeated items (e.g., table rows, product cards)
state --parent "//tr[@class='item']" --fields '{"name": ".//td[1]", "price": ".//td[2]"}'
{"url":"...","title":"...","results":[{"name":"Item 1","price":"$10"},...]]}
```

## Example: LLM Agent Workflow

```bash
# Agent starts session
$ ar-crawl session
{"sessionId":"...","status":"ready"}

# Agent navigates
{"type": "goto", "url": "https://news.ycombinator.com"}
{"success":true,"url":"https://news.ycombinator.com/","title":"Hacker News"}

# Agent extracts just what it needs (30 titles, minimal tokens)
state --fields '{"titles": "//span[@class=\"titleline\"]/a"}'
{"url":"...","results":{"titles":["Story 1","Story 2",...]}}

# Agent clicks on interesting story
{"type": "click", "selector": "span.titleline > a"}
{"success":true,"url":"https://...","title":"..."}

# Agent extracts article content
state --fields '{"content": "//article//p"}'

# Agent saves recording for replay later
commit my-research.json
{"status":"committed","file":"my-research.json"}
```

Every command and action is in the [session reference](../reference/session.md). To film the session, see [How to record a demo](how-to-record-a-demo.md).
