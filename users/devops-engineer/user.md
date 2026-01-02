# DevOps Engineer User Profile

## Who They Are

**Name:** Alex Kim
**Role:** Site Reliability Engineer / DevOps
**Organization:** SaaS company or web agency
**Technical Level:** Expert (scripting, automation, CI/CD, monitoring)

## Daily Context

Alex maintains production systems and needs to monitor web services. They typically:

- Monitor website availability and performance
- Run health checks on internal and external services
- Integrate tools into CI/CD pipelines
- Debug production issues with web frontends
- Test deployments across environments

## Goals

1. Monitor website uptime and content correctness
2. Verify deployments rendered correctly
3. Integrate crawling into CI/CD pipelines
4. Detect regressions in web applications

## Pain Points

- curl doesn't render JavaScript
- Selenium is heavyweight for simple checks
- Need quick CLI tool that fits DevOps workflows
- Must work in Docker/CI environments

## Technical Environment

- Linux servers, macOS locally
- Docker, Kubernetes, CI/CD systems
- Bash, Python scripting
- Prometheus, Grafana, alerting systems

---

# Happy Path Flows

## Flow 1: Health Check for JavaScript Application

Alex needs to verify a React app is serving content correctly.

```bash
# Check if SPA renders expected content
ar-crawl -s playwright crawl https://app.company.com/dashboard \
  --pw-delay 5000 \
  --output /tmp/health-check.json

# Verify expected elements exist
ar-crawl extract /tmp/health-check.json \
  --fields '{"title": "//title", "main_content": "//main", "nav": "//nav"}'

# In a health check script:
CONTENT=$(ar-crawl extract /tmp/health-check.json --fields '{"dashboard": "//div[@id=\"dashboard\"]"}' 2>/dev/null)
if echo "$CONTENT" | grep -q "dashboard"; then
  echo "OK: Dashboard rendered"
  exit 0
else
  echo "FAIL: Dashboard not found"
  exit 1
fi
```

**Expected Outcome:** Exit code indicates application health.

**Success Criteria:**
- Works in CI/CD pipelines
- Fast enough for regular checks
- Clear pass/fail result

---

## Flow 2: Post-Deployment Verification

Alex runs a smoke test after deploying a new version.

```bash
#!/bin/bash
# smoke-test.sh - Run after deployment

set -e

ENVIRONMENT=${1:-staging}
BASE_URL="https://$ENVIRONMENT.company.com"

echo "Running smoke tests against $BASE_URL"

# Test 1: Homepage loads
ar-crawl crawl "$BASE_URL" --format json --output /tmp/homepage.json
TITLE=$(ar-crawl extract /tmp/homepage.json --fields '{"title": "//title"}' | grep -o '"title":"[^"]*"')
echo "Homepage: $TITLE"

# Test 2: API documentation page (static)
ar-crawl crawl "$BASE_URL/docs" --format json --output /tmp/docs.json
DOC_COUNT=$(ar-crawl extract /tmp/docs.json --fields '{"endpoints": "//div[@class=\"endpoint\"]"}' | wc -l)
echo "API docs: Found content"

# Test 3: Dashboard renders (JavaScript)
ar-crawl -s playwright crawl "$BASE_URL/app" \
  --pw-delay 3000 \
  --output /tmp/app.json
APP_CONTENT=$(ar-crawl extract /tmp/app.json --fields '{"app_root": "//div[@id=\"root\"]"}')
if [ -z "$APP_CONTENT" ]; then
  echo "FAIL: React app did not render"
  exit 1
fi

echo "All smoke tests passed for $ENVIRONMENT"
```

**Expected Outcome:** Automated verification that deployment succeeded.

**Success Criteria:**
- Runs in CI pipeline post-deploy
- Catches rendering failures
- Clear error messages on failure

---

## Flow 3: Page Load Performance Monitoring

Alex tracks page performance across releases.

```bash
#!/bin/bash
# performance-check.sh

URLS=(
  "https://app.company.com/"
  "https://app.company.com/dashboard"
  "https://app.company.com/settings"
)

echo "timestamp,url,dom_load_ms,network_idle_ms,requests"

for URL in "${URLS[@]}"; do
  # Probe returns performance metrics
  METRICS=$(ar-crawl probe "$URL" 2>&1 | tail -5)

  DOM_MS=$(echo "$METRICS" | grep "DOM content" | grep -oE '[0-9]+')
  NETWORK_MS=$(echo "$METRICS" | grep "Network idle" | grep -oE '[0-9]+')
  REQUESTS=$(echo "$METRICS" | grep "requests" | grep -oE '[0-9]+')

  echo "$(date -Iseconds),$URL,$DOM_MS,$NETWORK_MS,$REQUESTS"
done
```

