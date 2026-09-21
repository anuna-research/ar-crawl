---
title: Configuration file and environment
mode: reference
---

# Configuration file and environment

Configuration files, their JSON structure, and the environment variables ar-crawl reads.

## Configuration Files

AR-Crawl uses JSON configuration files located in the `config/` directory:

- `config/default.json` - Default development configuration
- `config/production.json` - Production configuration template

## Configuration Structure

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

## Environment Variables

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

## Playwright service variables

- `PLAYWRIGHT_SERVICE_PORT` - Custom port (default: `3033`)
- `PLAYWRIGHT_SERVICE_URL` - Full service URL override
