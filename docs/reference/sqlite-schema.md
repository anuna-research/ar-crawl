---
title: SQLite schema
mode: reference
---

# SQLite schema

Tables and indexes of a crawl database written with `--format sqlite`.

The SQLite database uses a normalized relational schema optimized for analysis:

**Core Tables:**
- **`crawl_sessions`** - Metadata for each crawl run (duration, statistics, configuration)
- **`crawled_pages`** - Individual page content, metadata, and extracted text
- **`discovered_links`** - All links found during crawling with relationship tracking
- **`failed_urls`** - URLs that failed to crawl with error details
- **`extracted_items`** - Structured data extraction results (for advanced scraping)

**Key Fields:**
- **URLs, titles, content** - Full page data with content length tracking
- **Timestamps** - When pages were crawled for temporal analysis
- **Relationships** - Foreign keys linking pages to crawl sessions and links
- **Metadata** - HTTP methods, user agents, response times, and more

**Indexes:** Optimized for fast queries on URLs, crawl IDs, content length, and timestamps
