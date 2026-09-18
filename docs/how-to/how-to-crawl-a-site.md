---
title: How to crawl a site
mode: how-to
---

# How to crawl a site

This guide covers crawling a whole site with `crawl-site`, for a reader who has run a single `crawl`.

## Basic Site Crawling

```bash
# Crawl entire site (same domain only)
racket src/cli.rkt crawl-site https://example.com

# Crawl with custom limits
racket src/cli.rkt crawl-site https://example.com --max-pages 100 --max-depth 5
```

## Advanced Filtering

```bash
# Only crawl blog posts and news articles
racket src/cli.rkt crawl-site https://example.com \
  --url-pattern ".*(blog|news|article).*" \
  --max-pages 50

# Only crawl PDFs and documents
racket src/cli.rkt crawl-site https://example.com \
  --url-pattern ".*\.(pdf|doc|docx)$" \
  --max-pages 20

# Crawl specific year/date patterns
racket src/cli.rkt crawl-site https://news-site.com \
  --url-pattern ".*/202[4-5]/.*" \
  --max-pages 100
```

## Output and Results

```bash
# Save comprehensive results with progress tracking
racket src/cli.rkt crawl-site https://example.com \
  --verbose --output output/crawl-results.json \
  --max-pages 50 \
  --crawl-delay 2000

# Export as CSV for analysis
racket src/cli.rkt crawl-site https://example.com \
  --output results.csv --format csv --max-pages 25

# Generate Markdown report
racket src/cli.rkt crawl-site https://example.com \
  --output report.md --format markdown --max-pages 30

# Save to SQLite database (compact, queryable)
racket src/cli.rkt crawl-site https://example.com \
  --output crawl-data.db --format sqlite --max-pages 50
```

## Real-World Examples

### Legal Database Crawling (AustLII)
```bash
# Crawl Australian legal cases to JSON
racket src/cli.rkt crawl-site https://www.austlii.edu.au/ \
  --verbose --output output/austlii-cases.json \
  --max-pages 50 \
  --url-pattern ".*austlii\.edu\.au.*(cases|HCA).*" \
  --crawl-delay 2000

# Crawl to SQLite for legal research analysis
racket src/cli.rkt crawl-site https://www.austlii.edu.au/ \
  --verbose --output output/austlii-cases.db --format sqlite \
  --max-pages 50 \
  --url-pattern ".*austlii\.edu\.au.*(cases|HCA).*" \
  --crawl-delay 2000
```

### Academic Research
```bash
# Crawl university research pages to JSON
racket src/cli.rkt crawl-site https://university.edu/research/ \
  --verbose --output output/research.json \
  --url-pattern ".*(research|publications|papers).*" \
  --max-pages 75 \
  --crawl-delay 1500

# Crawl to SQLite for research analysis and citation tracking
racket src/cli.rkt crawl-site https://university.edu/research/ \
  --verbose --output output/research.db --format sqlite \
  --url-pattern ".*(research|publications|papers).*" \
  --max-pages 75 \
  --crawl-delay 1500
```

### News and Media Sites
```bash
# Crawl recent news articles to JSON
racket src/cli.rkt crawl-site https://news-site.com \
  --verbose --output output/news.json \
  --url-pattern ".*/(202[4-5]|latest|breaking).*" \
  --max-pages 100 \
  --crawl-delay 1000

# Crawl to SQLite for news analysis and trend tracking
racket src/cli.rkt crawl-site https://news-site.com \
  --verbose --output output/news.db --format sqlite \
  --url-pattern ".*/(202[4-5]|latest|breaking).*" \
  --max-pages 100 \
  --crawl-delay 1000
```

## Working practices

- **Respect Rate Limits**: Use `--crawl-delay` to be respectful to target sites
- **Use URL Patterns**: Filter crawling to relevant content only
- **Monitor Progress**: Use `--verbose` to track crawling progress
- **Save Results**: Always use `--output` to preserve crawled data
- **Test First**: Start with small `--max-pages` values to test patterns
- **Domain Boundaries**: The default stays on the seed's domain

The output document is described in [Site crawl output](../reference/site-crawl-output.md); every flag is in the [CLI reference](../reference/cli.md).
