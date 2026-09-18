---
title: CLI commands and options
mode: reference
---

# CLI commands and options

Every command, its options, exit codes and the typo suggestion behaviour. `ar-crawl help <command>` prints the same for one command.

## Core Commands

- **`crawl <url>`** - Crawl a single URL
  ```bash
  ar-crawl crawl https://example.com --output results.json --verbose
  
  # Save to SQLite database for analysis
  ar-crawl crawl https://example.com --output results.db --format sqlite
  ```

- **`crawl-site <url>`** - Crawl an entire site with link following
  ```bash
  # Basic site crawl
  ar-crawl crawl-site https://example.com

  # Advanced site crawl with options
  ar-crawl crawl-site https://example.com \
    --verbose --output output/results.json \
    --max-pages 100 \
    --url-pattern ".*blog.*" \
    --crawl-delay 2000

  # Save site crawl to SQLite for advanced analysis
  ar-crawl crawl-site https://example.com \
    --output site-data.db --format sqlite \
    --max-pages 50 \
    --url-pattern ".*blog.*"
  ```

- **`probe <url>`** - Measure page load performance to determine optimal scraping parameters
  ```bash
  # Basic probe
  ar-crawl probe https://example.com

  # Verbose probe with detailed timing breakdown
  ar-crawl probe https://spa-site.com -v

  # Save probe results to file
  ar-crawl probe https://example.com -o probe-results.json
  ```

- **`sample <file>`** - Show sample HTML from crawl results to help figure out XPaths
  ```bash
  # Show first result (default 5000 chars)
  ar-crawl sample results.json

  # Show specific result by index
  ar-crawl sample results.json --index 2

  # Show more content
  ar-crawl sample results.json --length 10000
  ```

- **`extract <file>`** - Extract structured data from crawl results using XPath
  ```bash
  # Simple field extraction with xpath-map
  ar-crawl extract results.json --xpath-map '{
    "title": "//h1",
    "price": "//span[@class=\"price\"]"
  }'

  # Item extraction (multiple items per page)
  ar-crawl extract results.json \
    --parent "//div[@class='product']" \
    --fields '{"name": ".//h2", "price": ".//span[@class=\"price\"]"}'

  # Save extracted data to CSV
  ar-crawl extract results.json \
    --output extracted.csv --format csv \
    --xpath-map '{"title": "//h1"}'
  ```

- **`health`** - Check service health status
  ```bash
  ar-crawl health --verbose
  ```

- **`test`** - Test individual services
  ```bash
  ar-crawl test --service firecrawl --verbose
  ```

- **`services`** - List available crawling services
  ```bash
  ar-crawl services --verbose
  ```

- **`monitor`** - Real-time monitoring dashboard
  ```bash
  ar-crawl monitor --interval 5
  ```

## Configuration Commands

- **`config init`** - Create configuration file
  ```bash
  ar-crawl config init --file config/production.json --type production
  ```

- **`config show`** - Display current configuration
  ```bash
  ar-crawl config show --file config/default.json
  ```

- **`config validate`** - Validate configuration
  ```bash
  ar-crawl config validate --file config/production.json
  ```

## Command Options

### Global Options
- **`--config, -c <file>`** - Specify configuration file
- **`--verbose, -v`** - Enable verbose output and progress tracking
- **`--quiet, -q`** - Suppress non-essential output
- **`--dry-run, -n`** - Print the plan and do nothing
- **`--output, -o <file>`** - Save results to file
- **`--format <type>`** - Output format (json, csv, markdown, sqlite)
- **`--service, -s <name>`** - Use specific service (can be repeated)
- **`--no-color`** - Disable colored output (also respects `NO_COLOR` env var)
- **`--color`** - Force colored output even when not a TTY

### Site Crawling Options
- **`--max-pages <num>`** - Maximum pages to crawl (default: 50)
- **`--max-depth <num>`** - Maximum crawl depth (default: 3)
- **`--url-pattern <regex>`** - URL regex filter (default: ".*")
- **`--allow-external`** - Allow crawling external domains
- **`--crawl-delay <ms>`** - Delay between requests in ms (default: 1000)

### Sample Command Options
- **`--index <num>`** - Index of result to show (default: 0)
- **`--length <num>`** - Maximum characters to display (default: 5000)

### Extract Command Options
- **`--xpath-map <json>`** - JSON object mapping field names to XPath expressions
- **`--parent <xpath>`** - Parent XPath for item extraction (use with --fields)
- **`--fields <json>`** - JSON object mapping field names to relative XPaths (use with --parent)

## Exit Codes

AR-Crawl uses standardized exit codes following [clig.dev](https://clig.dev/) guidelines:

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Error (runtime failure, network error, etc.) |
| 2 | Usage error (invalid arguments, missing required options) |

Scripts and pipelines branch on these codes.

## Typo Suggestions

WHEN a command is mistyped, ar-crawl suggests the closest match:

```bash
$ ar-crawl crawll https://example.com
error: unknown command 'crawll'

    Did you mean 'crawl'?

Run 'ar-crawl help' for usage information.
```
