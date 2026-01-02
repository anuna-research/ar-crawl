# LLM Agent User Profile

## Who They Are

**Name:** Claude / GPT / Gemini (AI Assistant)
**Role:** Autonomous coding agent
**Organization:** Integrated into developer workflows via Claude Code, Cursor, Aider, etc.
**Technical Level:** Expert (full programming capability, but operates through CLI)

## Daily Context

The LLM agent assists human developers with tasks that involve web data. They typically:

- Execute commands on behalf of users who describe goals in natural language
- Need tools that work reliably with minimal configuration
- Require clear, parseable output for decision-making
- Operate in interactive sessions where speed matters

## Goals

1. Execute web scraping tasks with single commands when possible
2. Get structured output that can be processed programmatically
3. Handle errors gracefully with clear diagnostic messages
4. Work without requiring API keys or complex setup

## Pain Points

- Verbose or inconsistent output is hard to parse
- Interactive prompts block automation
- Unclear error messages require human intervention
- Complex multi-step setup fails in automated contexts

## Technical Environment

- Terminal-based interaction only (no GUI)
- Can execute bash commands and read files
- Prefers JSON output for structured data
- Needs quiet mode for clean output parsing

---

# Happy Path Flows

## Flow 1: Quick Content Fetch for User Question

User asks: "What does the homepage of example.com say?"

```bash
# Simple fetch with minimal output
ar-crawl crawl https://example.com --format json --output /tmp/page.json

# Extract readable content
ar-crawl extract /tmp/page.json --fields '{"title": "//title", "main": "//body"}'
```

**Expected Outcome:** Quick content retrieval to answer user question.

**Success Criteria:**
- Single command execution
- Clean output without progress bars
- Content ready to summarize for user

---

## Flow 2: Gather Data for Code Generation

User asks: "Scrape the API documentation and help me write a client."

```bash
# Crawl documentation section
ar-crawl crawl-site https://api.service.com/docs \
  --url-pattern ".*/docs/.*" \
  --max-pages 50 \
  --output /tmp/api-docs.db --format sqlite

# Extract API endpoint information
ar-crawl extract /tmp/api-docs.db \
  --output /tmp/endpoints.json --format json \
  --parent "//div[@class='endpoint']" \
  --fields '{"method": ".//span[@class=\"method\"]", "path": ".//span[@class=\"path\"]", "description": ".//p[@class=\"desc\"]"}'

# Read the extracted data
cat /tmp/endpoints.json
```

**Expected Outcome:** Structured API data to inform code generation.

**Success Criteria:**
- Documentation captured in structured format
- Can be read and parsed by agent
- Informs accurate code generation

---

## Flow 3: Verify Web Application State

User asks: "Check if the deployment is working."

```bash
# Quick health check with Playwright for JS apps
ar-crawl -s playwright crawl https://app.example.com \
  --pw-delay 3000 \
  --format json \
  --output /tmp/check.json

# Verify expected content exists
ar-crawl extract /tmp/check.json --fields '{"app_root": "//div[@id=\"app\"]", "title": "//title"}'
```

**Expected Outcome:** Confirmation that app is rendering correctly.

**Success Criteria:**
- Clear pass/fail determination
- Works for JavaScript applications
- Fast enough for interactive use

---

## Flow 4: Research Task - Collect Information

User asks: "Find all the pricing tiers on competitor.com"

```bash
# Crawl pricing pages
ar-crawl crawl https://competitor.com/pricing --format json --output /tmp/pricing.json

# Sample to understand structure
ar-crawl sample /tmp/pricing.json --length 3000

# Extract pricing data
ar-crawl extract /tmp/pricing.json \
  --parent "//div[@class='pricing-tier']" \
  --fields '{"name": ".//h3", "price": ".//span[@class=\"price\"]", "features": ".//ul[@class=\"features\"]"}'
```

**Expected Outcome:** Pricing information ready to present to user.

**Success Criteria:**
- Complete pricing data extracted
- Structured for easy summarization
- Can answer follow-up questions

---

## Flow 5: Build Dataset for Analysis

User asks: "Collect the last 100 blog posts from this site for analysis."

```bash
# Crawl blog section
ar-crawl crawl-site https://blog.example.com \
  --url-pattern ".*/posts/.*" \
  --max-pages 100 \
  --output /tmp/blog.db --format sqlite

# Extract article data
ar-crawl extract /tmp/blog.db \
  --output /tmp/articles.json --format json \
  --parent "//article" \
  --fields '{"title": ".//h1", "date": ".//time/@datetime", "content": ".//div[@class=\"content\"]", "author": ".//span[@class=\"author\"]"}'

# Verify collection
sqlite3 /tmp/blog.db "SELECT COUNT(*) as total_pages FROM crawled_pages"
```

**Expected Outcome:** Dataset ready for user's analysis.

**Success Criteria:**
- All requested posts collected
- Structured data in usable format
- Can proceed with analysis tasks

---

## Flow 6: Troubleshoot Crawling Issues

When initial crawl fails, diagnose and retry.

```bash
# Check if site needs JavaScript
ar-crawl probe https://problem-site.com -v

# If JS is needed, retry with Playwright
ar-crawl -s playwright crawl https://problem-site.com \
  --pw-delay 5000 \
  --format json \
  --output /tmp/retry.json

# Verify content was captured
ar-crawl sample /tmp/retry.json --length 1000
```

**Expected Outcome:** Successful crawl after adjusting approach.

**Success Criteria:**
- Clear diagnostic information from probe
- Automatic service selection guidance
- Recovery without user intervention

---

# Recommended Patterns for LLM Agents

## Use Quiet Mode

```bash
# Quiet mode reduces noise in output
ar-crawl crawl https://example.com --format json 2>/dev/null
```

## Prefer JSON Output

```bash
# JSON is easiest to parse programmatically
ar-crawl extract data.json --format json --fields '{"key": "//selector"}'
```

## Use SQLite for Large Collections

```bash
# SQLite allows SQL queries for data exploration
ar-crawl crawl-site https://example.com --output data.db --format sqlite
sqlite3 data.db "SELECT url, title FROM crawled_pages LIMIT 10"
```

## Check Service Availability First

```bash
# Verify services before attempting JS-heavy sites
ar-crawl health
```

## Handle Errors Gracefully

```bash
# Check exit codes
ar-crawl crawl https://example.com --format json || echo "Crawl failed, trying Playwright"
ar-crawl -s playwright crawl https://example.com --format json
```

---

# Edge Cases and Recovery

## Site Requires JavaScript

```bash
# Probe first, then use appropriate service
ar-crawl probe https://spa-site.com
# If "dynamic content detected", use Playwright
ar-crawl -s playwright crawl https://spa-site.com --pw-delay 5000
```

## Rate Limited

```bash
# Add delays between requests
ar-crawl crawl-site https://strict-site.com --delay 2000 --max-pages 50
```

## Empty Output

```bash
# Sample to debug XPath selectors
ar-crawl sample previous-crawl.json --length 5000
# Adjust selectors based on actual HTML structure
```

## Timeout on Slow Sites

```bash
# Increase delays for slow-loading pages
ar-crawl -s playwright crawl https://slow-site.com \
  --pw-delay 10000 \
  --timeout 60000
```
