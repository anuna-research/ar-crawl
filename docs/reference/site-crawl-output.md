---
title: Site crawl output
mode: reference
---

# Site crawl output

The JSON document `crawl-site` writes.

The site crawler generates comprehensive JSON output with:

```json
{
  "pages": [
    {
      "url": "https://example.com/page1",
      "title": "Page Title",
      "content": "Full HTML content...",
      "links": ["https://example.com/page2", "..."],
      "metadata": {
        "content-length": 5420,
        "method": "direct-http",
        "user-agent": "AR-Crawl/1.0"
      },
      "timestamp": "2025-01-10T15:30:45Z"
    }
  ],
  "failed-urls": [],
  "statistics": {
    "pages-crawled": 50,
    "failed-urls": 0,
    "total-urls-discovered": 127,
    "duration-ms": 45600,
    "average-page-time-ms": 912.0
  },
  "metadata": {
    "seed-url": "https://example.com",
    "base-domain": "example.com"
  },
  "timestamp": "2025-01-10T15:35:45Z"
}
```
