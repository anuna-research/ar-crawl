---
title: Crawling services
mode: reference
---

# Crawling services

The services `-s` selects, what each renders, and what each needs.

## Playwright (local browser)
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

## FireCrawl
- **Features**: Markdown extraction, HTML cleaning, link extraction
- **Best for**: Content extraction, article parsing
- **Setup**: Get API key from [firecrawl.dev](https://firecrawl.dev)

## ScrapingBee
- **Features**: JavaScript rendering, premium proxies, geolocation
- **Best for**: Dynamic content, anti-bot protection
- **Setup**: Get API key from [scrapingbee.com](https://scrapingbee.com)

## Browserless
- **Features**: Full browser automation, stealth mode, screenshots
- **Best for**: Complex JavaScript apps, SPAs
- **Setup**: Get API key from [browserless.io](https://browserless.io)

## ScraperAPI
- **Features**: Proxy rotation, CAPTCHA solving, mobile rendering
- **Best for**: Large-scale scraping, geo-targeting
- **Setup**: Get API key from [scraperapi.com](https://scraperapi.com)
