# Flow: Playwright Interaction Sequences

## User Story

As a web developer, I want to create and execute Playwright interaction sequences so that I can test my web app's dynamic behavior with my LLM agent.

## Prerequisites

- ar-crawl installed
- Local dev server running (e.g., `npm run dev`)
- Playwright service available

## The Flow

### Step 1: Verify Playwright Service

```bash
# Check if Playwright service is available
ar-crawl health -v

# Expected output:
# Service: playwright
# Status: available
# Browser: chromium
```

### Step 2: Basic Click Interaction

Test a button click and capture the result.

```bash
# Navigate and click a button
ar-crawl -s playwright crawl http://localhost:3000 \
  --click-selector "//button[@id='load-more']" \
  --pw-delay 1500 \
  --format json \
  --output /tmp/after-click.json

# Extract the result
ar-crawl extract /tmp/after-click.json \
  --fields '{"item_count": "count(//div[@class=\"item\"])"}'
```

### Step 3: Multiple Clicks (Load More Pattern)

```bash
# Click "Load More" 3 times
ar-crawl -s playwright crawl http://localhost:3000/feed \
  --click-selector "//button[contains(text(),'Load More')]" \
  --click-count 3 \
  --pw-delay 1000 \
  --format json \
  --output /tmp/feed-expanded.json

# Verify all content loaded
ar-crawl extract /tmp/feed-expanded.json \
  --fields '{"posts": "count(//article[@class=\"post\"])"}'
```

### Step 4: Scroll Interactions

```bash
# Infinite scroll page - scroll 5 times
ar-crawl -s playwright crawl http://localhost:3000/timeline \
  --scroll \
  --scroll-count 5 \
  --scroll-delay 1500 \
  --format json \
  --output /tmp/timeline.json

# Check how much content loaded
ar-crawl extract /tmp/timeline.json \
  --fields '{"entries": "count(//div[@class=\"timeline-entry\"])"}'
```

### Step 5: Combined Click + Scroll

```bash
# Open a modal, then scroll within it
ar-crawl -s playwright crawl http://localhost:3000/dashboard \
  --click-selector "//button[@id='show-details']" \
  --pw-delay 500 \
  --scroll \
  --format json \
  --output /tmp/modal-content.json
```

### Step 6: Wait for Specific Selector

```bash
# Wait for dynamic content to appear
ar-crawl -s playwright crawl http://localhost:3000/search?q=test \
  --pw-delay 3000 \
  --format json \
  --output /tmp/search-results.json

# The delay ensures AJAX results are loaded
ar-crawl extract /tmp/search-results.json \
  --fields '{
    "result_count": "count(//div[@class=\"result\"])",
    "first_result": "//div[@class=\"result\"][1]//h3"
  }'
```

## Playwright CLI Options Reference

| Option | Description | Example |
|--------|-------------|---------|
| `--pw-delay` | Wait after page load (ms) | `--pw-delay 3000` |
| `--click-selector` | XPath of element to click | `--click-selector "//button[@id='submit']"` |
| `--click-count` | Number of times to click | `--click-count 5` |
| `--scroll` | Enable scrolling | `--scroll` |
| `--scroll-count` | Number of scroll iterations | `--scroll-count 10` |
| `--scroll-delay` | Delay between scrolls (ms) | `--scroll-delay 1000` |

## Success Criteria

- Click interactions trigger UI updates
- Scroll loads lazy content
- Delays account for async operations
- Extracted content reflects post-interaction state

## Common Issues

### Clicks Not Working

```bash
# Verify selector exists first
ar-crawl -s playwright crawl http://localhost:3000 \
  --format json --output /tmp/page.json

ar-crawl sample /tmp/page.json --length 2000 | grep -i button
```

### Content Not Fully Loaded

```bash
# Use probe to find optimal delay
ar-crawl probe http://localhost:3000/slow-page

# Look for "Recommended pw-delay" in output
```

### Element Not Clickable

```bash
# Try increasing initial delay before click
ar-crawl -s playwright crawl http://localhost:3000 \
  --pw-delay 2000 \
  --click-selector "//button" \
  --format json --output /tmp/result.json
```
