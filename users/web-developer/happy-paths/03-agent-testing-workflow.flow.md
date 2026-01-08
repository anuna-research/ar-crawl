# Flow: Complete LLM Agent Testing Workflow

## User Story

As a web developer, I want to provide ar-crawl as a CLI tool to my LLM agent so that it can test my web app autonomously with minimal token overhead.

## The Complete Workflow

### Step 1: Prepare Your Agent

Tell your LLM agent (Claude Code, Cursor, etc.) about ar-crawl:

```
You have access to ar-crawl, a CLI tool for testing web applications.

Commands:
- ar-crawl -s playwright crawl <url> --format json --output /tmp/page.json
- ar-crawl extract /tmp/page.json --fields '<json-xpath-map>'
- ar-crawl probe <url> (to check page load timing)
- ar-crawl sample /tmp/page.json (to see raw HTML structure)

Always use extract with minimal fields to keep context small.
```

### Step 2: Agent Tests a Feature

**User prompt to agent:** "Verify the login page has all required fields"

**Agent executes:**

```bash
# Crawl the login page
ar-crawl -s playwright crawl http://localhost:3000/login \
  --pw-delay 2000 \
  --format json \
  --output /tmp/login.json 2>/dev/null

# Extract only verification data
ar-crawl extract /tmp/login.json \
  --fields '{
    "has_email_field": "boolean(//input[@type=\"email\"])",
    "has_password_field": "boolean(//input[@type=\"password\"])",
    "has_submit_button": "boolean(//button[@type=\"submit\"])",
    "has_forgot_link": "boolean(//a[contains(@href,\"forgot\")])",
    "form_action": "//form/@action"
  }' 2>/dev/null
```

**Agent receives:**

```json
{"has_email_field": true, "has_password_field": true, "has_submit_button": true, "has_forgot_link": true, "form_action": "/api/auth/login"}
```

**Agent reports:** "Login page has all required fields: email input, password input, submit button, and forgot password link. Form submits to /api/auth/login."

### Step 3: Agent Tests an Interaction

**User prompt:** "Click the 'Load More' button and verify more items appear"

**Agent executes:**

```bash
# First, get baseline count
ar-crawl -s playwright crawl http://localhost:3000/products \
  --pw-delay 2000 \
  --format json \
  --output /tmp/before.json 2>/dev/null

BEFORE=$(ar-crawl extract /tmp/before.json \
  --fields '{"count": "count(//div[@class=\"product\"])"}' 2>/dev/null)
echo "Before click: $BEFORE"

# Click load more
ar-crawl -s playwright crawl http://localhost:3000/products \
  --click-selector "//button[contains(text(),'Load More')]" \
  --pw-delay 2000 \
  --format json \
  --output /tmp/after.json 2>/dev/null

AFTER=$(ar-crawl extract /tmp/after.json \
  --fields '{"count": "count(//div[@class=\"product\"])"}' 2>/dev/null)
echo "After click: $AFTER"
```

**Agent receives:**

```
Before click: {"count": "10"}
After click: {"count": "20"}
```

**Agent reports:** "Load More button works correctly. Product count increased from 10 to 20."

### Step 4: Agent Debugs an Issue

**User prompt:** "The dashboard is showing a blank page, what's wrong?"

**Agent executes:**

```bash
# Check page load timing
ar-crawl probe http://localhost:3000/dashboard 2>/dev/null

# Crawl with extended delay
ar-crawl -s playwright crawl http://localhost:3000/dashboard \
  --pw-delay 5000 \
  --format json \
  --output /tmp/dashboard.json 2>/dev/null

# Check for errors and content
ar-crawl extract /tmp/dashboard.json \
  --fields '{
    "has_content": "boolean(//main/*)",
    "error_message": "normalize-space(//div[@class=\"error\"])",
    "console_error": "//script[contains(text(),\"Error\")]",
    "loading_spinner": "boolean(//div[@class=\"loading\"])",
    "empty_state": "boolean(//div[@class=\"empty-state\"])"
  }' 2>/dev/null
```

