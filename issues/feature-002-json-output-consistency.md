# Feature: Consistent JSON Output for All Commands

## Status
- [x] Proposed
- [x] Implemented

## Description
The commands `services`, `health`, `stats`, and `probe` currently output human-readable text to stdout. Some support JSON only when writing to a file (like `probe`), while others (`services`, `health`, `stats`) have no JSON support at all.

This creates friction for LLM agents and automation scripts that need to:
1. Programmatically discover available services (`services`)
2. Verify system health and readiness (`health`)
3. Analyze crawl database statistics (`stats`)
4. Read probe metrics without managing temporary files (`probe`)

The "LLM Agent User" profile explicitly emphasizes the need for "structured output that can be processed programmatically" and "quiet mode for clean output parsing".

## Current Behavior

```bash
$ ar-crawl services
Available Crawling Services:
• direct
• playwright
...
```

```bash
$ ar-crawl health
Checking service health...
Overall Status: healthy
...
```

## Desired Behavior

Add `--format json` support to these commands. When enabled, the command should output only the JSON payload to stdout, sending any logs or progress information to stderr.

### Services
```bash
$ ar-crawl services --format json
{
  "services": ["direct", "playwright", "firecrawl", ...],
  "count": 6
}
```

### Health
```bash
$ ar-crawl health --format json
{
  "status": "healthy",
  "uptime": 3600,
  "services": {
    "direct": true,
    "playwright": false
  }
}
```

### Stats
```bash
$ ar-crawl stats data.db --format json
{
  "database": "data.db",
  "total_pages": 150,
  "pages_with_title": 148,
  ...
}
```

### Probe
```bash
$ ar-crawl probe https://example.com --format json
{
  "url": "https://example.com",
  "timing": { ... },
  "recommendations": { ... }
}
```

## Impact
Greatly improves the developer experience for autonomous agents and tools integrating with `ar-crawl`, adhering to the "Unix philosophy" of text streams and structured data.
