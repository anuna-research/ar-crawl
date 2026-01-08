# Flow: Debug Rendering Issues

## User Story

As a web developer, I want to use ar-crawl to debug rendering issues so that I can understand what the browser actually sees and compare SSR vs CSR output.

## Common Debugging Scenarios

### Scenario 1: Content Not Appearing

```bash
# Step 1: Check if content exists in HTML
ar-crawl crawl http://localhost:3000/problematic-page \
  --format json --output /tmp/static.json 2>/dev/null

ar-crawl sample /tmp/static.json --length 3000

# Step 2: Check with JavaScript rendering
ar-crawl -s playwright crawl http://localhost:3000/problematic-page \
  --pw-delay 5000 \
  --format json --output /tmp/dynamic.json 2>/dev/null

ar-crawl sample /tmp/dynamic.json --length 3000
```

### Scenario 2: SSR vs CSR Comparison

Detect hydration mismatches or content that only appears client-side:

```bash
#!/bin/bash
# compare-ssr-csr.sh

URL="$1"

# SSR output (no JavaScript)
ar-crawl crawl "$URL" --format json --output /tmp/ssr.json 2>/dev/null
SSR=$(ar-crawl extract /tmp/ssr.json --fields '{
  "title": "//title",
  "h1": "normalize-space(//h1)",
  "main_content": "normalize-space(//main)",
  "data_count": "count(//*[@data-testid])"
}' 2>/dev/null)

# CSR output (with JavaScript)
ar-crawl -s playwright crawl "$URL" --pw-delay 3000 --format json --output /tmp/csr.json 2>/dev/null
CSR=$(ar-crawl extract /tmp/csr.json --fields '{
  "title": "//title",
  "h1": "normalize-space(//h1)",
  "main_content": "normalize-space(//main)",
  "data_count": "count(//*[@data-testid])"
}' 2>/dev/null)

echo "SSR Output:"
echo "$SSR" | jq .

echo ""
echo "CSR Output:"
echo "$CSR" | jq .

echo ""
echo "Differences indicate client-side only content or hydration issues"
```

### Scenario 3: Page Load Performance

```bash
# Probe to understand timing
ar-crawl probe http://localhost:3000/slow-page

# Output shows:
# - DOM content loaded: 245ms
# - Page load complete: 1,823ms
# - Network idle: 3,456ms
# - JS execution estimate: 1,578ms
# - Recommended pw-delay: 2500ms
# - Recommended timeout: 35000ms
```

### Scenario 4: What Selectors Exist?

When your XPath returns empty, explore the page structure:

```bash
# Get a sample of the HTML
ar-crawl sample /tmp/page.json --length 5000

# Search for specific patterns
ar-crawl sample /tmp/page.json | grep -i "class="

# Extract all class names to understand structure
ar-crawl extract /tmp/page.json \
  --fields '{"classes": "//*/@class"}' 2>/dev/null

# Extract all IDs
ar-crawl extract /tmp/page.json \
  --fields '{"ids": "//*/@id"}' 2>/dev/null

# Extract all data attributes
ar-crawl extract /tmp/page.json \
  --fields '{"data_attrs": "//*/@*[starts-with(name(),\"data-\")]"}' 2>/dev/null
```

### Scenario 5: Element Visibility Debug

```bash
# Check if elements exist but might be hidden
ar-crawl extract /tmp/page.json --fields '{
  "modal_exists": "boolean(//div[@class=\"modal\"])",
  "modal_visible": "boolean(//div[@class=\"modal\" and not(contains(@class,\"hidden\"))])",
  "modal_display": "//div[@class=\"modal\"]/@style",
  "overlay_exists": "boolean(//div[@class=\"overlay\"])"
}' 2>/dev/null
```

### Scenario 6: Form State Debug

```bash
# Debug form issues
ar-crawl -s playwright crawl http://localhost:3000/form \
  --pw-delay 2000 --format json --output /tmp/form.json 2>/dev/null

ar-crawl extract /tmp/form.json --fields '{
  "form_action": "//form/@action",
  "form_method": "//form/@method",
  "input_count": "count(//input)",
  "required_fields": "count(//input[@required])",
  "disabled_fields": "count(//input[@disabled])",
  "validation_errors": "count(//span[@class=\"error\"])",
  "submit_disabled": "boolean(//button[@type=\"submit\"]/@disabled)"
}' 2>/dev/null
```

### Scenario 7: Network-Related Issues

```bash
# Check if page loaded at all
ar-crawl -s playwright crawl http://localhost:3000 \
  --pw-delay 1000 --format json --output /tmp/check.json 2>/dev/null

ar-crawl extract /tmp/check.json --fields '{
  "has_html": "boolean(//html)",
  "has_body": "boolean(//body)",
  "body_empty": "normalize-space(//body) = \"\"",
  "has_react_root": "boolean(//div[@id=\"root\"])",
  "react_mounted": "boolean(//div[@id=\"root\"]/*)"
}' 2>/dev/null

# If react_mounted is false, the SPA didn't hydrate
```

### Scenario 8: Debug Infinite Scroll

```bash
# Test if scroll loads more content
BEFORE=$(ar-crawl -s playwright crawl http://localhost:3000/feed \
  --pw-delay 2000 --format json --output /tmp/s1.json 2>/dev/null && \
  ar-crawl extract /tmp/s1.json --fields '{"count": "count(//article)"}' 2>/dev/null)

AFTER=$(ar-crawl -s playwright crawl http://localhost:3000/feed \
  --scroll --scroll-count 3 --scroll-delay 1500 \
  --pw-delay 2000 --format json --output /tmp/s2.json 2>/dev/null && \
  ar-crawl extract /tmp/s2.json --fields '{"count": "count(//article)"}' 2>/dev/null)

echo "Before scroll: $BEFORE"
echo "After scroll: $AFTER"

# If counts are same, infinite scroll isn't working
```

## Debug Command Reference

```bash
# See raw HTML structure
ar-crawl sample /tmp/page.json --length 5000

# Check page timing
ar-crawl probe "$URL"

# Compare static vs dynamic
ar-crawl crawl "$URL" --format json --output /tmp/static.json
ar-crawl -s playwright crawl "$URL" --pw-delay 3000 --format json --output /tmp/dynamic.json

# Extract with verbose error (remove 2>/dev/null)
ar-crawl extract /tmp/page.json --fields '{"test": "//selector"}'

# Health check services
ar-crawl health -v
```

## Common Issues and Solutions

| Issue | Diagnosis | Solution |
|-------|-----------|----------|
| Empty content | SPA not hydrated | Increase `--pw-delay` |
| XPath returns null | Wrong selector | Use `sample` to see structure |
| Timeout | Page too slow | Use `probe` to find timing |
| Playwright fails | Service not running | Run `ar-crawl health -v` |
| SSR/CSR mismatch | Hydration issue | Compare static vs dynamic crawl |
| Click no effect | Element not ready | Add delay before click |

## Success Criteria

- Root cause identified
- Timing parameters optimized
- Selectors verified against actual HTML
- SSR/CSR differences understood
