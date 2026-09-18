---
title: How to extract structured data
mode: how-to
---

# How to extract structured data

This guide covers turning crawled pages into fields and items with XPath, for a reader with a crawl result file.

AR-Crawl provides a two-step workflow for structured data extraction: first crawl pages, then extract data using XPath expressions.

## Extraction Workflow

```bash
# Step 1: Crawl the site and save results
ar-crawl crawl-site https://shop.example.com \
  --output products.json \
  --url-pattern ".*product.*" --max-pages 50

# Step 2: Explore the HTML structure
ar-crawl sample products.json

# Step 3: Extract structured data using XPath
ar-crawl extract products.json \
  --output extracted.csv --format csv \
  --parent "//div[@class='product']" \
  --fields '{"name": ".//h2", "price": ".//span[@class=\"price\"]"}'
```

## Sample Command

Use `sample` to inspect HTML content and figure out the right XPath expressions:

```bash
# Show first page's HTML (default 5000 chars)
ar-crawl sample results.json

# Show a specific page by index
ar-crawl sample results.json --index 3

# Show more content for complex pages
ar-crawl sample results.json --length 15000
```

The sample output includes the source URL and suggests how to use the `extract` command.

## Extract Command

Two extraction modes are available:

### Simple Field Extraction

Use `--xpath-map` to extract single values per page:

```bash
ar-crawl extract results.json --xpath-map '{
  "title": "//h1",
  "author": "//span[@class=\"author\"]",
  "date": "//time/@datetime"
}'
```

### Item Extraction (Multiple Items Per Page)

Use `--parent` with `--fields` to extract repeating items like product listings:

```bash
ar-crawl extract results.json \
  --parent "//div[@class='product-card']" \
  --fields '{
    "name": ".//h2/text()",
    "price": ".//span[@class=\"price\"]/text()",
    "link": ".//a/@href"
  }'
```

## Output Formats

```bash
# JSON output (default)
ar-crawl extract results.json --output data.json --xpath-map '...'

# CSV for spreadsheets
ar-crawl extract results.json --output data.csv --format csv --xpath-map '...'

# SQLite for analysis
ar-crawl extract results.json --output data.db --format sqlite --xpath-map '...'
```

## Real-World Extraction Examples

### E-commerce Product Extraction
```bash
# Crawl product pages
ar-crawl crawl-site https://shop.example.com \
  --output shop.json \
  --url-pattern ".*product.*" --max-pages 100

# Extract product data
ar-crawl extract shop.json \
  --output products.csv --format csv \
  --parent "//div[@class='product']" \
  --fields '{
    "name": ".//h2[@class=\"title\"]/text()",
    "price": ".//span[@class=\"price\"]/text()",
    "sku": ".//span[@class=\"sku\"]/text()"
  }'
```

### News Article Extraction
```bash
# Crawl news articles
ar-crawl crawl-site https://news.example.com \
  --output news.json \
  --url-pattern ".*/article/.*" --max-pages 50

# Extract article metadata
ar-crawl extract news.json \
  --output articles.json \
  --xpath-map '{
    "headline": "//h1",
    "author": "//span[@class=\"byline\"]",
    "published": "//time/@datetime",
    "summary": "//p[@class=\"lead\"]"
  }'
```

Extract and sample options are in the [CLI reference](../reference/cli.md).