**Agent receives:**

```json
{"has_content": false, "error_message": "Failed to fetch user data", "console_error": null, "loading_spinner": false, "empty_state": false}
```

**Agent reports:** "Dashboard shows 'Failed to fetch user data' error. The API endpoint for user data may be down or returning an error. Check your backend /api/user endpoint."

### Step 5: Agent Runs a Test Suite

**User prompt:** "Run a quick smoke test on all main pages"

**Agent creates and executes:**

```bash
#!/bin/bash
# smoke-test.sh

PAGES=(
  "http://localhost:3000|//main"
  "http://localhost:3000/login|//form"
  "http://localhost:3000/signup|//form"
  "http://localhost:3000/products|//div[@class='product']"
  "http://localhost:3000/about|//h1"
)

echo "Smoke Test Results:"
echo "==================="

for PAGE in "${PAGES[@]}"; do
  URL=$(echo "$PAGE" | cut -d'|' -f1)
  SELECTOR=$(echo "$PAGE" | cut -d'|' -f2)

  ar-crawl -s playwright crawl "$URL" \
    --pw-delay 2000 \
    --format json \
    --output /tmp/smoke.json 2>/dev/null

  RESULT=$(ar-crawl extract /tmp/smoke.json \
    --fields "{\"exists\": \"boolean($SELECTOR)\"}" 2>/dev/null)

  if echo "$RESULT" | grep -q "true"; then
    echo "PASS: $URL"
  else
    echo "FAIL: $URL (missing: $SELECTOR)"
  fi
done
```

**Agent receives:**

```
Smoke Test Results:
===================
PASS: http://localhost:3000
PASS: http://localhost:3000/login
PASS: http://localhost:3000/signup
FAIL: http://localhost:3000/products (missing: //div[@class='product'])
PASS: http://localhost:3000/about
```

**Agent reports:** "4 of 5 pages passed. Products page is failing - the product list div isn't rendering. This may indicate an API issue or React component error."

## Token Budget Guidelines

| Test Type | Expected Tokens | Recommended Fields |
|-----------|-----------------|-------------------|
| Existence check | 5-10 | 1-2 boolean fields |
| Content verification | 15-30 | 3-5 specific fields |
| Debug investigation | 30-50 | 5-8 diagnostic fields |
| Full page analysis | 50-100 | 10+ comprehensive fields |

## Agent Best Practices

1. **Always use extraction** - Never send raw HTML to agent context
2. **Use 2>/dev/null** - Suppress progress/error output from ar-crawl
3. **Boolean for existence** - `boolean(//element)` not the element itself
4. **Count for quantities** - `count(//elements)` not extracting all elements
5. **normalize-space for text** - Strips HTML and extra whitespace
6. **Store in /tmp** - Don't clutter with output files

## Quick Reference Commands

```bash
# Basic crawl (SPA)
ar-crawl -s playwright crawl "$URL" --pw-delay 2000 --format json --output /tmp/p.json 2>/dev/null

# Basic crawl (static)
ar-crawl crawl "$URL" --format json --output /tmp/p.json 2>/dev/null

# Extract fields
ar-crawl extract /tmp/p.json --fields '{"field": "//xpath"}' 2>/dev/null

# Click interaction
ar-crawl -s playwright crawl "$URL" --click-selector "//button" --pw-delay 1500 --format json --output /tmp/p.json 2>/dev/null

# Scroll page
ar-crawl -s playwright crawl "$URL" --scroll --scroll-count 3 --format json --output /tmp/p.json 2>/dev/null

# Debug page timing
ar-crawl probe "$URL"

# See raw HTML structure
ar-crawl sample /tmp/p.json --length 2000
```

## Success Criteria

- Agent completes tests autonomously
- Token usage stays under 100 per test
- Results are actionable and clear
- No manual intervention needed
