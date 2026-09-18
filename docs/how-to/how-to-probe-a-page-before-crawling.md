---
title: How to probe a page before crawling
mode: how-to
---

# How to probe a page before crawling

This guide covers choosing `--pw-delay`, `--pw-scroll-delay` and `--timeout` for a JavaScript-heavy page, before the first crawl of it.

## Probe the page

```bash
# Probe a URL to see timing metrics
ar-crawl probe https://example.com

# Verbose mode shows detailed breakdown
ar-crawl probe https://spa-site.com -v

# Save results for later reference
ar-crawl probe https://example.com -o probe-results.json
```

## Apply the recommended parameters

```bash
# 1. Probe the site first
ar-crawl probe https://spa-site.com -v

# 2. Use recommended values for crawling
ar-crawl -s playwright crawl https://spa-site.com \
  --pw-delay 8500 \
  --pw-scroll-delay 2500
```

What the numbers mean is in the [probe reference](../reference/probe.md).
