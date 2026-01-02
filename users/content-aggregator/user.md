# Content Aggregator User Profile

## Who They Are

**Name:** Jamie Patel
**Role:** Content Operations Lead / Indie Developer
**Organization:** News aggregator, content platform, or solo project
**Technical Level:** Medium-High (scripting, databases, some programming)

## Daily Context

Jamie builds and maintains content aggregation systems. They typically:

- Collect articles from multiple news sources
- Aggregate blog posts and updates
- Build RSS-like feeds from sites without feeds
- Archive content for search and discovery platforms

## Goals

1. Collect content from many sources reliably
2. Handle diverse site structures with minimal custom code
3. Store content in searchable databases
4. Run collection on schedules (daily, hourly)

## Pain Points

- Each site has different HTML structures
- Sites change layouts without warning
- Need to handle both static and JavaScript sites
- Volume requires efficient tooling

## Technical Environment

- Linux VPS or cloud server
- SQLite or PostgreSQL for storage
- Cron jobs for scheduling
- Basic scripting (bash, some Python)

---

# Happy Path Flows

## Flow 1: Build News Feed from Site Without RSS

Jamie needs to create a feed from a blog that doesn't offer RSS.

```bash
# Crawl recent articles
ar-crawl crawl-site https://interesting-blog.com/posts \
  --url-pattern ".*/posts/.*" \
  --max-depth 2 \
  --max-pages 50 \
  --output blog-posts.db --format sqlite

# Extract article data
ar-crawl extract blog-posts.db \
  --output articles.json --format json \
  --parent "//article" \
  --fields '{"title": ".//h1", "date": ".//time/@datetime", "author": ".//span[@class=\"author\"]", "content": ".//div[@class=\"post-content\"]", "url": ".//a/@href"}'

# Query recent articles
sqlite3 blog-posts.db "
  SELECT url, title, date(timestamp) as collected
  FROM crawled_pages
  ORDER BY timestamp DESC
  LIMIT 20
"
```

**Expected Outcome:** Structured feed data from a source without RSS.

**Success Criteria:**
- Captures new articles reliably
- Includes full content for indexing
- Can run daily for updates

---

## Flow 2: Multi-Source Aggregation Pipeline

Jamie aggregates content from five different sources.

```bash
#!/bin/bash
# aggregate.sh - Daily content collection

set -e

DATE=$(date +%Y-%m-%d)
DB_PATH="data/aggregated.db"

# Initialize SQLite if needed
sqlite3 "$DB_PATH" "
  CREATE TABLE IF NOT EXISTS articles (
    id INTEGER PRIMARY KEY,
    source TEXT,
    url TEXT UNIQUE,
    title TEXT,
    content TEXT,
    published_date TEXT,
    collected_at DATETIME DEFAULT CURRENT_TIMESTAMP
  )
"

collect_source() {
  local NAME=$1
  local URL=$2
  local PATTERN=$3
  local PARENT=$4
  local FIELDS=$5

  echo "Collecting from $NAME..."

  ar-crawl crawl-site "$URL" \
    --url-pattern "$PATTERN" \
    --max-pages 30 \
    --output "/tmp/$NAME.json"

  ar-crawl extract "/tmp/$NAME.json" \
    --output "/tmp/$NAME-extracted.json" --format json \
    --parent "$PARENT" \
    --fields "$FIELDS"

  # Import to main database (using jq to transform)
  # This is simplified; real implementation would parse JSON properly
  echo "Imported articles from $NAME"
}

# Source 1: Tech News
collect_source "technews" \
  "https://technews.example.com/articles" \
  ".*/articles/.*" \
  "//article" \
  '{"title": ".//h1", "content": ".//div[@class=\"body\"]", "date": ".//time"}'

# Source 2: Industry Blog
collect_source "industryblog" \
  "https://industry-blog.example.com" \
  ".*/blog/.*" \
  "//div[@class='post']" \
  '{"title": ".//h2", "content": ".//div[@class=\"content\"]", "date": ".//span[@class=\"date\"]"}'

# Source 3: Company Updates (JavaScript-heavy)
ar-crawl crawl-site "https://updates.company.com" \
  -s playwright \
  --url-pattern ".*/update/.*" \
  --max-pages 20 \
  --pw-delay 3000 \
  --output "/tmp/updates.json"

ar-crawl extract "/tmp/updates.json" \
  --output "/tmp/updates-extracted.json" --format json \
  --parent "//div[@class='update-card']" \
  --fields '{"title": ".//h3", "content": ".//p", "date": ".//time"}'

echo "Aggregation complete for $DATE"
echo "Total articles: $(sqlite3 $DB_PATH 'SELECT COUNT(*) FROM articles')"
```

**Expected Outcome:** Unified database with content from all sources.

**Success Criteria:**
- All sources collected in single run
- Deduplication by URL
- Handles static and JS sites

---

## Flow 3: Archive Historical Content

Jamie needs to archive an entire section of a site.

