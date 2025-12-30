# AR-Crawl - Production Web Crawler

A robust, production-ready web crawler with service fallbacks and **comprehensive site crawling capabilities**, built in Racket. Supports multiple crawling services including FireCrawl, ScrapingBee, Browserless, and ScraperAPI with automatic failover.

## Features

- **🆓 No API Keys Required**: Built-in direct HTTP service works immediately
- **🕷️ Site-Wide Crawling**: Intelligent link discovery and following with regex filtering
- **🎭 Local Playwright Integration**: Built-in browser rendering for JavaScript-heavy sites (auto-spawns)
- **Multi-Service Support**: Integrates with FireCrawl, ScrapingBee, Browserless, and ScraperAPI
- **Automatic Fallbacks**: Seamless failover between services when one fails
- **URL Filtering**: Advanced regex-based URL pattern matching and domain restrictions
- **Queue Management**: Efficient crawl queue with deduplication and depth control
- **Progress Tracking**: Real-time progress reporting and comprehensive statistics
- **Robust Error Handling**: Comprehensive retry mechanisms and error recovery
- **Production Ready**: Docker support, monitoring, health checks, and logging
- **CLI Interface**: Easy-to-use command-line tool with extensive options
- **Multiple Output Formats**: JSON, CSV, Markdown, and SQLite database export capabilities with full SQL querying support
- **Configuration Management**: Flexible JSON-based configuration with environment variable support
- **Real-time Monitoring**: Built-in dashboard and metrics collection

## Quick Start

### Prerequisites

