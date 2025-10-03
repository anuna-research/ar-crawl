# Using AR-Crawl Without API Keys

AR-Crawl includes a built-in **direct HTTP service** that requires **no API keys** and can crawl most websites directly.

## ✅ **What Works Without API Keys:**

- **Direct HTTP crawling** of public websites
- **HTML content extraction** 
- **Link discovery and following**
- **Title extraction**
- **Basic rate limiting and retries**
- **Fallback mechanisms**
- **All CLI commands and monitoring**

## 🚀 **Quick Start (No API Keys Required)**

### 1. **Test the Direct Service**
```bash
# Test direct HTTP service
make run ARGS='test --service direct --verbose'

# List all available services  
make run ARGS='services --verbose'
```

### 2. **Use Built-in Configuration**
```bash
# Use the direct-only configuration
make run ARGS='health --config config/direct-only.json'

# Test crawling with direct service
racket examples/direct-crawl-demo.rkt
```

### 3. **Programmatic Usage**
```racket
#lang racket

(require "src/crawl-service-adaptor.rkt")

;; Crawl any URL directly (no API key needed)
(define result (direct-http-adaptor "https://example.com"))

(if result
    (begin
      (printf "Success! Crawled: ~a~n" (hash-ref result 'url))
      (printf "Content: ~a chars~n" 
             (string-length (hash-ref result 'content))))
    (printf "Failed to crawl~n"))
```

## 🎯 **Direct Service Features**

The built-in `direct` service provides:

- ✅ **HTTP/HTTPS support**
- ✅ **Automatic redirects** (configurable)
- ✅ **Custom User-Agent** strings
- ✅ **Timeout handling**
- ✅ **HTML parsing and link extraction**
- ✅ **Title extraction**
- ✅ **Error handling with retries**

## ⚙️ **Configuration**

Create a `config/direct-only.json` file:

```json
{
  "crawler": {
    "services": ["direct"],
    "fallback_enabled": true,
    "rate_limit_ms": 1000,
    "max_concurrent_jobs": 5
  },
  "services": {
    "direct": {
      "timeout": 30000,
      "user_agent": "AR-Crawl/1.0",
      "follow_redirects": true
    }
  }
}
```

## 🛠️ **Advanced Usage**

### Crawl with Custom Settings
```racket
(direct-http-adaptor "https://example.com"
                    #:timeout 60000
                    #:user-agent "My Custom Bot 1.0"
                    #:follow-redirects #t)
```

### Use in Production Crawler
```racket
(require "src/production-crawler.rkt")

(define config (make-production-crawler-config 
                #:services '(direct)
                #:fallback-enabled #t
                #:rate-limit-ms 2000))

(define crawler (create-production-crawler config))
(start-crawling crawler "https://example.com")
```

## 🌟 **Benefits of Direct Service**

1. **No Dependencies**: Works immediately without any setup
2. **No Rate Limits**: Only limited by your connection and target site
3. **No Costs**: Completely free to use
4. **Full Control**: Customize headers, timeouts, etc.
5. **Privacy**: All requests go directly from your machine

## 🔄 **When to Use External Services**

Consider paid services (FireCrawl, ScrapingBee, etc.) when you need:

- **JavaScript rendering** for SPAs
- **Anti-bot protection bypassing**
- **Premium proxy networks**
- **CAPTCHA solving**
- **Geolocation-specific crawling**
- **High-volume enterprise features**

## 📋 **Example Output**

```bash
$ racket examples/direct-crawl-demo.rkt

AR-Crawl Direct Service Demo
============================

Testing direct HTTP service (no API keys required)...
✓ SUCCESS: Direct crawling works!

URL: https://httpbin.org/html
Title: Herman Melville - Moby-Dick
Content length: 3739 chars
Links found: 12
Method: direct-http
Timestamp: 2025-01-10T15:30:45Z

Available services:
  • direct          ← No API key required!
  • firecrawl       ← Requires API key
  • scrapingbee     ← Requires API key
  • browserless     ← Requires API key
  • scraperapi      ← Requires API key

To use without any API keys, just use 'direct' as your service!
```

## 🎯 **Summary**

**Yes!** You can absolutely use AR-Crawl without any service API keys. The built-in `direct` service provides robust web crawling capabilities for most use cases, and you get all the production features like monitoring, rate limiting, retries, and fallbacks.

**Perfect for:**
- Learning and experimentation
- Small to medium crawling projects  
- Academic research
- Personal projects
- Development and testing

**Scale up to paid services when you need advanced features like JavaScript rendering or anti-bot protection.**
