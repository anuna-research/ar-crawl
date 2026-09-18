---
title: How to analyse crawl results in SQLite
mode: how-to
---

# How to analyse crawl results in SQLite

This guide covers querying and exporting a crawl written with `--format sqlite`, for a reader with `sqlite3` installed.

## Write a crawl to a database

```bash
# Crawl single URL to SQLite
ar-crawl crawl https://example.com --output results.db --format sqlite

# Crawl entire site to database
ar-crawl crawl-site https://news-site.com \
  --output site-data.db --format sqlite --max-pages 100

# Crawl with filters and save to SQLite
ar-crawl crawl-site https://university.edu \
  --output research.db --format sqlite \
  --url-pattern ".*research.*" \
  --max-pages 50
```

## SQL Analysis Examples

```bash
# Find largest pages
sqlite3 results.db "
  SELECT url, title, content_length 
  FROM crawled_pages 
  WHERE content_length > 5000 
  ORDER BY content_length DESC 
  LIMIT 10"

# Analyze crawl statistics by domain
sqlite3 site-data.db "
  SELECT 
    cs.base_domain,
    COUNT(cp.id) as pages_crawled,
    AVG(cp.content_length) as avg_page_size,
    SUM(cp.content_length) as total_content,
    cs.duration_ms / 1000.0 as duration_seconds
  FROM crawl_sessions cs
  JOIN crawled_pages cp ON cs.crawl_id = cp.crawl_id
  GROUP BY cs.base_domain"

# Find pages with specific content
sqlite3 research.db "
  SELECT url, title 
  FROM crawled_pages 
  WHERE content LIKE '%machine learning%' 
  OR content LIKE '%artificial intelligence%'"

# Track link relationships
sqlite3 site-data.db "
  SELECT 
    dl.source_url, 
    dl.target_url,
    cp.title as target_title
  FROM discovered_links dl
  LEFT JOIN crawled_pages cp ON dl.target_url = cp.url
  WHERE dl.link_type = 'internal'
  LIMIT 20"
```

## Data Export and Integration

```bash
# Export to JSON for other tools
sqlite3 results.db ".mode json" ".output export.json" "SELECT * FROM crawled_pages"

# Export to CSV for Excel/Google Sheets
sqlite3 results.db ".mode csv" ".headers on" ".output data.csv" "
  SELECT url, title, content_length, timestamp 
  FROM crawled_pages 
  ORDER BY content_length DESC"

# Create data summary report
sqlite3 research.db ".mode column" ".headers on" "
  SELECT 
    'Total Pages' as metric, 
    COUNT(*) as value 
  FROM crawled_pages
  UNION ALL
  SELECT 
    'Average Page Size', 
    ROUND(AVG(content_length), 2) 
  FROM crawled_pages
  UNION ALL
  SELECT 
    'Total Content Size', 
    SUM(content_length) 
  FROM crawled_pages"
```

## Integration with Analysis Tools

**Python/Pandas:**
```python
import sqlite3
import pandas as pd

# Connect and analyze
conn = sqlite3.connect('crawl-data.db')
df = pd.read_sql_query("SELECT * FROM crawled_pages", conn)
print(df.describe())
```

**R:**
```r
library(DBI)
library(RSQLite)

# Connect and analyze
con <- dbConnect(RSQLite::SQLite(), "crawl-data.db")
pages <- dbGetQuery(con, "SELECT * FROM crawled_pages")
summary(pages$content_length)
```

Table and index names are in the [SQLite schema](../reference/sqlite-schema.md).