- [Racket](https://racket-lang.org/) 8.0 or higher
- [Node.js](https://nodejs.org/) 18+ (optional, for Playwright browser rendering)
- Docker (optional, for containerized deployment)
- API keys for desired crawling services (optional - direct and Playwright work without keys)

### Installation

1. **Clone the repository:**
   ```bash
   git clone <repository-url>
   cd ar-crawl
   ```

2. **Setup the environment:**
   ```bash
   make setup
   ```

3. **Install dependencies:**
   ```bash
   make install
   ```

4. **Configure API keys:**
   Edit the `.env` file created by setup:
   ```bash
   FIRECRAWL_API_KEY=your_firecrawl_api_key_here
   SCRAPINGBEE_API_KEY=your_scrapingbee_api_key_here
   BROWSERLESS_API_KEY=your_browserless_api_key_here
   SCRAPERAPI_API_KEY=your_scraperapi_api_key_here
   ```

### Basic Usage

**🆓 Crawl without API keys (using built-in direct service):**
```bash
# Test the direct service (no API key needed)
make run ARGS='test --service direct --verbose'

# Use direct-only configuration
make run ARGS='health --config config/direct-only.json'

# Run the direct crawling demo
racket examples/direct-crawl-demo.rkt
```

**🎭 Crawl JavaScript-heavy sites with Playwright:**
```bash
# Playwright auto-starts when needed (first run installs dependencies)
ar-crawl -s playwright crawl https://spa-example.com

# Site crawl with browser rendering
ar-crawl -s playwright -v crawl-site https://react-app.com --max-pages 20
```

**Crawl a single URL:**
```bash
make run ARGS='crawl https://example.com'

# Or save directly to SQLite database
racket src/cli.rkt --output results.db --format sqlite crawl https://example.com
```

**🕷️ Crawl an entire site:**
```bash
# Basic site crawl
racket src/cli.rkt crawl-site https://example.com

# Advanced site crawl with filtering and limits
racket src/cli.rkt --verbose --output output/site-results.json \
  crawl-site https://example.com \
  --max-pages 50 \
  --url-pattern ".*example\.com.*(blog|news).*" \
  --crawl-delay 1000
```

**Check service health:**
```bash
make run ARGS='health'
```

**List available services:**
```bash
make run ARGS='services --verbose'
```

**Test services:**
```bash
make run ARGS='test --verbose'
```

## CLI Commands

### Core Commands

- **`crawl <url>`** - Crawl a single URL
  ```bash
  ar-crawl crawl https://example.com --output results.json --verbose
  
  # Save to SQLite database for analysis
  ar-crawl --output results.db --format sqlite crawl https://example.com
  ```

- **`crawl-site <url>`** - Crawl an entire site with link following
  ```bash
  # Basic site crawl  
  ar-crawl crawl-site https://example.com
  
  # Advanced site crawl with options
  ar-crawl --verbose --output output/results.json \
    crawl-site https://example.com \
    --max-pages 100 \
    --url-pattern ".*blog.*" \
    --crawl-delay 2000
  
  # Save site crawl to SQLite for advanced analysis
  ar-crawl --output site-data.db --format sqlite \
    crawl-site https://example.com \
    --max-pages 50 \
    --url-pattern ".*blog.*"
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

### Configuration Commands

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

### Command Options

#### Global Options (must come before command)
- **`--config <file>`** - Specify configuration file
- **`--verbose`** - Enable verbose output and progress tracking
- **`--output <file>`** - Save results to file
- **`--format <type>`** - Output format (json, csv, markdown, sqlite)

#### Service Options
- **`--service <name>`** - Use specific service (can be repeated)

#### Site Crawling Options
- **`--max-pages <num>`** - Maximum pages to crawl (default: 50)
- **`--max-depth <num>`** - Maximum crawl depth (default: 3)
- **`--url-pattern <regex>`** - URL regex filter (default: ".*")
- **`--allow-external`** - Allow crawling external domains
- **`--crawl-delay <ms>`** - Delay between requests in ms (default: 1000)

**⚠️ Important:** Global options like `--verbose`, `--output` must come **before** the command name:
```bash
# ✅ CORRECT
racket src/cli.rkt --verbose --output results.json crawl-site https://example.com

# ❌ WRONG
racket src/cli.rkt crawl-site https://example.com --verbose --output results.json
```

## Site Crawling

AR-Crawl provides powerful site-wide crawling capabilities with intelligent link discovery, URL filtering, and comprehensive queue management.

### Basic Site Crawling

```bash
# Crawl entire site (same domain only)
racket src/cli.rkt crawl-site https://example.com

# Crawl with custom limits
racket src/cli.rkt crawl-site https://example.com --max-pages 100 --max-depth 5
```

### Advanced Filtering

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

### Output and Results

```bash
# Save comprehensive results with progress tracking
racket src/cli.rkt --verbose --output output/crawl-results.json \
  crawl-site https://example.com \
  --max-pages 50 \
  --crawl-delay 2000

# Export as CSV for analysis
racket src/cli.rkt --output results.csv --format csv \
  crawl-site https://example.com --max-pages 25

# Generate Markdown report
racket src/cli.rkt --output report.md --format markdown \
  crawl-site https://example.com --max-pages 30

# Save to SQLite database (compact, queryable)
racket src/cli.rkt --output crawl-data.db --format sqlite \
  crawl-site https://example.com --max-pages 50
```

### Real-World Examples

#### Legal Database Crawling (AustLII)
```bash
# Crawl Australian legal cases to JSON
racket src/cli.rkt --verbose --output output/austlii-cases.json \
  crawl-site https://www.austlii.edu.au/ \
  --max-pages 50 \
  --url-pattern ".*austlii\.edu\.au.*(cases|HCA).*" \
  --crawl-delay 2000

# Crawl to SQLite for legal research analysis
racket src/cli.rkt --verbose --output output/austlii-cases.db --format sqlite \
  crawl-site https://www.austlii.edu.au/ \
  --max-pages 50 \
  --url-pattern ".*austlii\.edu\.au.*(cases|HCA).*" \
  --crawl-delay 2000
```

#### Academic Research
```bash
# Crawl university research pages to JSON
racket src/cli.rkt --verbose --output output/research.json \
  crawl-site https://university.edu/research/ \
  --url-pattern ".*(research|publications|papers).*" \
  --max-pages 75 \
  --crawl-delay 1500

# Crawl to SQLite for research analysis and citation tracking
racket src/cli.rkt --verbose --output output/research.db --format sqlite \
  crawl-site https://university.edu/research/ \
  --url-pattern ".*(research|publications|papers).*" \
  --max-pages 75 \
  --crawl-delay 1500
```

#### News and Media Sites
```bash
# Crawl recent news articles to JSON
racket src/cli.rkt --verbose --output output/news.json \
  crawl-site https://news-site.com \
  --url-pattern ".*/(202[4-5]|latest|breaking).*" \
  --max-pages 100 \
  --crawl-delay 1000

# Crawl to SQLite for news analysis and trend tracking
racket src/cli.rkt --verbose --output output/news.db --format sqlite \
  crawl-site https://news-site.com \
  --url-pattern ".*/(202[4-5]|latest|breaking).*" \
  --max-pages 100 \
  --crawl-delay 1000
```

### Site Crawl Output Structure

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

## SQLite Database Output

AR-Crawl supports SQLite database output as a powerful, queryable alternative to JSON. SQLite is ideal for data analysis, research projects, and when you need to run complex queries on crawl data.

### SQLite Benefits

- **SQL Queryable**: Run complex analysis queries with JOINs, aggregations, and filters
- **Indexed Searches**: Fast lookups on URLs, domains, content, and timestamps
- **Structured Schema**: Normalized relational data with proper foreign keys
- **Zero Configuration**: Works immediately with no database setup required
- **Tool Integration**: Direct import into Excel, R, Python pandas, Tableau, and more
- **Research Ready**: Perfect for academic research, content analysis, and data science

### Basic Usage

```bash
# Crawl single URL to SQLite
racket src/cli.rkt --output results.db --format sqlite crawl https://example.com

# Crawl entire site to database
racket src/cli.rkt --output site-data.db --format sqlite \
  crawl-site https://news-site.com --max-pages 100

# Crawl with filters and save to SQLite
racket src/cli.rkt --output research.db --format sqlite \
  crawl-site https://university.edu \
  --url-pattern ".*research.*" \
  --max-pages 50
```

### SQL Analysis Examples

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

### Database Schema

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

### Data Export and Integration

```bash
# Run the interactive demo
racket examples/sqlite-output-demo.rkt

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

### Integration with Analysis Tools

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

### Crawling Best Practices

- **Respect Rate Limits**: Use `--crawl-delay` to be respectful to target sites
- **Use URL Patterns**: Filter crawling to relevant content only
- **Monitor Progress**: Use `--verbose` to track crawling progress
- **Save Results**: Always use `--output` to preserve crawled data
- **Test First**: Start with small `--max-pages` values to test patterns
- **Domain Boundaries**: Default behavior respects same-domain restrictions

## Configuration

### Configuration Files

AR-Crawl uses JSON configuration files located in the `config/` directory:

- `config/default.json` - Default development configuration
- `config/production.json` - Production configuration template

### Configuration Structure

```json
{
  "crawler": {
    "services": ["playwright", "firecrawl", "scrapingbee", "browserless"],
    "fallback_enabled": true,
    "max_concurrent_jobs": 50,
    "rate_limit_ms": 1000,
    "retry_attempts": 3,
    "timeout_ms": 30000,
    "enable_monitoring": true,
    "log_level": "info",
    "output_format": "json"
  },
  "services": {
    "firecrawl": {
      "api_key": "${FIRECRAWL_API_KEY}",
      "formats": ["markdown", "html"],
      "only_main_content": true
    },
    "scrapingbee": {
      "api_key": "${SCRAPINGBEE_API_KEY}",
      "render_js": true,
      "premium_proxy": false
    }
  },
  "monitoring": {
    "metrics_enabled": true,
    "health_check_interval": 300
  }
}
```

### Environment Variables

Set these in your `.env` file or environment:

```bash
# Service API Keys
FIRECRAWL_API_KEY=your_key_here
SCRAPINGBEE_API_KEY=your_key_here
BROWSERLESS_API_KEY=your_key_here
SCRAPERAPI_API_KEY=your_key_here

# Configuration
LOG_LEVEL=info
MAX_CONCURRENT_JOBS=10
RATE_LIMIT_MS=1000
```

## Docker Deployment

### Build and Run

```bash
# Build Docker image
make docker-build

# Run with Docker Compose
make docker-run

# View logs
make docker-logs

# Stop containers
make docker-stop
```

### Docker Compose Services

The `docker-compose.yml` includes:

- **ar-crawl** - Main crawler service
- **redis** - Caching and rate limiting (optional)
- **postgres** - Result storage (optional)
- **prometheus** - Metrics collection (optional)
- **grafana** - Monitoring dashboards (optional)

### Production Deployment

1. **Setup production configuration:**
   ```bash
   make prod-setup
   ```

2. **Configure environment variables:**
   ```bash
   cp .env.example .env
   # Edit .env with your production values
   ```

3. **Deploy with Docker:**
   ```bash
   docker-compose -f docker-compose.yml -f docker-compose.prod.yml up -d
   ```

## Supported Services

### Playwright (Local Browser - Recommended for SPAs)
- **Features**: Full JavaScript rendering, auto-spawning service, no API keys needed
- **Best for**: Single-page applications (SPAs), JavaScript-heavy sites, dynamic content
- **Setup**: Requires Node.js 18+. Dependencies auto-install on first use.

```bash
# Use Playwright for JS-heavy sites (service auto-starts)
ar-crawl -s playwright crawl https://spa-example.com

# Verbose mode shows service startup
ar-crawl -s playwright -v crawl https://example.com

# Fallback: try Playwright first, then direct HTTP
ar-crawl -s playwright -s direct crawl https://example.com
```

**Environment Variables:**
- `PLAYWRIGHT_SERVICE_PORT` - Custom port (default: `3033`)
- `PLAYWRIGHT_SERVICE_URL` - Full service URL override

### FireCrawl
- **Features**: Markdown extraction, HTML cleaning, link extraction
- **Best for**: Content extraction, article parsing
- **Setup**: Get API key from [firecrawl.dev](https://firecrawl.dev)

### ScrapingBee
- **Features**: JavaScript rendering, premium proxies, geolocation
- **Best for**: Dynamic content, anti-bot protection
- **Setup**: Get API key from [scrapingbee.com](https://scrapingbee.com)

### Browserless
- **Features**: Full browser automation, stealth mode, screenshots
- **Best for**: Complex JavaScript apps, SPAs
- **Setup**: Get API key from [browserless.io](https://browserless.io)

### ScraperAPI
- **Features**: Proxy rotation, CAPTCHA solving, mobile rendering
- **Best for**: Large-scale scraping, geo-targeting
- **Setup**: Get API key from [scraperapi.com](https://scraperapi.com)

## Monitoring and Health Checks

### Health Checks

Check overall system health:
```bash
ar-crawl health --verbose
```

Monitor services in real-time:
```bash
ar-crawl monitor --interval 10
```

### Metrics

The crawler collects metrics on:
- Request success/failure rates
- Response times
- Service availability
- Error types and frequencies

### Logging

Logs are written to:
- Console (controlled by log level)
- File logs (in `logs/` directory when configured)
- Docker logs (when running in containers)

Log levels: `debug`, `info`, `warning`, `error`

## Examples and Demos

### SQLite Output Demo
Run the comprehensive SQLite demo to see database capabilities:
```bash
racket examples/sqlite-output-demo.rkt
```

This demo shows:
- Creating SQLite databases from crawl data
- Running analysis queries 
- Exporting data back to JSON
- CLI usage examples

### Other Examples
- **Direct crawling** (no API keys): `racket examples/direct-crawl-demo.rkt`
- **Site crawling**: See examples in the CLI help and this README

## Development

### Project Structure

```
ar-crawl/
├── src/
│   ├── cli.rkt                    # CLI interface with site crawling
│   ├── production-crawler.rkt     # Main crawler engine
│   ├── site-crawler.rkt           # Site-wide crawling with link following
│   ├── crawl-service-adaptor.rkt  # Service adapters (incl. Playwright)
│   ├── config-manager.rkt         # Configuration management
│   ├── scraper-interfaces.rkt     # Data structures and contracts
│   ├── data-formatter.rkt         # Output formatting (JSON, CSV, SQLite)
│   ├── sqlite-formatter.rkt       # SQLite database output
│   ├── proxy-adaptor.rkt          # Legacy proxy adapters
│   └── utils.rkt                  # Utility functions
├── playwright-service/            # Local Playwright browser service
│   ├── package.json               # Node.js dependencies
│   └── server.js                  # HTTP server wrapping Playwright
├── config/
│   ├── default.json              # Default configuration
│   ├── direct-only.json          # Direct service only (no API keys)
│   └── production.json           # Production configuration
├── output/                       # Crawl results (gitignored)
├── examples/                     # Usage examples and demos
│   ├── sqlite-output-demo.rkt    # SQLite demo and examples
│   └── direct-crawl-demo.rkt     # Direct crawling demo
├── Dockerfile                    # Container definition
├── docker-compose.yml           # Multi-service setup
├── Makefile                     # Build automation
└── README.md                    # This file
```

### Running Tests

```bash
make test
```

### Development Workflow

1. **Make changes to source files**
2. **Test changes:**
   ```bash
   make dev-test
   ```
3. **Run in development mode:**
   ```bash
   make dev-run
   ```

### Adding New Services

1. **Implement service adapter** in `crawl-service-adaptor.rkt`
2. **Register service** in the service registry
3. **Add configuration** schema
4. **Update tests** and documentation

## Troubleshooting

### Common Issues

**"No API key found"**
- Ensure API keys are set in `.env` file
- Check configuration file has correct variable names
- Verify environment variable substitution is working

**"Service unavailable"**
- Check service health: `ar-crawl health`
- Verify API keys are valid
- Check service-specific status pages

**"Rate limit exceeded"**
- Increase `rate_limit_ms` in configuration
- Use premium proxy services
- Spread requests across multiple services

### Debug Mode

Enable verbose logging:
```bash
ar-crawl crawl https://example.com --verbose
```

Check configuration:
```bash
ar-crawl config show --file config/default.json
```

### Getting Help

- Check command help: `ar-crawl <command> --help`
- View configuration: `ar-crawl config show`
- Test services: `ar-crawl test --verbose`
- Monitor in real-time: `ar-crawl monitor`

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests
5. Submit a pull request

## License

[Add your license here]

## Support

For support and questions:
- Create an issue in the repository
- Check the troubleshooting section
- Review service documentation for API-specific issues

---

**AR-Crawl** - Production-ready web crawling with service fallbacks.
