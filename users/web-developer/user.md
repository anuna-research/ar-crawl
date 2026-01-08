# Web Developer User Profile

## Who They Are

**Name:** Taylor Nguyen
**Role:** Full-stack Web Developer
**Organization:** Startup or agency building web applications
**Technical Level:** Expert (JavaScript, HTML/CSS, familiar with XPath, can write shell scripts)

## Daily Context

Taylor builds and tests web applications. They use LLM agents (Claude Code, Cursor, etc.) to help with development tasks. They typically:

- Build SPAs with React, Vue, or similar frameworks
- Need to test their web apps during development
- Want their LLM agent to verify UI states and interactions
- Care about minimizing token usage in agent context windows
- Create automated interaction sequences for testing

## Goals

1. Provide ar-crawl as a CLI tool for their LLM agent to test web apps
2. Create reusable Playwright interaction files for common test scenarios
3. Use extraction to reduce irrelevant HTML tokens in agent responses
4. Verify UI renders correctly after code changes
5. Debug frontend issues with actual rendered content

## Pain Points

- Raw HTML is verbose and wastes LLM context tokens
- Need JS rendering for SPA testing (curl doesn't work)
- Want to define interaction sequences once and reuse them
- Agent context windows fill up with irrelevant page content
- Need structured output focused on what matters

## Technical Environment

- macOS or Linux development machine
- Node.js/TypeScript project with SPA framework
- LLM agent (Claude Code, Cursor, Aider, etc.)
- Local dev server on localhost:3000 or similar
- Familiar with Playwright concepts

---

# Happy Path Flows

## Flow 1: Set Up ar-crawl for LLM Agent Testing

Taylor installs ar-crawl and verifies it works with their agent.

```bash
# Install ar-crawl
curl -fsSL https://raw.githubusercontent.com/example/ar-crawl/main/install.sh | bash

# Verify installation
ar-crawl health

# Test basic crawl on local dev server
ar-crawl crawl http://localhost:3000 --format json --output /tmp/test.json

# Quick sample to verify content captured
ar-crawl sample /tmp/test.json --length 500
```

**Expected Outcome:** ar-crawl installed and working with local dev server.

**Success Criteria:**
- Health check passes
- Local app content captured
- Agent can invoke ar-crawl commands

---

## Flow 2: Create Playwright Interaction Sequence

Taylor creates a reusable interaction file for testing login flow.

```bash
# Test login flow with Playwright interactions
ar-crawl -s playwright crawl http://localhost:3000/login \
  --pw-delay 2000 \
  --click-selector "//input[@name='email']" \
  --format json \
  --output /tmp/login-page.json

# For more complex sequences, use the Playwright service directly
# First, ensure service is running
ar-crawl health -v

# Create an interaction script for your agent to use
cat > ~/.ar-crawl/interactions/login-flow.json << 'EOF'
{
  "name": "login-flow",
  "description": "Navigate to login, fill credentials, submit",
  "steps": [
    {
      "action": "navigate",
      "url": "http://localhost:3000/login"
    },
    {
      "action": "wait",
      "delay": 2000,
      "reason": "SPA hydration"
    },
    {
      "action": "crawl",
      "extract": {
        "form_state": "//form[@id='login-form']",
        "error_message": "//div[@class='error']",
        "submit_button": "//button[@type='submit']"
      }
    }
  ]
}
EOF
```

**Using the Playwright CLI options for interactions:**

```bash
# Click a button and wait for result
ar-crawl -s playwright crawl http://localhost:3000 \
  --click-selector "//button[@id='load-more']" \
  --click-count 3 \
  --pw-delay 1500 \
  --format json --output /tmp/after-clicks.json

# Scroll for infinite scroll pages
ar-crawl -s playwright crawl http://localhost:3000/feed \
  --scroll \
  --scroll-count 5 \
  --scroll-delay 1000 \
  --format json --output /tmp/feed.json
```

**Expected Outcome:** Reusable interaction patterns for testing.

**Success Criteria:**
- Interactions capture dynamic content
- Click and scroll actions work
- Sequences are reusable

---

## Flow 3: Extract Only Relevant Content for LLM Agent

Taylor reduces token usage by extracting only the fields that matter.

```bash
# BEFORE: Full HTML is ~50KB, wastes agent context
ar-crawl crawl http://localhost:3000/dashboard --format json --output /tmp/raw.json
# raw.json contains full HTML body - too verbose!

# AFTER: Extract only relevant fields - ~500 bytes
ar-crawl extract /tmp/raw.json \
  --fields '{
    "page_title": "//title",
    "user_name": "//span[@class=\"user-name\"]",
    "nav_items": "//nav//a",
    "main_content": "//main",
    "error_alerts": "//div[@role=\"alert\"]"
  }' \
  --format json

# Output is focused and token-efficient:
# {
#   "page_title": "Dashboard - MyApp",
#   "user_name": "Taylor",
#   "nav_items": ["Home", "Settings", "Logout"],
#   "main_content": "Welcome back! You have 3 notifications...",
#   "error_alerts": []
# }
```

**Extract for specific test assertions:**

```bash
# Check if login succeeded (minimal output)
ar-crawl -s playwright crawl http://localhost:3000/login \
  --format json --output /tmp/login.json

ar-crawl extract /tmp/login.json \
  --fields '{
    "is_authenticated": "//meta[@name=\"auth-status\"]/@content",
    "username_display": "//span[@class=\"username\"]",
    "logout_button": "//button[@id=\"logout\"]"
  }'

# Returns only what agent needs to verify:
# {"is_authenticated": "true", "username_display": "taylor", "logout_button": "Logout"}
```

**Expected Outcome:** Minimal, focused output for LLM agent context.

**Success Criteria:**
- Extracted content is 10-100x smaller than raw HTML
- Only relevant fields included
- Agent can make decisions from extracted data

---

## Flow 4: Test Component Rendering States

Taylor verifies different component states during development.

```bash
#!/bin/bash
# test-component-states.sh - Verify component renders all states

APP_URL="http://localhost:3000"
OUTPUT_DIR="/tmp/component-tests"
mkdir -p "$OUTPUT_DIR"

# Test loading state
ar-crawl -s playwright crawl "$APP_URL/users" \
  --pw-delay 500 \
  --format json --output "$OUTPUT_DIR/loading.json"

LOADING=$(ar-crawl extract "$OUTPUT_DIR/loading.json" \
  --fields '{"spinner": "//div[@class=\"loading-spinner\"]"}')
echo "Loading state: $LOADING"

# Test loaded state (wait longer)
ar-crawl -s playwright crawl "$APP_URL/users" \
  --pw-delay 3000 \
  --format json --output "$OUTPUT_DIR/loaded.json"

DATA=$(ar-crawl extract "$OUTPUT_DIR/loaded.json" \
  --fields '{
    "user_count": "count(//tr[@class=\"user-row\"])",
    "first_user": "//tr[@class=\"user-row\"][1]//td[@class=\"name\"]",
    "has_pagination": "//nav[@class=\"pagination\"]"
  }')
echo "Loaded state: $DATA"

# Test error state (invalid endpoint)
ar-crawl -s playwright crawl "$APP_URL/users?force_error=1" \
  --pw-delay 2000 \
  --format json --output "$OUTPUT_DIR/error.json"

ERROR=$(ar-crawl extract "$OUTPUT_DIR/error.json" \
  --fields '{"error_message": "//div[@class=\"error-message\"]"}')
echo "Error state: $ERROR"
```

**Expected Outcome:** Verified component states with minimal output.

**Success Criteria:**
- Each state captured correctly
- Timing accounts for async loading
- Agent receives structured test results

---

## Flow 5: Agent-Friendly Test Workflow

Taylor sets up a complete workflow for their LLM agent.

```bash
# The agent can run this to verify a feature works

# Step 1: Start local server (agent assumes it's running)
# npm run dev  # Already running on localhost:3000

# Step 2: Crawl the page after an interaction
ar-crawl -s playwright crawl http://localhost:3000/todos \
  --click-selector "//button[text()='Add Todo']" \
  --pw-delay 1000 \
  --format json \
  --output /tmp/todos-after-add.json

# Step 3: Extract ONLY the verification data (saves ~95% tokens)
ar-crawl extract /tmp/todos-after-add.json \
  --fields '{
    "todo_count": "count(//li[@class=\"todo-item\"])",
    "last_todo": "//li[@class=\"todo-item\"][last()]//span[@class=\"text\"]",
    "empty_state": "//div[@class=\"empty-state\"]"
  }' \
  --format json

# Agent receives:
# {"todo_count": "4", "last_todo": "New todo item", "empty_state": null}
#
# Instead of 30KB of HTML, agent gets ~80 bytes of relevant data
```

**For agents testing complex flows:**

```bash
# Multi-step interaction test
STEPS=(
  "Navigate to /signup"
  "Check form fields exist"
  "Submit empty - verify validation"
)

# Each step produces minimal, actionable output
ar-crawl -s playwright crawl http://localhost:3000/signup \
  --pw-delay 2000 \
  --format json --output /tmp/signup.json

# Check form fields (minimal output)
ar-crawl extract /tmp/signup.json --fields '{
  "email_field": "//input[@name=\"email\"]/@placeholder",
  "password_field": "//input[@name=\"password\"]/@type",
  "submit_enabled": "//button[@type=\"submit\"]/@disabled"
}'

# Submit and check validation
ar-crawl -s playwright crawl http://localhost:3000/signup \
  --click-selector "//button[@type='submit']" \
  --pw-delay 1000 \
  --format json --output /tmp/signup-submit.json

ar-crawl extract /tmp/signup-submit.json --fields '{
  "validation_errors": "//span[@class=\"error\"]",
  "success_message": "//div[@class=\"success\"]"
}'
```

**Expected Outcome:** Agent can test web app with minimal context usage.

**Success Criteria:**
- Complete workflow in few commands
- Output is structured and minimal
- Agent can verify features work

---

## Flow 6: Debug Rendering Issues

Taylor uses ar-crawl to see what the browser actually renders.

```bash
# Compare SSR output vs client-side rendered output

# Static/SSR content (no JavaScript)
ar-crawl crawl http://localhost:3000/product/123 \
  --format json --output /tmp/ssr.json

SSR_CONTENT=$(ar-crawl extract /tmp/ssr.json \
  --fields '{"product_name": "//h1", "price": "//span[@class=\"price\"]"}')
echo "SSR output: $SSR_CONTENT"

# Client-rendered content (with JavaScript)
ar-crawl -s playwright crawl http://localhost:3000/product/123 \
  --pw-delay 3000 \
  --format json --output /tmp/csr.json

CSR_CONTENT=$(ar-crawl extract /tmp/csr.json \
  --fields '{"product_name": "//h1", "price": "//span[@class=\"price\"]", "reviews": "//div[@class=\"reviews\"]"}')
echo "CSR output: $CSR_CONTENT"

# If they differ, there's a hydration issue!
```

**Probe page load performance:**

```bash
# Understand when content is available
ar-crawl probe http://localhost:3000/dashboard -v

# Output shows:
# - DOM content loaded: 150ms
# - Page load complete: 800ms
# - Network idle: 1200ms
# - JS execution estimate: 650ms
# - Recommended pw-delay: 1500ms

# Use recommended delay for reliable crawls
ar-crawl -s playwright crawl http://localhost:3000/dashboard \
  --pw-delay 1500 \
  --format json --output /tmp/dashboard.json
```

**Expected Outcome:** Understanding of actual rendered content.

**Success Criteria:**
- Can debug SSR vs CSR differences
- Probe gives timing guidance
- Reliable test parameters

---

## Flow 7: Minimal Token Output Patterns

Taylor optimizes agent context usage with extraction patterns.

```bash
# Pattern 1: Boolean checks (yes/no questions)
ar-crawl extract /tmp/page.json \
  --fields '{"logged_in": "boolean(//button[@id=\"logout\"])"}'
# Returns: {"logged_in": true}  -- 2 tokens instead of 500

# Pattern 2: Count assertions
ar-crawl extract /tmp/page.json \
  --fields '{"items": "count(//li[@class=\"item\"])"}'
# Returns: {"items": "12"}  -- 3 tokens

# Pattern 3: Text content only (strips HTML)
ar-crawl extract /tmp/page.json \
  --fields '{"main_text": "normalize-space(//main)"}'
# Returns: {"main_text": "Welcome..."}  -- text only, no tags

# Pattern 4: Presence checks for UI elements
ar-crawl extract /tmp/page.json \
  --fields '{
    "has_nav": "boolean(//nav)",
    "has_footer": "boolean(//footer)",
    "has_error": "boolean(//div[@class=\"error\"])",
    "has_loading": "boolean(//div[@class=\"loading\"])"
  }'
# Returns: {"has_nav": true, "has_footer": true, "has_error": false, "has_loading": false}

# Pattern 5: Attribute extraction (not full element)
ar-crawl extract /tmp/page.json \
  --fields '{
    "form_action": "//form/@action",
    "csrf_token": "//input[@name=\"_csrf\"]/@value",
    "page_lang": "//html/@lang"
  }'
```

**Agent workflow with minimal output:**

```bash
# Full workflow that keeps agent context clean

# 1. Crawl (store locally, don't flood context)
ar-crawl -s playwright crawl "$URL" --format json --output /tmp/page.json 2>/dev/null

# 2. Extract minimally
RESULT=$(ar-crawl extract /tmp/page.json --fields '{
  "title": "//title",
  "auth": "boolean(//meta[@name=\"authenticated\"])",
  "errors": "count(//div[@role=\"alert\"])"
}' 2>/dev/null)

echo "$RESULT"
# Output: {"title": "Dashboard", "auth": true, "errors": "0"}
# Total: ~15 tokens instead of 10,000+ from raw HTML
```

**Expected Outcome:** Extremely token-efficient agent output.

**Success Criteria:**
- Boolean patterns for yes/no checks
- Count patterns for quantities
- Text-only extraction strips HTML
- 95%+ token reduction from raw HTML

---

# Edge Cases and Recovery

## SPA Takes Too Long to Render

```bash
# Use probe to find optimal timing
ar-crawl probe http://localhost:3000/heavy-page

# If probe shows long JS execution, increase delay
ar-crawl -s playwright crawl http://localhost:3000/heavy-page \
  --pw-delay 8000 \
  --timeout 60000 \
  --format json --output /tmp/result.json
```

## Content Behind Login

```bash
# Can't directly test authenticated pages without session
# Workaround: Test the login flow itself
ar-crawl -s playwright crawl http://localhost:3000/login \
  --format json --output /tmp/login.json

ar-crawl extract /tmp/login.json --fields '{
  "has_form": "boolean(//form)",
  "has_email": "boolean(//input[@type=\"email\"])",
  "has_password": "boolean(//input[@type=\"password\"])"
}'
```

## XPath Returns Empty

```bash
# Sample the page to understand structure
ar-crawl sample /tmp/page.json --length 3000

# Use broader selectors first, then narrow down
ar-crawl extract /tmp/page.json --fields '{"all_divs": "//div/@class"}'
```

## Playwright Service Not Running

```bash
# Check status
ar-crawl health -v

# Service auto-starts on first use, but if issues:
cd playwright-service && npm install && npm start &
ar-crawl health
```

---

# Quick Reference for LLM Agents

```bash
# Minimal crawl command
ar-crawl -s playwright crawl "$URL" --format json --output /tmp/p.json 2>/dev/null

# Minimal extract (customize fields)
ar-crawl extract /tmp/p.json --fields '{"key": "//selector"}' 2>/dev/null

# Boolean check
ar-crawl extract /tmp/p.json --fields '{"exists": "boolean(//element)"}'

# Count elements
ar-crawl extract /tmp/p.json --fields '{"count": "count(//elements)"}'

# Get text only (no HTML)
ar-crawl extract /tmp/p.json --fields '{"text": "normalize-space(//main)"}'

# Click then crawl
ar-crawl -s playwright crawl "$URL" --click-selector "//button" --pw-delay 1000 --format json --output /tmp/p.json

# Scroll for infinite content
ar-crawl -s playwright crawl "$URL" --scroll --scroll-count 3 --format json --output /tmp/p.json
```