**Expected Outcome:** CSV metrics for Grafana or monitoring system.

**Success Criteria:**
- Tracks performance over time
- Integrates with monitoring stack
- Alerts on regression

---

## Flow 4: CI/CD Integration - Docker

Alex needs ar-crawl to run in a Docker CI environment.

```dockerfile
# Dockerfile.e2e-tests
FROM racket/racket:8.11

# Install ar-crawl
RUN raco pkg install --auto ar-crawl

# Install Playwright dependencies for JS rendering
RUN apt-get update && apt-get install -y \
    nodejs npm \
    && npm install -g playwright \
    && npx playwright install chromium \
    && npx playwright install-deps

WORKDIR /tests
COPY e2e-tests.sh .

ENTRYPOINT ["./e2e-tests.sh"]
```

```yaml
# .github/workflows/e2e.yml
name: E2E Tests
on: [push]

jobs:
  e2e:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Start application
        run: docker-compose up -d app

      - name: Wait for app
        run: sleep 10

      - name: Run e2e tests
        run: |
          docker build -f Dockerfile.e2e-tests -t e2e-tests .
          docker run --network host e2e-tests
```

**Expected Outcome:** Automated e2e crawl tests in CI.

**Success Criteria:**
- Works in containerized environment
- No manual browser setup
- Clear CI integration

---

## Flow 5: Content Drift Detection

Alex detects unexpected changes to critical pages.

```bash
#!/bin/bash
# content-drift.sh - Detect unexpected content changes

PAGE_URL="https://company.com/pricing"
BASELINE_FILE="baseline/pricing-content.txt"

# Crawl current content
ar-crawl crawl "$PAGE_URL" --format json --output /tmp/current.json

# Extract key content
ar-crawl extract /tmp/current.json \
  --fields '{"plans": "//div[@class=\"pricing-plans\"]", "prices": "//span[@class=\"price\"]"}' \
  > /tmp/current-content.txt

# Compare to baseline
if diff -q "$BASELINE_FILE" /tmp/current-content.txt > /dev/null 2>&1; then
  echo "OK: No content drift detected"
else
  echo "ALERT: Content changed!"
  diff "$BASELINE_FILE" /tmp/current-content.txt
  exit 1
fi
```

**Expected Outcome:** Alert when page content changes unexpectedly.

**Success Criteria:**
- Catches unauthorized changes
- Baseline comparison works
- Integrates with alerting

---

## Flow 6: Service Health Dashboard

Alex uses ar-crawl in a monitoring loop.

```bash
#!/bin/bash
# health-monitor.sh - Continuous monitoring

SERVICES=(
  "https://api.company.com/health|//status"
  "https://app.company.com|//div[@id='root']"
  "https://docs.company.com|//main"
)

while true; do
  for SERVICE in "${SERVICES[@]}"; do
    URL=$(echo "$SERVICE" | cut -d'|' -f1)
    SELECTOR=$(echo "$SERVICE" | cut -d'|' -f2)

    ar-crawl crawl "$URL" --format json --output /tmp/check.json 2>/dev/null
    CONTENT=$(ar-crawl extract /tmp/check.json --fields "{\"check\": \"$SELECTOR\"}" 2>/dev/null)

    if [ -n "$CONTENT" ]; then
      echo "$(date -Iseconds) OK $URL"
    else
      echo "$(date -Iseconds) FAIL $URL"
      # Send alert: curl -X POST alerting-webhook...
    fi
  done

  sleep 60
done
```

**Expected Outcome:** Simple uptime monitoring.

**Success Criteria:**
- Lightweight monitoring
- Webhook integration for alerts
- Runs on any server

---

# Edge Cases and Recovery

## Playwright Not Installed in Container

```bash
# Check if Playwright service is available
ar-crawl health --verbose

# Install if needed
ar-crawl services  # Lists available services
# Playwright auto-installs on first use, or:
cd playwright-service && npm install
```

## Timeout in CI Environment

```bash
# Increase timeout for slow CI runners
ar-crawl -s playwright crawl "$URL" \
  --pw-delay 10000 \
  --timeout 60000
```

## Testing Against localhost

```bash
# For local development testing
ar-crawl crawl http://localhost:3000 --format json

# Or with Playwright for local SPAs
ar-crawl -s playwright crawl http://localhost:3000 --pw-delay 2000
```
