# Flow: Test Component Rendering States

## User Story

As a web developer, I want to test different UI states (loading, loaded, error, empty) so that I can verify my components render correctly in all scenarios.

## Common UI States to Test

1. **Loading** - Spinner or skeleton visible
2. **Loaded** - Data displayed correctly
3. **Empty** - No data, empty state message
4. **Error** - Error message displayed
5. **Partial** - Some data loaded, some failed

## The Flow

### Testing Loading State

```bash
# Crawl with minimal delay to catch loading state
ar-crawl -s playwright crawl http://localhost:3000/users \
  --pw-delay 200 \
  --format json \
  --output /tmp/loading.json 2>/dev/null

ar-crawl extract /tmp/loading.json \
  --fields '{
    "has_spinner": "boolean(//div[@class=\"loading-spinner\"])",
    "has_skeleton": "boolean(//div[contains(@class,\"skeleton\")])",
    "has_data": "boolean(//table//tr[@class=\"user-row\"])"
  }'

# Expected: {"has_spinner": true, "has_skeleton": false, "has_data": false}
```

### Testing Loaded State

```bash
# Crawl with enough delay for data to load
ar-crawl -s playwright crawl http://localhost:3000/users \
  --pw-delay 3000 \
  --format json \
  --output /tmp/loaded.json 2>/dev/null

ar-crawl extract /tmp/loaded.json \
  --fields '{
    "has_spinner": "boolean(//div[@class=\"loading-spinner\"])",
    "user_count": "count(//tr[@class=\"user-row\"])",
    "first_user_name": "normalize-space(//tr[@class=\"user-row\"][1]//td[@class=\"name\"])",
    "has_pagination": "boolean(//nav[@class=\"pagination\"])"
  }'

# Expected: {"has_spinner": false, "user_count": "10", "first_user_name": "John Doe", "has_pagination": true}
```

### Testing Empty State

```bash
# Use query param to trigger empty state
ar-crawl -s playwright crawl "http://localhost:3000/users?filter=nonexistent" \
  --pw-delay 2000 \
  --format json \
  --output /tmp/empty.json 2>/dev/null

ar-crawl extract /tmp/empty.json \
  --fields '{
    "has_empty_state": "boolean(//div[@class=\"empty-state\"])",
    "empty_message": "normalize-space(//div[@class=\"empty-state\"]//p)",
    "has_create_button": "boolean(//button[contains(text(),\"Create\")])",
    "user_count": "count(//tr[@class=\"user-row\"])"
  }'

# Expected: {"has_empty_state": true, "empty_message": "No users found", "has_create_button": true, "user_count": "0"}
```

### Testing Error State

```bash
# Trigger error (mock failed API)
ar-crawl -s playwright crawl "http://localhost:3000/users?force_error=500" \
  --pw-delay 2000 \
  --format json \
  --output /tmp/error.json 2>/dev/null

ar-crawl extract /tmp/error.json \
  --fields '{
    "has_error": "boolean(//div[@role=\"alert\"])",
    "error_message": "normalize-space(//div[@role=\"alert\"])",
    "has_retry_button": "boolean(//button[contains(text(),\"Retry\")])",
    "has_spinner": "boolean(//div[@class=\"loading-spinner\"])"
  }'

# Expected: {"has_error": true, "error_message": "Failed to load users. Please try again.", "has_retry_button": true, "has_spinner": false}
```

### Complete State Test Script

```bash
#!/bin/bash
# test-states.sh - Test all UI states for a component

COMPONENT_URL="http://localhost:3000/users"

echo "Testing UI States"
echo "================="

# Loading state
echo -n "Loading state: "
ar-crawl -s playwright crawl "$COMPONENT_URL" \
  --pw-delay 100 --format json --output /tmp/s.json 2>/dev/null
ar-crawl extract /tmp/s.json --fields '{"loading": "boolean(//*[@class=\"loading-spinner\" or contains(@class,\"skeleton\")])"}' 2>/dev/null

# Loaded state
echo -n "Loaded state: "
ar-crawl -s playwright crawl "$COMPONENT_URL" \
  --pw-delay 3000 --format json --output /tmp/s.json 2>/dev/null
ar-crawl extract /tmp/s.json --fields '{"has_data": "boolean(//tr[@class=\"user-row\"])", "count": "count(//tr[@class=\"user-row\"])"}' 2>/dev/null

# Empty state
echo -n "Empty state: "
ar-crawl -s playwright crawl "$COMPONENT_URL?filter=xxx" \
  --pw-delay 2000 --format json --output /tmp/s.json 2>/dev/null
ar-crawl extract /tmp/s.json --fields '{"empty": "boolean(//div[@class=\"empty-state\"])"}' 2>/dev/null

# Error state
echo -n "Error state: "
ar-crawl -s playwright crawl "$COMPONENT_URL?error=1" \
  --pw-delay 2000 --format json --output /tmp/s.json 2>/dev/null
ar-crawl extract /tmp/s.json --fields '{"error": "boolean(//div[@role=\"alert\"])"}' 2>/dev/null
```

## State Transition Testing

Test that states transition correctly:

```bash
# Test loading -> loaded transition
echo "Testing state transition..."

# Capture loading
ar-crawl -s playwright crawl "$URL" --pw-delay 100 --format json --output /tmp/t1.json 2>/dev/null
STATE1=$(ar-crawl extract /tmp/t1.json --fields '{"loading": "boolean(//*[@class=\"loading\"])"}' 2>/dev/null)

# Capture loaded
ar-crawl -s playwright crawl "$URL" --pw-delay 3000 --format json --output /tmp/t2.json 2>/dev/null
STATE2=$(ar-crawl extract /tmp/t2.json --fields '{"loading": "boolean(//*[@class=\"loading\"])", "data": "boolean(//*[@class=\"data\"])"}' 2>/dev/null)

echo "Initial: $STATE1"
echo "Final: $STATE2"
```

## XPath Patterns for State Detection

```xpath
# Loading indicators
boolean(//*[contains(@class,'loading')])
boolean(//*[contains(@class,'spinner')])
boolean(//*[contains(@class,'skeleton')])
boolean(//div[@role='progressbar'])

# Error states
boolean(//div[@role='alert'])
boolean(//*[contains(@class,'error')])
boolean(//*[contains(@class,'alert-danger')])

# Empty states
boolean(//*[contains(@class,'empty-state')])
boolean(//*[contains(@class,'no-data')])
boolean(//*[contains(text(),'No results')])

# Success states
boolean(//*[contains(@class,'success')])
boolean(//div[@role='status'])
```

## Success Criteria

- All states are detected correctly
- Timing captures transient states (loading)
- Error messages are extracted
- Empty state content verified
