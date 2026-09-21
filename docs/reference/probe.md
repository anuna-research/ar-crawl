---
title: Probe metrics and scoring
mode: reference
---

# Probe metrics and scoring

What `probe` measures, how it scores a page, and its options.

## Metrics Measured

| Metric | Description |
|--------|-------------|
| DOM Content Loaded | Time until DOMContentLoaded event fires |
| Page Load Complete | Time until load event fires |
| Network Idle | Time until no network activity for 500ms |
| JS Execution (est) | Estimated JavaScript execution time |
| TTFB | Time to first byte |
| Total Requests | Number of network requests |
| Transfer Size | Total data transferred |

## Example Output

```
=== Page Load Metrics ===

Timing:
  DOM Content Loaded: 895 ms
  Page Load Complete: 2968 ms
  Network Idle:       6299 ms
  JS Execution (est): 2073 ms

Resources:
  Total Requests:     250
  Total Transfer:     2400 KB

=== Content Analysis ===

  Content Type: Dynamic/SPA
  The page relies heavily on JavaScript for content.
  Recommendation: Use -s playwright for full content

=== Recommended Scraping Parameters ===

  --pw-delay 8500        # Wait for JS to complete
  --pw-scroll-delay 2500 # Delay between scrolls
  --timeout 30000        # Request timeout

Probe completed in 6386 ms
```

## Content Analysis

The probe command automatically analyzes page characteristics to determine if content is static or dynamically loaded via JavaScript. This helps you choose the right crawling service.

**Content Types:**

| Type | Score | Description | Recommendation |
|------|-------|-------------|----------------|
| Static | 0-19 | Minimal JavaScript, server-rendered HTML | Use `-s direct` for speed |
| Light JS | 20-49 | Some JavaScript, sometimes works without a browser | Try `-s direct` first |
| Dynamic/SPA | 50+ | Heavy JavaScript, content loaded dynamically | Use `-s playwright` |

**Scoring Factors:**

| Factor | Points | Threshold |
|--------|--------|-----------|
| JS Execution Time | +30 | > 500ms |
| XHR/Fetch Requests | +30 | Any async requests |
| Script Count | +25 | > 20 scripts |
| Network Idle Delay | +15 | > 1000ms after load |

Verbose mode (`-v`) prints the exact score and contributing factors:

```
Dynamic Score: 100/100
Factors: JS=2854ms, XHR/Fetch=7, Scripts=115, NetworkDelay=30011ms
```

## Verbose Mode Details

With `-v`, the probe prints additional performance metrics:

```bash
ar-crawl probe https://example.com -v
```

Shows:
- **TTFB** - Time to first byte from server
- **DOM Parsing** - Time spent parsing the DOM
- **DOM Interactive** - When DOM becomes interactive
- **DOM Complete** - When DOM is fully loaded
- **Resource breakdown** - Requests and transfer size by type (scripts, images, etc.)

## Probe Options

| Option | Description |
|--------|-------------|
| `-v, --verbose` | Show detailed timing breakdown and resource metrics |
| `-o, --output FILE` | Save probe results to JSON file |
