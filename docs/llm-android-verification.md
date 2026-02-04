# LLM Agent Guide: Android APK Verification

This guide explains how to use ar-crawl's Android APK verification capabilities to test mobile apps, detect visual regressions, and verify code fixes.

## Quick Start

### Complete Verification in One Command

```bash
ar-crawl android verify app-debug.apk \
  --baseline baseline.png \
  --script tests.json \
  --output results.json
```

This single command:
1. Installs the APK
2. Launches the app
3. Compares against baseline screenshot
4. Runs test scripts
5. Checks for crashes
6. Reports pass/fail with details

## Prerequisites

- Android emulator running OR physical device connected
- ADB daemon accessible (`adb devices` shows device)
- Playwright service (auto-starts on demand)

## Workflow Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    APK Verification Workflow                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. INSTALL          2. LAUNCH           3. VISUAL              │
│  ┌─────────┐        ┌─────────┐         ┌─────────┐            │
│  │  APK    │───────▶│  App    │────────▶│ Compare │            │
│  │ Install │        │ Launch  │         │Baseline │            │
│  └─────────┘        └─────────┘         └─────────┘            │
│       │                  │                   │                  │
│       ▼                  ▼                   ▼                  │
│  4. TEST             5. CRASH           6. REPORT              │
│  ┌─────────┐        ┌─────────┐         ┌─────────┐            │
│  │  Run    │───────▶│  Crash  │────────▶│ Results │            │
│  │ Script  │        │  Check  │         │  JSON   │            │
│  └─────────┘        └─────────┘         └─────────┘            │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## CLI Commands

### 1. Capture Baseline Screenshots

Before verification, capture a baseline from a known-good state:

```bash
# From package name
ar-crawl android baseline com.example.app -o baseline.png

# From APK file
ar-crawl android baseline app-release.apk -o baseline.png -n initial-state
```

### 2. Run Verification

```bash
ar-crawl android verify app-debug.apk \
  -b baseline.png \
  -s tests.json \
  -t 5 \
  -o results.json
```

**Options:**
| Flag | Description |
|------|-------------|
| `-b, --baseline <file>` | Baseline screenshot for visual comparison |
| `-s, --script <file>` | Test script (JSON) |
| `-d, --device <serial>` | Target device |
| `-t, --threshold <pct>` | Visual diff threshold (default: 0%) |
| `-w, --wait <ms>` | Wait after launch (default: 3000ms) |
| `-o, --output <file>` | Results file (JSON) |
| `--continue` | Continue if visual diff fails |

### 3. Run Tests Only

```bash
ar-crawl android test tests.json -d emulator-5554 -o results.json
```

## Test Script Format

Create JSON test scripts with action steps:

```json
{
  "name": "Login Flow Test",
  "steps": [
    {
      "type": "tap",
      "selector": "res=com.example:id/username"
    },
    {
      "type": "fill",
      "selector": "res=com.example:id/username",
      "text": "testuser"
    },
    {
      "type": "tap",
      "selector": "text=Login"
    },
    {
      "type": "waitFor",
      "text": "Welcome"
    },
    {
      "type": "assert",
      "selector": "text=Welcome",
      "assertions": {
        "visible": true
      }
    }
  ]
}
```

### Available Step Types

| Type | Description | Parameters |
|------|-------------|------------|
| `tap` | Tap element | `selector` |
| `longTap` | Long press | `selector` |
| `fill` | Enter text | `selector`, `text` |
| `swipe` | Swipe gesture | `selector`, `direction`, `percent` |
| `scroll` | Scroll view | `selector`, `direction` |
| `waitFor` | Wait for condition | `selector`/`text`/`textGone`, `timeout` |
| `assert` | Verify element | `selector`, `assertions` |
| `screenshot` | Capture screen | `path` (optional) |

### Selector Formats

```
res=com.example:id/button     Resource ID
text=Submit                   Text content
desc=Menu button              Content description
class=android.widget.Button   Widget class
res=btn&&text=OK              Compound (AND)
```

## HTTP API for Programmatic Access

### Session-Based Verification

```bash
# 1. Create session
curl -X POST http://localhost:3033/android/session/create \
  -H "Content-Type: application/json" \
  -d '{"serial": "emulator-5554"}'
# Returns: {"sessionId": "android-abc123", ...}

# 2. Install APK
curl -X POST http://localhost:3033/android/session/android-abc123/action \
  -H "Content-Type: application/json" \
  -d '{"type": "installApk", "path": "/path/to/app.apk"}'

# 3. Launch app
curl -X POST http://localhost:3033/android/session/android-abc123/action \
  -H "Content-Type: application/json" \
  -d '{"type": "launch", "pkg": "com.example.app"}'

# 4. Compare screenshot
curl -X POST http://localhost:3033/android/session/android-abc123/compare \
  -H "Content-Type: application/json" \
  -d '{"baseline": "<base64-image>", "threshold": 5}'

# 5. Run test
curl -X POST http://localhost:3033/android/session/android-abc123/test \
  -H "Content-Type: application/json" \
  -d '{"name": "Login Test", "steps": [...]}'

# 6. Check for crashes
curl -X POST http://localhost:3033/android/session/android-abc123/action \
  -H "Content-Type: application/json" \
  -d '{"type": "checkCrash", "pkg": "com.example.app"}'

# 7. Cleanup
curl -X DELETE http://localhost:3033/android/session/android-abc123
```

