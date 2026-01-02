# Data Scientist User Profile

## Who They Are

**Name:** Dr. Sarah Chen
**Role:** Research Data Scientist
**Organization:** University research lab or data consultancy
**Technical Level:** High (Python, R, SQL, command line proficient)

## Daily Context

Sarah works on research projects that require collecting web data for analysis. She typically:

- Builds datasets from public websites for academic research
- Analyzes legal documents, scientific papers, or public records
- Creates reproducible data pipelines for her research
- Documents her data collection methodology for publication

## Goals

1. Collect structured data from websites without writing custom scrapers
2. Export data in formats compatible with analysis tools (CSV, SQLite)
3. Handle JavaScript-heavy academic databases
4. Document and reproduce data collection for peer review

## Pain Points

- Many academic databases require JavaScript rendering
- Needs to respect robots.txt and rate limits for ethical scraping
- Wants structured output without parsing HTML manually
- Commercial scraping APIs are expensive for academic budgets

## Technical Environment

- macOS or Linux workstation
- Comfortable with terminal and command-line tools
- Uses Python/R for analysis, prefers data in CSV or SQLite
- Has experience with databases and SQL queries

---

# Happy Path Flows

## Flow 1: Collect Dataset from Static Research Portal

Sarah needs to collect 500 research paper metadata entries from a university repository.

```bash
# Step 1: Test the site structure
ar-crawl crawl https://research.university.edu/papers --format json

# Step 2: Sample the HTML to find XPath patterns
ar-crawl sample papers.json --length 5000

# Step 3: Crawl the entire papers section
ar-crawl crawl-site https://research.university.edu/papers \
  --url-pattern ".*/papers/\d+.*" \
  --max-pages 500 \
  --output papers.db --format sqlite

# Step 4: Extract structured fields
ar-crawl extract papers.db \
  --output papers-data.csv --format csv \
  --parent "//article[@class='paper']" \
  --fields '{"title": ".//h1", "authors": ".//span[@class=\"authors\"]", "abstract": ".//div[@class=\"abstract\"]", "year": ".//span[@class=\"year\"]"}'

# Step 5: Load into analysis environment
sqlite3 papers.db "SELECT COUNT(*) FROM crawled_pages"
```

**Expected Outcome:** CSV file with structured paper metadata ready for R or Python analysis.

**Success Criteria:**
- Data exported in clean tabular format
- All 500 papers collected
- Reproducible with same command

---

## Flow 2: Scrape JavaScript-Heavy Legal Database

Sarah needs to collect case law from AustLII (Australian Legal Information Institute), which uses dynamic JavaScript rendering.

```bash
# Step 1: Probe the site to understand JS requirements
ar-crawl probe https://www.austlii.edu.au/cgi-bin/viewdb/au/cases/cth/HCA/ -v

# Step 2: Use Playwright service for JS rendering
ar-crawl -s playwright crawl-site https://www.austlii.edu.au/cgi-bin/viewdb/au/cases/cth/HCA/ \
  --url-pattern ".*/HCA/\d{4}/\d+.*" \
  --max-pages 200 \
  --pw-delay 3000 \
  --output hca-cases.db --format sqlite

# Step 3: Verify collection
ar-crawl sample hca-cases.db --show 3

# Step 4: Extract case details
ar-crawl extract hca-cases.db \
  --output cases.csv --format csv \
  --fields '{"case_name": "//h1", "citation": "//div[@class=\"citation\"]", "judgment": "//div[@class=\"judgment-body\"]"}'
```

**Expected Outcome:** SQLite database with case law text suitable for NLP analysis.

**Success Criteria:**
- JavaScript content properly rendered
- Rate limiting respected (no IP blocks)
- Clean text extraction for NLP pipeline

---

## Flow 3: Build Reproducible Data Pipeline

Sarah needs to document her data collection for a publication supplement.

```bash
# Create a shell script for reproducibility
cat > collect_dataset.sh << 'EOF'
#!/bin/bash
set -e

# Dataset: Technology news articles from 2024
# Collected: $(date)
# Tool: ar-crawl

ar-crawl crawl-site https://technews.example.com/articles \
  --url-pattern ".*/2024/.*" \
  --max-pages 1000 \
  --max-depth 3 \
  --output data/tech-news-2024.db --format sqlite \
  --verbose

# Extract structured data
ar-crawl extract data/tech-news-2024.db \
  --output data/articles.csv --format csv \
  --parent "//article" \
  --fields '{"headline": ".//h1", "date": ".//time/@datetime", "body": ".//div[@class=\"content\"]", "author": ".//span[@class=\"author\"]"}'

echo "Collection complete: $(sqlite3 data/tech-news-2024.db 'SELECT COUNT(*) FROM crawled_pages') pages"
EOF

chmod +x collect_dataset.sh
./collect_dataset.sh
```

**Expected Outcome:** Documented, reproducible data collection script for publication.

**Success Criteria:**
- Script runs identically on different machines
- Output is deterministic and documented
- Suitable for research reproducibility standards

---

# Edge Cases and Recovery

## Rate Limited or Blocked

```bash
# If getting 429 errors, add delays
ar-crawl crawl-site https://example.com \
  --delay 2000 \
  --max-pages 100
```

## JavaScript Not Rendering

```bash
# Increase wait times for slow sites
ar-crawl -s playwright crawl https://slow-spa.com \
  --pw-delay 10000 \
  --pw-scroll-delay 3000
```

## Missing Data in Extraction

```bash
# Re-sample to verify XPath patterns
ar-crawl sample previous-crawl.db --show 5 --length 10000

# Test extraction on single page first
ar-crawl extract previous-crawl.db \
  --max-items 1 \
  --fields '{"test": "//div[@class=\"new-selector\"]"}'
```
