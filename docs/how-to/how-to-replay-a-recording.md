---
title: How to replay a recording
mode: how-to
---

# How to replay a recording

This guide covers automating a browser flow from a Chrome DevTools Recorder export, for a reader who has the flow open in Chrome.

## Creating a Recording

1. Open Chrome DevTools (F12 or Cmd+Option+I)
2. Click "More tools" > "Recorder" (or Ctrl/Cmd+Shift+P, type "Recorder")
3. Click "Start new recording", name it, click "Start recording"
4. Perform your interactions in the browser
5. Click "End recording"
6. Export as JSON: Click "Export" > "JSON"

## Basic Usage

```bash
# Replay a recording
ar-crawl replay recording.json

# Save the final page state for extraction
ar-crawl replay recording.json -o result.json

# Verbose mode shows each step
ar-crawl replay recording.json -v
```

## Full Workflow: Record → Replay → Extract → Validate

This example shows the complete workflow including using `jq` for validation:

```bash
# 1. Replay a login flow recording
ar-crawl replay login-flow.json -o /tmp/after-login.json

# 2. Extract data from the result
ar-crawl extract /tmp/after-login.json --fields '{
  "page_title": "//title",
  "username": "//span[@class=\"user-name\"]"
}'

# 3. Validate the replay succeeded using jq exit codes
# jq -e returns non-zero exit code if result is null/false
jq -e '.recording.stepResults | all(.success)' /tmp/after-login.json

# 4. Use in a script with error handling
if jq -e '.recording.stepResults | all(.success)' /tmp/after-login.json > /dev/null 2>&1; then
  echo "Replay succeeded"
else
  echo "Replay failed - check step results"
  jq '.recording.stepResults[] | select(.success == false)' /tmp/after-login.json
  exit 1
fi
```

## Example: Testing a Checkout Flow

```bash
# Replay the checkout recording
ar-crawl replay checkout.json -o /tmp/checkout-result.json -v

# Extract order confirmation details
ar-crawl extract /tmp/checkout-result.json --fields '{
  "order_id": "//span[@class=\"order-id\"]",
  "total": "//span[@class=\"total-price\"]"
}'

# Verify we reached the confirmation page
jq -e '.data[0].url | contains("confirmation")' /tmp/checkout-result.json
```

## Validation with jq

Use `jq -e` to get meaningful exit codes for scripting:

```bash
# Check all steps succeeded (exit 0 if true, exit 1 if false)
jq -e '.recording.stepResults | all(.success)' result.json

# Check specific step succeeded
jq -e '.recording.stepResults[2].success' result.json

# Get failed steps only
jq '.recording.stepResults[] | select(.success == false)' result.json

# Check final URL contains expected path
jq -e '.data[0].url | contains("/dashboard")' result.json

# Count successful steps
jq '.recording.stepResults | map(select(.success)) | length' result.json
```

Supported step types and the result document are in the [replay reference](../reference/replay.md).
