# Flow: Replay Chrome DevTools Recorder Recordings

## User Story

As a web developer, I want to record browser interactions using Chrome DevTools Recorder and replay them with ar-crawl so that I can automate complex interaction sequences without writing code.

## Why Use Recordings?

- **No code required** - Record interactions visually in Chrome
- **Complex flows** - Handle multi-step forms, authentication, navigation
- **Reproducible** - Same recording works consistently
- **Agent-friendly** - LLM agents can trigger recordings without understanding Playwright

## Creating a Recording

### Step 1: Open Chrome DevTools Recorder

1. Open Chrome and navigate to any page
2. Open DevTools (F12 or Cmd+Option+I)
3. Click "More tools" > "Recorder" (or Ctrl/Cmd+Shift+P, type "Recorder")

### Step 2: Record Your Interaction

1. Click "Start new recording"
2. Name it (e.g., "login-flow", "checkout-process")
3. Click "Start recording"
4. Perform your interactions in the browser:
   - Click buttons and links
   - Fill in form fields
   - Navigate between pages
   - Scroll, hover, etc.
5. Click "End recording"

### Step 3: Export as JSON

1. Click the "Export" button (download icon)
2. Choose "JSON" format
3. Save the file (e.g., `login-flow.json`)

## Replaying with ar-crawl

### Basic Replay

```bash
# Replay a recording and get the final page state
ar-crawl replay login-flow.json

# Output shows final page content, URL, title, and step results
```

### Replay with Output File

```bash
# Save results for extraction
ar-crawl replay checkout.json -o /tmp/checkout-result.json

# Extract data from the final page
ar-crawl extract /tmp/checkout-result.json \
  --fields '{
    "order_number": "//span[@class=\"order-id\"]",
    "total": "//span[@class=\"total-price\"]",
    "confirmation": "normalize-space(//h1)"
  }'
```

### Verbose Mode

```bash
# See each step as it executes
ar-crawl replay user-journey.json -v

# Output:
# Recording 'User Login' completed
# Steps executed: 5
# Final URL: http://localhost:3000/dashboard
# Total time: 3456 ms
```

## The Flow

### Example: Test Login Flow

```bash
# 1. Create recording in Chrome DevTools:
#    - Navigate to /login
#    - Fill email field
#    - Fill password field
#    - Click submit
#    - Wait for dashboard

# 2. Export and replay
ar-crawl replay login-flow.json -o /tmp/after-login.json -v

# 3. Verify login succeeded
ar-crawl extract /tmp/after-login.json \
  --fields '{
    "logged_in": "boolean(//div[@class=\"user-menu\"])",
    "username": "normalize-space(//span[@class=\"username\"])",
    "dashboard_visible": "boolean(//main[@class=\"dashboard\"])"
  }'

# Expected: {"logged_in": true, "username": "John Doe", "dashboard_visible": true}
```

### Example: Test Multi-Step Form

```bash
# Recording captures:
#   Step 1: Fill personal info, click Next
#   Step 2: Fill address info, click Next
#   Step 3: Fill payment info, click Submit
#   Step 4: Wait for confirmation

ar-crawl replay wizard-form.json -o /tmp/wizard-result.json -v

ar-crawl extract /tmp/wizard-result.json \
  --fields '{
    "confirmation_shown": "boolean(//div[@class=\"confirmation\"])",
    "order_id": "//span[@id=\"order-id\"]/text()",
    "errors": "count(//div[@class=\"error\"])"
  }'
```

### Example: Test Search and Filter

```bash
# Recording captures:
#   - Type in search box
#   - Select category filter
#   - Click search button
#   - Wait for results

ar-crawl replay search-products.json -o /tmp/search-results.json

ar-crawl extract /tmp/search-results.json \
  --fields '{
    "result_count": "count(//div[@class=\"product-card\"])",
    "first_result": "normalize-space(//div[@class=\"product-card\"][1]//h3)",
    "filter_active": "boolean(//button[contains(@class,\"active-filter\")])"
  }'
```

## Recording Format Reference

Chrome DevTools Recorder exports JSON with this structure:

```json
{
  "title": "My Recording",
  "steps": [
    {"type": "setViewport", "width": 1920, "height": 1080},
    {"type": "navigate", "url": "http://localhost:3000/login"},
    {"type": "click", "selectors": [["#email"]], "offsetX": 50, "offsetY": 10},
    {"type": "change", "selectors": [["#email"]], "value": "user@example.com"},
    {"type": "click", "selectors": [["#password"]]},
    {"type": "change", "selectors": [["#password"]], "value": "secret123"},
    {"type": "click", "selectors": [["button[type=\"submit\"]"]]},
    {"type": "waitForElement", "selectors": [["#dashboard"]]}
  ]
}
```

### Supported Step Types

| Step Type | Description | Key Properties |
|-----------|-------------|----------------|
| `navigate` | Go to URL | `url` |
| `click` | Click element | `selectors`, `button`, `clickCount` |
| `doubleClick` | Double-click | `selectors` |
| `change` | Fill form field | `selectors`, `value` |
| `keyDown` | Press key | `key` |
| `keyUp` | Release key | `key` |
| `scroll` | Scroll page/element | `x`, `y`, `selectors` (optional) |
| `hover` | Hover over element | `selectors` |
| `waitForElement` | Wait for element | `selectors`, `visible` |
| `waitForExpression` | Wait for JS condition | `expression` |
| `setViewport` | Set browser size | `width`, `height` |

### Selector Formats

Chrome DevTools provides selectors in various formats:

- **CSS**: `#id`, `.class`, `button[type="submit"]`
- **ARIA**: `aria/Submit button` (converted to text selector)
- **XPath**: `xpath///html/body/div` (converted to XPath)
- **Pierce**: `pierce/.shadow-element` (for shadow DOM)
- **Text**: `text/Click me` (converted to text selector)

## LLM Agent Integration

### Providing Recording to Agent

```
You can replay recorded browser interactions:

ar-crawl replay <recording.json> -o /tmp/result.json -v
ar-crawl extract /tmp/result.json --fields '<json>'

Recordings are created in Chrome DevTools Recorder and exported as JSON.
Use replay for complex multi-step interactions that would be hard to script.
```

### Agent Usage Example

**User prompt:** "Test the checkout flow using the checkout.json recording"

**Agent executes:**

```bash
# Replay the recorded checkout flow
ar-crawl replay checkout.json -o /tmp/checkout.json -v 2>/dev/null

# Verify successful checkout
ar-crawl extract /tmp/checkout.json \
  --fields '{
    "success": "boolean(//div[@class=\"order-confirmation\"])",
    "order_number": "normalize-space(//span[@class=\"order-id\"])",
    "total": "normalize-space(//span[@class=\"total\"])"
  }' 2>/dev/null
```

**Agent receives:**

```json
{"success": true, "order_number": "ORD-12345", "total": "$99.99"}
```

**Agent reports:** "Checkout flow completed successfully. Order ORD-12345 placed for $99.99."

## Troubleshooting

### Recording Fails to Replay

```bash
# Run with verbose to see which step fails
ar-crawl replay recording.json -v

# Output shows per-step success/failure
# Step 2 (click) failed: Element not found
```

**Common fixes:**
- Increase delays between steps (edit JSON, add `waitForElement`)
- Update selectors if UI changed
- Check if element is in shadow DOM

### Selectors Not Found

Recording selectors may break if:
- CSS class names are generated (CSS-in-JS)
- IDs are dynamic
- Page structure changed

**Fix:** Edit the JSON to use more stable selectors:

```json
{
  "type": "click",
  "selectors": [
    ["[data-testid=\"submit-button\"]"],
    ["button[type=\"submit\"]"],
    ["aria/Submit"]
  ]
}
```

### Timing Issues

If steps execute before content loads:

```json
{
  "type": "waitForElement",
  "selectors": [["#dynamic-content"]],
  "visible": true
}
```

Or add wait expressions:

```json
{
  "type": "waitForExpression",
  "expression": "document.querySelectorAll('.item').length > 0"
}
```

## Best Practices

1. **Use data-testid** - Add stable test attributes to your app
2. **Add wait steps** - Record waits for dynamic content
3. **Keep recordings focused** - One flow per recording
4. **Version control** - Store recordings with your tests
5. **Name clearly** - `login-success.json`, `checkout-empty-cart.json`

## Success Criteria

- Recording replays successfully
- Final page state captured
- Data extracted from result
- Errors identified if replay fails
