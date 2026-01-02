# Business Analyst User Profile

## Who They Are

**Name:** Marcus Rodriguez
**Role:** Market Research Analyst
**Organization:** E-commerce company or consulting firm
**Technical Level:** Medium (spreadsheet expert, some command line experience)

## Daily Context

Marcus monitors competitors and market trends for strategic decisions. He typically:

- Tracks competitor pricing and product catalogs
- Collects market data for quarterly reports
- Monitors industry news and announcements
- Creates dashboards and presentations for executives

## Goals

1. Collect competitor product listings and prices
2. Export data to Excel-compatible formats
3. Set up repeatable data collection runs
4. Get structured data without writing code

## Pain Points

- Manual data collection is tedious and error-prone
- Browser extensions break frequently
- Needs data in spreadsheet format, not HTML
- Limited programming experience

## Technical Environment

- macOS laptop, occasionally Windows
- Strong Excel/Google Sheets skills
- Can follow command-line instructions
- Uses CSV files for data import/export

---

# Happy Path Flows

## Flow 1: Collect Competitor Product Catalog

Marcus needs to monitor a competitor's product lineup and pricing.

```bash
# Step 1: Test single product page
ar-crawl crawl https://competitor.com/products/widget-pro --format json

# Step 2: Look at the HTML structure
ar-crawl sample products.json --length 3000

# Step 3: Crawl all products
ar-crawl crawl-site https://competitor.com/products \
  --url-pattern ".*/products/[^/]+$" \
  --max-pages 500 \
  --output competitor-products.json

# Step 4: Extract product data to CSV for Excel
ar-crawl extract competitor-products.json \
  --output products.csv --format csv \
  --parent "//div[@class='product-detail']" \
  --fields '{"name": ".//h1[@class=\"product-name\"]", "price": ".//span[@class=\"price\"]", "sku": ".//span[@class=\"sku\"]", "description": ".//div[@class=\"description\"]"}'

# Open in Excel
open products.csv
```

**Expected Outcome:** CSV file that opens directly in Excel with product data.

**Success Criteria:**
- All products captured with prices
- CSV imports cleanly into Excel
- Can be run weekly for updates

---

## Flow 2: Monitor Industry News

Marcus needs to collect recent news about the industry for a market report.

```bash
# Crawl news section
ar-crawl crawl-site https://industry-news.com/technology \
  --url-pattern ".*/technology/2024/.*" \
  --max-pages 100 \
  --max-depth 2 \
  --output tech-news.json

# Extract headlines and summaries
ar-crawl extract tech-news.json \
  --output news-summary.csv --format csv \
  --parent "//article" \
  --fields '{"headline": ".//h1", "date": ".//time", "summary": ".//p[@class=\"lead\"]", "url": "ancestor::*/@data-url"}'
```

**Expected Outcome:** Spreadsheet of recent industry headlines for report.

**Success Criteria:**
- Recent articles captured with dates
- Ready for copy-paste into PowerPoint

---

## Flow 3: Price Monitoring Across Multiple Competitors

Marcus runs weekly price checks across three competitors.

```bash
#!/bin/bash
# Weekly price collection script

DATE=$(date +%Y-%m-%d)
mkdir -p data/$DATE

# Competitor A
ar-crawl crawl-site https://competitor-a.com/shop \
  --url-pattern ".*/product/.*" \
  --max-pages 200 \
  --output data/$DATE/competitor-a.json

ar-crawl extract data/$DATE/competitor-a.json \
  --output data/$DATE/prices-a.csv --format csv \
  --parent "//div[@class='product']" \
  --fields '{"name": ".//h2", "price": ".//span[@class=\"current-price\"]"}'

# Competitor B
ar-crawl -s playwright crawl-site https://competitor-b.com/catalog \
  --url-pattern ".*/item/.*" \
  --max-pages 200 \
  --pw-delay 2000 \
  --output data/$DATE/competitor-b.json

ar-crawl extract data/$DATE/competitor-b.json \
  --output data/$DATE/prices-b.csv --format csv \
  --parent "//div[@class='catalog-item']" \
  --fields '{"name": ".//h3", "price": ".//div[@class=\"price\"]"}'

# Competitor C
ar-crawl crawl-site https://competitor-c.com/all-products \
  --url-pattern ".*/p/.*" \
  --max-pages 200 \
  --output data/$DATE/competitor-c.json

ar-crawl extract data/$DATE/competitor-c.json \
  --output data/$DATE/prices-c.csv --format csv \
  --parent "//li[@class='product-card']" \
  --fields '{"name": ".//a[@class=\"title\"]", "price": ".//span[@class=\"amount\"]"}'

echo "Price collection complete for $DATE"
echo "Files saved to data/$DATE/"
```

**Expected Outcome:** Weekly price snapshots from all competitors.

**Success Criteria:**
- Consistent data format across competitors
- Historical data preserved in dated folders
- Can run as scheduled task (cron)

---

## Flow 4: Quick One-Off Data Collection

Marcus needs to quickly grab a table from a webpage.

```bash
# Grab page with a data table
ar-crawl crawl https://stats-site.com/market-share-2024 --format json

# Sample to find the table
ar-crawl sample market-share.json

# Extract table rows
ar-crawl extract market-share.json \
  --output market-share.csv --format csv \
  --parent "//table[@id='market-data']//tr" \
  --fields '{"company": ".//td[1]", "share": ".//td[2]", "growth": ".//td[3]"}'
```

**Expected Outcome:** Quick CSV export of tabular data.

**Success Criteria:**
- Minimal commands for simple extraction
- Data ready for Excel in under 5 minutes

---

# Edge Cases and Recovery

## JavaScript-Heavy E-commerce Site

```bash
# Use Playwright for React/Vue sites
ar-crawl -s playwright crawl-site https://spa-store.com/products \
  --pw-delay 5000 \
  --pw-scroll-delay 2000 \
  --max-pages 100
```

## Price in Wrong Format (Includes Currency Symbol)

```bash
# Extract raw, clean in Excel later
# Or use more specific XPath
ar-crawl extract data.json \
  --fields '{"price_raw": ".//span[@class=\"price\"]"}'
# Then use Excel formulas to clean: =VALUE(SUBSTITUTE(A1,"$",""))
```

## Site Structure Changed

```bash
# Re-sample to find new selectors
ar-crawl sample old-data.json --length 5000

# Test new XPath on fresh crawl
ar-crawl crawl https://competitor.com/products/sample-item --format json
ar-crawl sample sample-item.json
```