```bash
# Full site archive
ar-crawl crawl-site https://archive-target.com/articles \
  --url-pattern ".*/articles/\d{4}/.*" \
  --max-pages 5000 \
  --max-depth 5 \
  --output archive.db --format sqlite \
  --verbose

# Check progress
sqlite3 archive.db "
  SELECT
    strftime('%Y-%m', timestamp) as month,
    COUNT(*) as pages
  FROM crawled_pages
  GROUP BY month
  ORDER BY month
"

# Extract for full-text search
ar-crawl extract archive.db \
  --output archive-searchable.json --format json \
  --parent "//article" \
  --fields '{"title": ".//h1", "body": ".//div[@class=\"content\"]", "date": ".//time", "tags": ".//a[@class=\"tag\"]"}'
```

**Expected Outcome:** Complete archive of historical content.

**Success Criteria:**
- All historical pages captured
- Full text preserved for search
- Metadata extracted

---

## Flow 4: Incremental Updates

Jamie runs hourly updates to catch new content.

```bash
#!/bin/bash
# incremental-update.sh

DB_PATH="data/feed.db"

# Get most recent crawl timestamp
LAST_RUN=$(sqlite3 "$DB_PATH" "SELECT MAX(timestamp) FROM crawled_pages" 2>/dev/null || echo "")

echo "Last run: $LAST_RUN"
echo "Checking for new content..."

# Crawl only recent pages (limit depth for speed)
ar-crawl crawl-site https://news-source.com \
  --url-pattern ".*/2024/.*" \
  --max-depth 1 \
  --max-pages 20 \
  --output /tmp/latest.json

# Check what's new
NEW_COUNT=$(cat /tmp/latest.json | grep -c '"url"' || echo "0")
echo "Found $NEW_COUNT pages"

# Merge new content into main database
if [ "$NEW_COUNT" -gt 0 ]; then
  ar-crawl extract /tmp/latest.json \
    --output /tmp/latest-data.json --format json \
    --parent "//article" \
    --fields '{"title": ".//h1", "content": ".//div[@class=\"body\"]"}'

  echo "New content added to pipeline"
fi
```

**Expected Outcome:** Efficient incremental content updates.

**Success Criteria:**
- Fast (only checks new content)
- Runs frequently without overload
- Catches new posts quickly

---

## Flow 5: Handle Different Site Structures

Jamie has sources with varying HTML structures.

```bash
# Source config file approach
cat > sources.json << 'EOF'
[
  {
    "name": "source-a",
    "url": "https://source-a.com/news",
    "pattern": ".*/news/.*",
    "service": "direct",
    "parent": "//article",
    "fields": {"title": ".//h1", "body": ".//div[@class='content']"}
  },
  {
    "name": "source-b",
    "url": "https://source-b.com/blog",
    "pattern": ".*/blog/.*",
    "service": "playwright",
    "parent": "//div[@class='post']",
    "fields": {"title": ".//h2", "body": ".//section[@class='body']"}
  }
]
EOF

# Process each source with its specific config
# (In practice, this would be a Python/Racket script parsing the JSON)
```

**Expected Outcome:** Configurable multi-source collection.

**Success Criteria:**
- Each source has own extraction rules
- Easy to add new sources
- Maintenance-friendly

---

## Flow 6: Search Corpus Building

Jamie builds a corpus for a search engine.

```bash
# Collect content
ar-crawl crawl-site https://documentation-site.com \
  --url-pattern ".*/docs/.*" \
  --max-pages 1000 \
  --output docs-corpus.db --format sqlite

# Build search-ready export
ar-crawl extract docs-corpus.db \
  --output corpus.json --format json \
  --parent "//main" \
  --fields '{"title": ".//h1", "content": ".//article", "section": ".//nav[@class=\"breadcrumb\"]//a[last()]"}'

# Index with search tool (e.g., MeiliSearch, Typesense)
# curl -X POST 'http://localhost:7700/indexes/docs/documents' \
#   -H 'Content-Type: application/json' \
#   --data-binary @corpus.json
```

**Expected Outcome:** Content ready for search engine indexing.

**Success Criteria:**
- Clean text extraction
- Metadata preserved
- Format matches search engine requirements

---

# Edge Cases and Recovery

## Site Changed HTML Structure

```bash
# Re-sample to discover new structure
ar-crawl crawl https://changed-site.com/article/123 --format json
ar-crawl sample article-123.json --length 5000

# Update extraction fields accordingly
```

## Rate Limited by Source

```bash
# Add delays and reduce page count
ar-crawl crawl-site https://strict-site.com \
  --delay 3000 \
  --max-pages 50
```

## Mixed Static and JavaScript Pages

```bash
# Probe first to determine
ar-crawl probe https://mystery-site.com -v

# Use Playwright if JS is needed
ar-crawl crawl-site https://mystery-site.com \
  -s playwright \
  --pw-delay 4000
```

## Handling Pagination

```bash
# For paginated listings, increase depth
ar-crawl crawl-site https://paginated-site.com/posts \
  --max-depth 10 \
  --url-pattern ".*/posts/page/\d+|.*/posts/[^/]+$"
```
