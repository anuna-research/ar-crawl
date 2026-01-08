# Flow: Extract Features to Reduce LLM Context Tokens

## User Story

As a web developer using an LLM agent, I want to extract only relevant content from crawled pages so that I minimize token usage and keep my agent's context window focused.

## The Problem

Raw HTML from a crawled page might be 50KB+ (10,000+ tokens). Your LLM agent doesn't need all of it - it just needs specific data points to make decisions.

**Before extraction:** Full HTML body with scripts, styles, boilerplate = 50,000 characters
**After extraction:** Targeted JSON with only relevant fields = 200 characters (99.6% reduction)

## The Flow

### Step 1: Crawl and Store Raw Data

```bash
# Crawl the page (store locally, don't print to stdout)
ar-crawl -s playwright crawl http://localhost:3000/dashboard \
  --pw-delay 2000 \
  --format json \
  --output /tmp/raw.json 2>/dev/null
```

### Step 2: Extract Only What You Need

```bash
# Extract targeted fields
ar-crawl extract /tmp/raw.json \
  --fields '{
    "page_title": "//title",
    "user_name": "//span[@class=\"user-name\"]",
    "notification_count": "count(//div[@class=\"notification\"])",
    "has_errors": "boolean(//div[@role=\"alert\"])"
  }' --format json

# Output: {"page_title":"Dashboard","user_name":"Taylor","notification_count":"3","has_errors":false}
# Total: ~25 tokens instead of 10,000+
```

### Step 3: Extraction Patterns for Common Use Cases

#### Boolean Checks (Yes/No Questions)

```bash
# Is user logged in?
ar-crawl extract /tmp/page.json \
  --fields '{"logged_in": "boolean(//button[@id=\"logout\"])"}'
# Output: {"logged_in": true}

# Does error message exist?
ar-crawl extract /tmp/page.json \
  --fields '{"has_error": "boolean(//div[@class=\"error-message\"])"}'
# Output: {"has_error": false}

# Is form valid?
ar-crawl extract /tmp/page.json \
  --fields '{"form_invalid": "boolean(//input[@aria-invalid=\"true\"])"}'
```

#### Count Patterns (How Many?)

```bash
# How many items in list?
ar-crawl extract /tmp/page.json \
  --fields '{"item_count": "count(//li[@class=\"item\"])"}'
# Output: {"item_count": "12"}

# How many errors?
ar-crawl extract /tmp/page.json \
  --fields '{"error_count": "count(//span[@class=\"error\"])"}'

# Multiple counts
ar-crawl extract /tmp/page.json \
  --fields '{
    "rows": "count(//tr)",
    "columns": "count(//th)",
    "images": "count(//img)"
  }'
```

#### Text Content (Strip HTML)

```bash
# Get text only, no HTML tags
ar-crawl extract /tmp/page.json \
  --fields '{"main_text": "normalize-space(//main)"}'

# First paragraph only
ar-crawl extract /tmp/page.json \
  --fields '{"intro": "normalize-space(//p[1])"}'

# Specific element text
ar-crawl extract /tmp/page.json \
  --fields '{"heading": "normalize-space(//h1)"}'
```

#### Attribute Extraction

```bash
# Get specific attributes (not full elements)
ar-crawl extract /tmp/page.json \
  --fields '{
    "form_action": "//form/@action",
    "page_lang": "//html/@lang",
    "csrf_token": "//input[@name=\"_csrf\"]/@value",
    "image_src": "//img[@id=\"hero\"]/@src"
  }'
```

#### Multiple Fields Combined

```bash
# Full verification payload
ar-crawl extract /tmp/page.json \
  --fields '{
    "title": "//title",
    "is_logged_in": "boolean(//nav//a[contains(@href,\"logout\")])",
    "username": "//span[@class=\"username\"]",
    "nav_items": "count(//nav//a)",
    "has_sidebar": "boolean(//aside)",
    "error_text": "normalize-space(//div[@class=\"error\"])",
    "form_action": "//form/@action"
  }'
```

### Step 4: Agent Workflow Integration

```bash
#!/bin/bash
# agent-test.sh - Minimal token output for LLM agent

URL="$1"
FIELDS="$2"

# Crawl silently
ar-crawl -s playwright crawl "$URL" \
  --pw-delay 2000 \
  --format json \
  --output /tmp/page.json 2>/dev/null

# Extract only what agent needs
ar-crawl extract /tmp/page.json --fields "$FIELDS" 2>/dev/null
```

Usage:

```bash
# Agent calls this with specific fields
./agent-test.sh "http://localhost:3000" '{"logged_in": "boolean(//button[@id=\"logout\"])", "username": "//span[@class=\"user\"]"}'

# Output: {"logged_in": true, "username": "taylor"}
# Just 10 tokens to agent context
```

## Token Comparison

| Scenario | Raw HTML | Extracted | Savings |
|----------|----------|-----------|---------|
| Login check | 30KB | 30 bytes | 99.9% |
| Page title | 30KB | 50 bytes | 99.8% |
| Item count | 30KB | 25 bytes | 99.9% |
| Form state | 30KB | 150 bytes | 99.5% |
| Full verification | 30KB | 300 bytes | 99.0% |

## Success Criteria

- Extraction output is <500 bytes for most checks
- Agent can make decisions from extracted data
- No irrelevant HTML in agent context
- JSON output is directly parseable

## Common XPath Patterns

```xpath
# Boolean (exists check)
boolean(//element)

# Count
count(//elements)

# Text only (strips whitespace)
normalize-space(//element)

# Attribute value
//element/@attribute

# First match
(//element)[1]

# Last match
(//element)[last()]

# Contains text
//div[contains(text(),'Error')]

# Contains class
//div[contains(@class,'active')]

# Multiple conditions
//input[@type='email' and @required]
```