### Key Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/android/devices` | GET | List connected devices |
| `/android/session/create` | POST | Create verification session |
| `/android/session/{id}/action` | POST | Execute actions |
| `/android/session/{id}/compare` | POST | Visual comparison |
| `/android/session/{id}/diff-report` | POST | Generate diff report |
| `/android/session/{id}/test` | POST | Run test script |
| `/android/session/{id}/assert` | POST | Assert element properties |
| `/android/session/{id}/wait-for` | POST | Wait for conditions |
| `/android/session/{id}` | DELETE | Close session |

## Result Interpretation

### Verification Output

```json
{
  "apk": "app-debug.apk",
  "device": "emulator-5554",
  "passed": true,
  "install": {
    "success": true,
    "package": "com.example.app"
  },
  "launch": {
    "success": true
  },
  "visual": {
    "success": true,
    "diffPercent": "0.50",
    "threshold": 5
  },
  "test": {
    "passed": true,
    "stepsExecuted": 5,
    "stepsPassed": 5
  },
  "crashCheck": {
    "crashed": false,
    "anr": false
  }
}
```

### Pass/Fail Criteria

| Check | Pass Condition |
|-------|---------------|
| Install | APK installed successfully |
| Launch | App launched without error |
| Visual | `diffPercent <= threshold` |
| Test | All assertions passed |
| Crash | No crash/ANR detected |

## Common Workflows

### Verify Bug Fix

```bash
# 1. Capture baseline from fixed build
ar-crawl android baseline app-fixed.apk -o baseline-fixed.png

# 2. Create regression test
echo '[
  {"type": "tap", "selector": "text=Submit"},
  {"type": "waitFor", "textGone": "Loading"},
  {"type": "assert", "selector": "text=Success", "assertions": {"visible": true}}
]' > bug-test.json

# 3. Verify the fix
ar-crawl android verify app-debug.apk \
  -b baseline-fixed.png \
  -s bug-test.json
```

### Visual Regression Testing

```bash
# Capture baseline
ar-crawl android baseline com.example.app -o baseline.png -w 5000

# After code changes, verify
ar-crawl android verify app-new.apk -b baseline.png -t 2
```

### Smoke Test New Build

```bash
# Quick install and crash check
ar-crawl android verify app-debug.apk
```

### Generate Visual Diff Report

```bash
# Via session
curl -X POST http://localhost:3033/android/session/{id}/diff-report \
  -H "Content-Type: application/json" \
  -d '{
    "baseline": "main-screen",
    "format": "html",
    "path": "/tmp/diff-report.html"
  }'
```

## Best Practices for LLM Agents

1. **Start with device discovery**
   ```bash
   ar-crawl android devices
   ```
   Ensure target device is available before verification.

2. **Use appropriate thresholds**
   - `0%` for pixel-perfect comparison
   - `1-5%` for minor rendering differences
   - `10%+` for layout-only verification

3. **Add wait times for animations**
   Use `-w` flag or `waitFor` steps to handle loading states.

4. **Include crash detection**
   Always specify `-p` package name for crash monitoring.

5. **Save results to file**
   Use `-o` for JSON output to parse results programmatically.

6. **Handle failures gracefully**
   Use `--continue` to run all checks even if visual diff fails.

## Troubleshooting

### Device Not Found
```bash
# Check ADB
adb devices

# Restart ADB
adb kill-server && adb start-server
```

### Visual Diff Always Fails
- Increase threshold: `-t 5`
- Add wait time: `-w 5000`
- Check screen orientation matches baseline

### Test Script Selector Not Found
- Use `ar-crawl android session` to interactively find selectors
- Try `text=` selector for visible text
- Use `res=` for resource IDs (inspect with UI Automator Viewer)

### App Crashes During Test
- Results include logcat output
- Check `crashCheck.crashMessage` for stack trace
- Ensure app has required permissions

## Example: Complete CI Pipeline

```bash
#!/bin/bash
set -e

# Start emulator (CI-specific)
emulator -avd test_device -no-window &
adb wait-for-device

# Run verification
ar-crawl android verify app-debug.apk \
  --baseline baseline.png \
  --script smoke-tests.json \
  --threshold 2 \
  --output results.json

# Check result
if jq -e '.passed' results.json > /dev/null; then
  echo "Verification PASSED"
  exit 0
else
  echo "Verification FAILED"
  jq '.test.failedStep, .crashCheck' results.json
  exit 1
fi
```
