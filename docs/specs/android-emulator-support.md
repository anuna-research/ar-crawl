# Android Emulator Support Specification

**Version:** 1.0.0
**Status:** Draft
**Date:** 2026-01-13

---

## Executive Summary

This specification defines the requirements, architecture, and contracts for adding Android emulator control to ar-crawl's session and replay functionality. The implementation leverages Playwright's experimental Android API to enable automated testing and crawling of Android applications and mobile web experiences through the existing session-based architecture.

---

## User Profiles

### User: Mobile QA Engineer

**Role:** Quality assurance engineer responsible for testing mobile applications and responsive web experiences across Android devices.

**Goals:**
- Record and replay user journeys on Android emulators
- Validate mobile-specific interactions (swipe, pinch, fling)
- Test WebView-based hybrid applications
- Capture screenshots for visual regression testing

**Constraints:**
- Technical proficiency: High (familiar with ADB, emulators)
- Environment: Development workstation with Android SDK installed
- Accessibility: Standard screen reader support not required for testing tools

**Daily Workflow:**
1. Start Android emulator (AVD)
2. Create ar-crawl session targeting the emulator
3. Execute mobile-specific actions (tap, swipe, scroll)
4. Launch and interact with WebViews
5. Export recording for CI/CD integration
6. Replay recordings to verify regressions

---

### User: Agent Developer

**Role:** Developer building AI agents that interact with mobile applications.

**Goals:**
- Programmatically control Android devices via HTTP API
- Extract structured data from Android app screens
- Automate app installation and testing workflows
- Integrate mobile automation into agent pipelines

**Constraints:**
- Technical proficiency: High
- Environment: Containerized or cloud-based execution
- Integration: RESTful HTTP API preferred

**Daily Workflow:**
1. Provision Android emulator in CI environment
2. Connect ar-crawl to emulator via ADB
3. Install target APK programmatically
4. Execute action sequences via HTTP endpoints
5. Capture device state and screenshots
6. Process results in agent logic

---

### Happy Path: Record Mobile Web Session

**Preconditions:**
- Android emulator running with ADB accessible
- Chrome 87+ installed on emulator
- `adb devices` shows emulator as authorized

**Steps:**
1. `POST /android/session/create` with emulator serial → Returns session ID
2. `POST /android/session/{id}/action` with `{type: "launchBrowser", url: "..."}` → Browser opens, returns page state
3. `POST /android/session/{id}/action` with `{type: "tap", selector: "..."}` → Element tapped, state updated
4. `POST /android/session/{id}/action` with `{type: "swipe", direction: "up", percent: 50}` → Page scrolled
5. `GET /android/session/{id}/state` → Returns current viewport snapshot
6. `POST /android/session/{id}/commit` → Returns Chrome DevTools-compatible recording

**Postconditions:**
- Recording JSON saved with all actions in replayable format
- Session closed, device connection released

**Failure Modes:**
- Emulator not detected → Error with ADB troubleshooting guidance
- App crash during recording → Session preserved, partial recording returned
- WebView not available → Error indicating Chrome requirements

---

### Happy Path: Replay Mobile Recording

**Preconditions:**
- Valid Android recording JSON from previous session
- Compatible emulator running

**Steps:**
1. `POST /android/replay` with recording JSON and target device → Replay starts
2. System executes each step with configurable delays
3. System captures screenshots at each step (optional)
4. `GET /android/replay/{id}/status` → Returns progress and any failures
5. Replay completes → Returns summary with pass/fail per step

**Postconditions:**
- All actions replayed on target device
- Comparison report available if baseline provided

**Failure Modes:**
- Selector not found → Retry with timeout, then fail with context
- Device disconnected → Attempt reconnection, preserve progress
- App state divergence → Warning with screenshot diff

---

## Requirements

### REQ-001: Android Device Discovery

The system SHALL enumerate available Android devices/emulators connected via ADB WITHIN 5 seconds FOR any authenticated user WITH a list containing device serial, model, and status.

**Acceptance Criteria:**
- Returns all devices shown by `adb devices`
- Includes device model name from `adb shell getprop ro.product.model`
- Filters to only "device" status (not "unauthorized" or "offline")
- Supports custom ADB host:port configuration

**Trace:**
- TEST-001, TEST-002
- CON-001
- OBS-001

---

### REQ-002: Android Session Creation

The system SHALL create an Android automation session connected to a specified device WITHIN 10 seconds FOR any authenticated user WITH a unique session ID and initial device state.

**Acceptance Criteria:**
- Accepts device serial number as required parameter
- Optionally accepts timeout configuration
- Returns session ID, device model, screen dimensions
- Maintains session in memory with activity timestamp
- Supports concurrent sessions on different devices

**Trace:**
- TEST-003, TEST-004
- CON-002
- OBS-002

---

### REQ-003: Native App Interaction

The system SHALL execute native Android UI actions (tap, swipe, scroll, pinch, fling, drag, long-tap) on widgets identified by selector WITHIN 2 seconds per action FOR session users WITH action confirmation and updated state.

**Selector Types Supported:**
- Resource ID: `res=com.example:id/button`
- Text content: `text=Submit`
- Content description: `desc=Menu button`
- Class name: `class=android.widget.Button`
- Compound: `res=button&&text=OK`

**Acceptance Criteria:**
- All Playwright AndroidDevice interaction methods exposed
- Actions recorded in session step history
- Timeout configurable per action (default: 30s)
- Returns widget info after action when available

**Trace:**
- TEST-005 through TEST-012
- CON-003
- OBS-003

---

### REQ-004: Text Input

The system SHALL input text into Android text fields via two methods: (1) widget-targeted fill, (2) raw keyboard input WITHIN 1 second per operation FOR session users WITH confirmation of input completion.

**Acceptance Criteria:**
- `fill` action targets specific widget by selector
- `type` action sends keystrokes to focused widget
- `press` action sends individual key codes
- Supports Android key constants (KEYCODE_ENTER, etc.)
- Handles IME composition for non-Latin scripts

**Trace:**
- TEST-013, TEST-014
- CON-003
- OBS-003

---

### REQ-005: WebView Automation

The system SHALL detect and connect to Android WebViews WITHIN 5 seconds FOR session users WITH a Playwright Page interface for web automation.

**Acceptance Criteria:**
- Lists all active WebViews on device
- Filters by package name or socket name
- Returns Playwright Page for standard web automation
- Emits events when WebViews open/close
- Maintains WebView connection through app navigation

**Trace:**
- TEST-015, TEST-016
- CON-004
- OBS-004

---

### REQ-006: Browser Launch

The system SHALL launch Chrome browser on Android device and return a BrowserContext WITHIN 15 seconds FOR session users WITH full Playwright browser automation capabilities.

**Acceptance Criteria:**
- Launches Chrome with configurable options
- Returns persistent BrowserContext
- Supports all standard Playwright page operations
- Integrates with existing session recording format
- Handles Chrome feature flags configuration

**Trace:**
- TEST-017, TEST-018
- CON-005
- OBS-004

---

### REQ-007: Device State Capture

The system SHALL capture device screenshots and widget hierarchy WITHIN 3 seconds FOR session users WITH PNG image buffer and structured element data.

**Acceptance Criteria:**
- Screenshot returns PNG Buffer, optionally saves to path
- Widget info returns AndroidElementInfo structure
- Supports capturing specific widget by selector
- Device must be awake (documented limitation)

**Trace:**
- TEST-019, TEST-020
- CON-006
- OBS-005

---

### REQ-008: APK Management

The system SHALL install APK files onto connected Android device WITHIN 60 seconds FOR session users WITH installation confirmation.

**Acceptance Criteria:**
- Accepts file path or Buffer containing APK
- Supports additional `adb install` arguments
- Returns success/failure with error details
- Handles APK already installed scenarios

**Trace:**
- TEST-021
- CON-007
- OBS-006

---

### REQ-009: Shell Command Execution

The system SHALL execute ADB shell commands on device WITHIN 30 seconds FOR session users WITH command output buffer.

**Acceptance Criteria:**
- Executes arbitrary shell commands
- Returns stdout as Buffer
- Supports interactive shell via AndroidSocket
- Commands timeout configurable

**Trace:**
- TEST-022, TEST-023
- CON-008
- OBS-007

---

### REQ-010: File Transfer

The system SHALL push files to Android device filesystem WITHIN 30 seconds per 10MB FOR session users WITH transfer confirmation.

**Acceptance Criteria:**
- Accepts local file path or Buffer
- Accepts target device path
- Supports file permission mode setting
- Returns success with bytes transferred

**Trace:**
- TEST-024
- CON-009
- OBS-006

---

### REQ-011: Session Recording Export

The system SHALL export Android session recordings in Chrome DevTools Recorder-compatible format WITHIN 1 second FOR session users WITH complete action history.

**Acceptance Criteria:**
- Exports all session actions as steps array
- Converts Android-specific actions to extended format
- Includes device metadata (model, serial, dimensions)
- Maintains compatibility with existing replay infrastructure
- Supports custom step annotations

**Trace:**
- TEST-025, TEST-026
- CON-010
- OBS-008

---

### REQ-012: Recording Replay

The system SHALL replay Android session recordings on target device WITHIN original-duration + 50% overhead FOR session users WITH step-by-step execution status.

**Acceptance Criteria:**
- Accepts recording JSON from session export
- Supports different target device than original
- Provides progress callbacks/polling
- Captures screenshots per step (optional)
- Reports pass/fail with failure context

**Trace:**
- TEST-027, TEST-028, TEST-029
- CON-011
- OBS-009

---

### REQ-013: Remote Device Connection

The system SHALL connect to Android devices via WebSocket endpoint WITHIN 10 seconds FOR session users WITH full device control capabilities.

**Acceptance Criteria:**
- Accepts WebSocket URL from `android.launchServer()`
- Supports custom headers for authentication
- Supports slowMo for debugging
- Maintains connection with automatic reconnection

**Trace:**
- TEST-030
- CON-012
- OBS-010

---

## Non-Functional Requirements

### NFR-001: Action Latency

Response time SHALL be ≤ 500ms UNDER normal device load WITH 95th percentile for standard actions (tap, swipe, type).

**Trace:**
- TEST-031
- OBS-011

---

### NFR-002: Session Concurrency

The system SHALL support ≥ 5 concurrent Android sessions UNDER standard server resources WITH no degradation in action latency.

**Trace:**
- TEST-032
- OBS-012

---

### NFR-003: Memory Efficiency

Memory usage SHALL be ≤ 200MB per active Android session UNDER normal operation WITH automatic cleanup on session close.

**Trace:**
- TEST-033
- OBS-013

---

### NFR-004: Connection Resilience

The system SHALL maintain device connection through transient ADB interruptions ≤ 5 seconds UNDER network instability WITH automatic reconnection and session preservation.

**Trace:**
- TEST-034
- OBS-014

---

### NFR-005: Recording Fidelity

Replay accuracy SHALL be ≥ 95% step success rate UNDER identical device/app conditions WITH detailed failure diagnostics for mismatches.

**Trace:**
- TEST-035
- OBS-015

---

## Architecture Decision Records

### ADR-001: Extend Playwright Service vs. Separate Service

**Context:**
Android automation could be implemented as:
1. Extension to existing `/playwright-service/server.js`
2. Separate dedicated Android service
3. Direct integration in Racket CLI

**Decision:** Extend existing Playwright service

**Rationale:**
- Playwright Android API uses same Node.js runtime
- Shares session management patterns with browser automation
- Single service simplifies deployment and discovery
- Consistent HTTP API design for agents
- Reuses existing Chrome DevTools recording format

**Consequences:**
- Playwright service grows in scope
- Android-specific endpoints namespaced under `/android/`
- Shared session timeout/cleanup infrastructure
- Single point of failure for both browser and Android

**Trade-offs:**
- (+) Simpler deployment, single service
- (+) Code reuse for recording/replay
- (-) Service complexity increases
- (-) Browser issues could affect Android

---

### ADR-002: Selector Strategy for Native Apps

**Context:**
Native Android widgets need selectors for automation targeting. Options:
1. Playwright's native selector format (resource-id, text, etc.)
2. UiAutomator2 selector syntax
3. Custom unified selector DSL
4. XPath over UI hierarchy

**Decision:** Use Playwright's native selector object format with string shorthand

**Rationale:**
- Playwright API already defines selector structure
- Most intuitive for simple cases (`text=Submit`)
- Full power available via object syntax
- Consistent with WebView/browser selectors

**Format Examples:**
```javascript
// String shorthand
"text=Submit"
"res=com.example:id/button"
"desc=Menu"

// Object selector (complex)
{ res: "button", text: "OK", enabled: true }

// Compound
{ res: "list", childIndex: 0 }
```

**Consequences:**
- Documentation must explain both formats
- Parser needed for string shorthand
- Object format passed directly to Playwright

---

### ADR-003: Recording Format Extension

**Context:**
Chrome DevTools Recorder format designed for web, not native Android. Options:
1. Extend DevTools format with Android-specific step types
2. Create separate Android recording format
3. Convert Android actions to closest web equivalents

**Decision:** Extend DevTools format with Android-specific types under `android` namespace

**Rationale:**
- Maintains compatibility with DevTools ecosystem
- Clear distinction between web and native actions
- Supports hybrid recordings (native + WebView)
- Future-proof for iOS when available

**Format Extension:**
```json
{
  "type": "android/tap",
  "selector": "text=Submit",
  "duration": 100,
  "timeout": 5000
}

{
  "type": "android/swipe",
  "selector": "res=list",
  "direction": "up",
  "percent": 50,
  "speed": 500
}

{
  "type": "android/launchBrowser",
  "url": "https://example.com",
  "options": {}
}
```

**Consequences:**
- Replay must handle `android/*` step types
- Web replay ignores/errors on Android steps
- Hybrid recordings require device context

---

### ADR-004: WebView Bridge Strategy

**Context:**
WebViews require special handling to bridge native and web contexts. Options:
1. Automatic WebView detection and session forking
2. Explicit WebView connection via API call
3. Transparent proxy that routes to appropriate context

**Decision:** Explicit WebView connection with session sub-context

**Rationale:**
- Matches Playwright API design
- User controls when to enter/exit WebView context
- Clear recording boundaries
- Supports multiple simultaneous WebViews

**Implementation:**
```javascript
// Enter WebView context
POST /android/session/{id}/action
{ "type": "connectWebView", "selector": { "pkg": "com.example" } }
// Returns webViewId

// WebView actions use standard web format
POST /android/session/{id}/webview/{webViewId}/action
{ "type": "click", "selector": "button#submit" }

// Exit WebView
POST /android/session/{id}/action
{ "type": "disconnectWebView", "webViewId": "..." }
```

**Consequences:**
- Two action endpoints during WebView sessions
- Recording contains context switches
- Replay must track WebView state

---

## Contract Specifications

### CON-001: Device Discovery Endpoint

**Endpoint:** `GET /android/devices`

**Pre-conditions:**
- Playwright service running
- ADB daemon accessible

**Request Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| host | string | No | ADB server host (default: localhost) |
| port | number | No | ADB server port (default: 5037) |

**Response (200 OK):**
```json
{
  "devices": [
    {
      "serial": "emulator-5554",
      "model": "sdk_gphone64_x86_64",
      "status": "device",
      "androidVersion": "14"
    }
  ]
}
```

**Error Model:**
| Code | Condition | Response |
|------|-----------|----------|
| 500 | ADB not running | `{"error": "ADB daemon not accessible", "hint": "Run 'adb start-server'"}` |
| 504 | ADB timeout | `{"error": "ADB connection timeout"}` |

**Implements:** REQ-001

**Verified by:** TEST-001, TEST-002

---

### CON-002: Session Creation Endpoint

**Endpoint:** `POST /android/session/create`

**Pre-conditions:**
- Device serial exists and is authorized
- No existing session on same device (optional enforcement)

**Request Body:**
```json
{
  "serial": "emulator-5554",
  "options": {
    "timeout": 30000,
    "omitDriverInstall": false
  }
}
```

**Response (201 Created):**
```json
{
  "sessionId": "android-a1b2c3d4",
  "device": {
    "serial": "emulator-5554",
    "model": "sdk_gphone64_x86_64"
  },
  "screen": {
    "width": 1080,
    "height": 2400
  },
  "createdAt": "2026-01-13T10:30:00Z"
}
```

**Post-conditions:**
- Session stored in memory
- Device connection established
- Session appears in `/android/sessions` list

**Error Model:**
| Code | Condition | Response |
|------|-----------|----------|
| 400 | Missing serial | `{"error": "Device serial required"}` |
| 404 | Device not found | `{"error": "Device not found", "serial": "..."}` |
| 409 | Session exists | `{"error": "Session already exists for device"}` |
| 500 | Connection failed | `{"error": "Failed to connect to device"}` |

**Implements:** REQ-002

**Verified by:** TEST-003, TEST-004

---

### CON-003: Native Action Endpoint

**Endpoint:** `POST /android/session/{sessionId}/action`

**Pre-conditions:**
- Valid session ID
- Device still connected

**Request Body - Tap:**
```json
{
  "type": "tap",
  "selector": "text=Submit",
  "options": {
    "duration": 100,
    "timeout": 5000
  }
}
```

**Request Body - Swipe:**
```json
{
  "type": "swipe",
  "selector": "res=com.example:id/list",
  "direction": "up",
  "percent": 50,
  "options": {
    "speed": 500,
    "timeout": 5000
  }
}
```

**Request Body - Scroll:**
```json
{
  "type": "scroll",
  "selector": "res=scroll_view",
  "direction": "down",
  "percent": 30,
  "options": {
    "speed": 300,
    "timeout": 5000
  }
}
```

**Request Body - Pinch:**
```json
{
  "type": "pinchOpen",
  "selector": "res=image_view",
  "percent": 50,
  "options": {
    "speed": 200,
    "timeout": 5000
  }
}
```

**Request Body - Fling:**
```json
{
  "type": "fling",
  "selector": "res=list",
  "direction": "down",
  "options": {
    "speed": 1000,
    "timeout": 5000
  }
}
```

**Request Body - Drag:**
```json
{
  "type": "drag",
  "selector": "res=draggable",
  "dest": { "x": 500, "y": 800 },
  "options": {
    "speed": 300,
    "timeout": 5000
  }
}
```

**Request Body - Long Tap:**
```json
{
  "type": "longTap",
  "selector": "res=item",
  "options": {
    "timeout": 5000
  }
}
```

**Request Body - Wait:**
```json
{
  "type": "wait",
  "selector": "text=Loading",
  "options": {
    "state": "gone",
    "timeout": 10000
  }
}
```

**Response (200 OK):**
```json
{
  "success": true,
  "action": "tap",
  "stepIndex": 5,
  "widgetInfo": {
    "bounds": { "x": 100, "y": 200, "width": 200, "height": 50 },
    "text": "Submit",
    "enabled": true,
    "focused": false
  },
  "duration": 150
}
```

**Post-conditions:**
- Action recorded in session steps
- Session lastActivity updated

**Error Model:**
| Code | Condition | Response |
|------|-----------|----------|
| 400 | Invalid action type | `{"error": "Unknown action type", "type": "..."}` |
| 404 | Session not found | `{"error": "Session not found"}` |
| 404 | Selector not found | `{"error": "Widget not found", "selector": "..."}` |
| 408 | Action timeout | `{"error": "Action timed out", "timeout": 5000}` |
| 500 | Device disconnected | `{"error": "Device connection lost"}` |

**Implements:** REQ-003, REQ-004

**Verified by:** TEST-005 through TEST-014

---

### CON-004: WebView Connection Endpoint

**Endpoint:** `POST /android/session/{sessionId}/webview/connect`

**Pre-conditions:**
- Active session
- WebView present on device

**Request Body:**
```json
{
  "selector": {
    "pkg": "com.example.app"
  },
  "options": {
    "timeout": 5000
  }
}
```

**Response (200 OK):**
```json
{
  "webViewId": "wv-1234",
  "pkg": "com.example.app",
  "pid": 12345,
  "url": "https://example.com/page"
}
```

**Post-conditions:**
- WebView context available for page operations
- WebView ID tracked in session

**Error Model:**
| Code | Condition | Response |
|------|-----------|----------|
| 404 | No matching WebView | `{"error": "WebView not found", "selector": {...}}` |
| 500 | Connection failed | `{"error": "Failed to connect to WebView"}` |

**Implements:** REQ-005

**Verified by:** TEST-015, TEST-016

---

### CON-005: Browser Launch Endpoint

**Endpoint:** `POST /android/session/{sessionId}/browser/launch`

**Pre-conditions:**
- Active session
- Chrome installed on device

**Request Body:**
```json
{
  "url": "https://example.com",
  "options": {
    "locale": "en-US",
    "colorScheme": "dark"
  }
}
```

**Response (200 OK):**
```json
{
  "browserId": "br-5678",
  "contextId": "ctx-9012",
  "page": {
    "url": "https://example.com",
    "title": "Example Domain"
  }
}
```

**Post-conditions:**
- Chrome browser launched
- BrowserContext available for standard operations
- Page actions route through existing browser action handlers

**Implements:** REQ-006

**Verified by:** TEST-017, TEST-018

---

### CON-006: Screenshot Endpoint

**Endpoint:** `GET /android/session/{sessionId}/screenshot`

**Pre-conditions:**
- Active session
- Device screen on

**Request Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| path | string | No | Save to file path |
| selector | string | No | Capture specific widget |

**Response (200 OK):**
- Content-Type: `image/png`
- Body: PNG image buffer

**Alternative Response (with path):**
```json
{
  "saved": true,
  "path": "/tmp/screenshot.png",
  "size": 245678
}
```

**Error Model:**
| Code | Condition | Response |
|------|-----------|----------|
| 400 | Screen off | `{"error": "Device screen is off", "hint": "Wake device first"}` |

**Implements:** REQ-007

**Verified by:** TEST-019, TEST-020

---

### CON-007: APK Install Endpoint

**Endpoint:** `POST /android/session/{sessionId}/install`

**Pre-conditions:**
- Active session
- Valid APK file

**Request Body:**
```json
{
  "apk": "/path/to/app.apk",
  "options": {
    "args": ["-r", "-d"]
  }
}
```

**Response (200 OK):**
```json
{
  "installed": true,
  "package": "com.example.app",
  "duration": 5432
}
```

**Implements:** REQ-008

**Verified by:** TEST-021

---

### CON-008: Shell Command Endpoint

**Endpoint:** `POST /android/session/{sessionId}/shell`

**Request Body:**
```json
{
  "command": "pm list packages"
}
```

**Response (200 OK):**
```json
{
  "output": "package:com.android.settings\npackage:com.google.chrome\n...",
  "exitCode": 0
}
```

**Implements:** REQ-009

**Verified by:** TEST-022, TEST-023

---

### CON-009: File Push Endpoint

**Endpoint:** `POST /android/session/{sessionId}/push`

**Request Body:**
```json
{
  "file": "/local/path/data.json",
  "path": "/sdcard/Download/data.json",
  "options": {
    "mode": 420
  }
}
```

**Response (200 OK):**
```json
{
  "pushed": true,
  "bytes": 1234,
  "path": "/sdcard/Download/data.json"
}
```

**Implements:** REQ-010

**Verified by:** TEST-024

---

### CON-010: Session Commit Endpoint

**Endpoint:** `POST /android/session/{sessionId}/commit`

**Request Body:**
```json
{
  "title": "Login Flow Test",
  "metadata": {
    "author": "qa-team",
    "version": "1.0"
  }
}
```

**Response (200 OK):**
```json
{
  "title": "Login Flow Test",
  "device": {
    "serial": "emulator-5554",
    "model": "sdk_gphone64_x86_64",
    "screen": { "width": 1080, "height": 2400 }
  },
  "steps": [
    {
      "type": "android/tap",
      "selector": "res=com.example:id/username",
      "timestamp": 1000
    },
    {
      "type": "android/fill",
      "selector": "res=com.example:id/username",
      "text": "testuser",
      "timestamp": 1500
    }
  ],
  "metadata": {
    "author": "qa-team",
    "version": "1.0",
    "recordedAt": "2026-01-13T10:35:00Z",
    "duration": 45000
  }
}
```

**Post-conditions:**
- Session closed
- Device connection released
- Recording JSON returned

**Implements:** REQ-011

**Verified by:** TEST-025, TEST-026

---

### CON-011: Replay Endpoint

**Endpoint:** `POST /android/replay`

**Request Body:**
```json
{
  "recording": { "...recording JSON..." },
  "options": {
    "serial": "emulator-5556",
    "speed": 1.0,
    "screenshotPerStep": true,
    "stopOnError": false
  }
}
```

**Response (200 OK - Async Start):**
```json
{
  "replayId": "replay-abcd",
  "status": "running",
  "totalSteps": 15
}
```

**Status Endpoint:** `GET /android/replay/{replayId}/status`
```json
{
  "replayId": "replay-abcd",
  "status": "completed",
  "progress": {
    "completed": 15,
    "total": 15,
    "failed": 0
  },
  "results": [
    { "step": 0, "status": "passed", "duration": 120 },
    { "step": 1, "status": "passed", "duration": 450 }
  ],
  "screenshots": [
    "/tmp/replay-abcd/step-0.png",
    "/tmp/replay-abcd/step-1.png"
  ]
}
```

**Implements:** REQ-012

**Verified by:** TEST-027, TEST-028, TEST-029

---

### CON-012: Remote Connection Endpoint

**Endpoint:** `POST /android/connect`

**Request Body:**
```json
{
  "wsEndpoint": "ws://remote-server:3000/android",
  "options": {
    "headers": { "Authorization": "Bearer ..." },
    "slowMo": 100,
    "timeout": 30000
  }
}
```

**Response (200 OK):**
```json
{
  "sessionId": "remote-xyz",
  "device": {
    "serial": "remote-device",
    "model": "Pixel 6"
  }
}
```

**Implements:** REQ-013

**Verified by:** TEST-030

---

## Test Specifications

### TEST-001: Device Discovery - Emulator Running

**Linked Requirement:** REQ-001

**Preconditions:**
- Android emulator running
- ADB daemon started

**Steps:**
1. Start Android emulator via AVD manager
2. Verify `adb devices` shows device
3. Call `GET /android/devices`
4. Verify response contains emulator

**Expected Results:**
- Response includes device with serial matching emulator
- Model field populated
- Status is "device"

---

### TEST-002: Device Discovery - No Devices

**Linked Requirement:** REQ-001

**Preconditions:**
- No Android devices connected
- ADB daemon running

**Steps:**
1. Ensure no emulators running
2. Call `GET /android/devices`

**Expected Results:**
- Response: `{"devices": []}`
- HTTP 200 (empty is valid state)

---

### TEST-003: Session Creation - Success

**Linked Requirement:** REQ-002

**Preconditions:**
- Emulator running and authorized

**Steps:**
1. Get device serial from discovery
2. Call `POST /android/session/create` with serial
3. Verify session created

**Expected Results:**
- HTTP 201
- Valid sessionId returned
- Device info matches emulator
- Screen dimensions reasonable (>0)

---

### TEST-004: Session Creation - Invalid Serial

**Linked Requirement:** REQ-002

**Steps:**
1. Call `POST /android/session/create` with fake serial

**Expected Results:**
- HTTP 404
- Error message indicates device not found

---

### TEST-005: Tap Action

**Linked Requirement:** REQ-003

**Preconditions:**
- Active session
- Settings app open (reliable UI elements)

**Steps:**
1. Create session
2. Open Settings via shell
3. Tap on "Network & internet" (or similar)
4. Verify navigation occurred

**Expected Results:**
- Action succeeds
- Step recorded in session
- UI navigated to tapped item

---

### TEST-006: Swipe Action

**Linked Requirement:** REQ-003

**Preconditions:**
- Active session
- Scrollable list visible

**Steps:**
1. Open Settings
2. Swipe up on list
3. Verify scroll position changed

**Expected Results:**
- List scrolled
- Action recorded with direction and percent

---

### TEST-007: Scroll Action

**Linked Requirement:** REQ-003

**Steps:**
1. Open scrollable content
2. Scroll down 50%
3. Verify new content visible

**Expected Results:**
- Smooth scroll executed
- Position changed proportionally

---

### TEST-008: Pinch Open Action

**Linked Requirement:** REQ-003

**Preconditions:**
- App with pinch-zoom support (Gallery, Maps)

**Steps:**
1. Open zoomable content
2. Execute pinchOpen 50%
3. Verify zoom level increased

**Expected Results:**
- Content zoomed in
- Action recorded

---

### TEST-009: Pinch Close Action

**Linked Requirement:** REQ-003

**Steps:**
1. Start from zoomed state
2. Execute pinchClose 50%
3. Verify zoom level decreased

---

### TEST-010: Fling Action

**Linked Requirement:** REQ-003

**Steps:**
1. Open scrollable list
2. Fling down
3. Verify rapid scroll with momentum

**Expected Results:**
- Fast scroll executed
- Settles after momentum

---

### TEST-011: Drag Action

**Linked Requirement:** REQ-003

**Preconditions:**
- App with draggable elements (home screen icons)

**Steps:**
1. Long press icon to enable drag
2. Drag to new position
3. Verify icon moved

---

### TEST-012: Long Tap Action

**Linked Requirement:** REQ-003

**Steps:**
1. Long tap on list item
2. Verify context menu appears

**Expected Results:**
- Context menu or selection mode activated
- Action recorded with implicit duration

---

### TEST-013: Fill Action

**Linked Requirement:** REQ-004

**Steps:**
1. Open app with text field
2. Fill text into field by selector
3. Verify text entered

**Expected Results:**
- Text field contains expected value
- Recorded with selector and text

---

### TEST-014: Type Action - Keyboard Input

**Linked Requirement:** REQ-004

**Steps:**
1. Focus text field
2. Type text character by character
3. Press Enter key

**Expected Results:**
- Characters appear sequentially
- Enter triggers form submission or newline

---

### TEST-015: WebView Detection

**Linked Requirement:** REQ-005

**Preconditions:**
- App with WebView running

**Steps:**
1. Launch hybrid app
2. Call webViews() to list
3. Verify WebView detected

**Expected Results:**
- WebView in list with package name
- PID valid

---

### TEST-016: WebView Page Interaction

**Linked Requirement:** REQ-005

**Steps:**
1. Connect to WebView
2. Get page
3. Execute standard click
4. Verify web element clicked

**Expected Results:**
- Page returned
- Click succeeded
- Navigation/action occurred in WebView

---

### TEST-017: Browser Launch

**Linked Requirement:** REQ-006

**Steps:**
1. Launch browser with URL
2. Verify Chrome opened
3. Verify page loaded

**Expected Results:**
- Chrome launched
- URL navigated
- Page title accessible

---

### TEST-018: Browser Context Operations

**Linked Requirement:** REQ-006

**Steps:**
1. Launch browser
2. Execute standard Playwright operations (click, fill)
3. Verify operations succeed

**Expected Results:**
- All standard browser actions work
- Recorded in compatible format

---

### TEST-019: Screenshot Capture

**Linked Requirement:** REQ-007

**Steps:**
1. Ensure unique content on screen
2. Capture screenshot
3. Verify PNG returned

**Expected Results:**
- Valid PNG buffer
- Image dimensions match screen
- Content visible in image

---

### TEST-020: Widget Screenshot

**Linked Requirement:** REQ-007

**Steps:**
1. Capture specific widget by selector
2. Verify cropped image

**Expected Results:**
- Image matches widget bounds
- Smaller than full screen

---

### TEST-021: APK Installation

**Linked Requirement:** REQ-008

**Preconditions:**
- Valid APK file available

**Steps:**
1. Install APK via endpoint
2. Verify package appears in list
3. Launch installed app

**Expected Results:**
- Installation succeeds
- App launchable

---

### TEST-022: Shell Command - Simple

**Linked Requirement:** REQ-009

**Steps:**
1. Execute `pm list packages | head -5`
2. Verify output returned

**Expected Results:**
- Package names in output
- Exit code 0

---

### TEST-023: Shell Command - Interactive Socket

**Linked Requirement:** REQ-009

**Steps:**
1. Open shell socket
2. Write command
3. Read output
4. Close socket

**Expected Results:**
- Socket opened
- Data events received
- Clean close

---

### TEST-024: File Push

**Linked Requirement:** REQ-010

**Steps:**
1. Create test file locally
2. Push to device
3. Verify via shell `cat` command

**Expected Results:**
- File exists on device
- Content matches

---

### TEST-025: Session Recording Export

**Linked Requirement:** REQ-011

**Steps:**
1. Create session
2. Execute multiple actions
3. Commit session
4. Verify recording JSON

**Expected Results:**
- All actions in steps array
- Timestamps sequential
- Device metadata present

---

### TEST-026: Recording Format Compatibility

**Linked Requirement:** REQ-011

**Steps:**
1. Export recording
2. Validate against DevTools schema (extended)
3. Verify android/* types present

**Expected Results:**
- Valid JSON structure
- Android actions use android/ prefix
- Selectors preserved

---

### TEST-027: Recording Replay - Same Device

**Linked Requirement:** REQ-012

**Steps:**
1. Record simple flow (3-5 actions)
2. Reset app state
3. Replay recording
4. Verify end state matches

**Expected Results:**
- All steps pass
- Final state equivalent to original

---

### TEST-028: Recording Replay - Different Device

**Linked Requirement:** REQ-012

**Steps:**
1. Record on emulator A
2. Replay on emulator B (same config)
3. Verify actions succeed

**Expected Results:**
- Actions adapt to device
- Selectors resolve correctly

---

### TEST-029: Replay Error Handling

**Linked Requirement:** REQ-012

**Steps:**
1. Create recording with specific selector
2. Modify app to remove target element
3. Replay recording
4. Verify error reported

**Expected Results:**
- Step fails with clear error
- Selector included in error
- Other steps continue (if stopOnError=false)

---

### TEST-030: Remote WebSocket Connection

**Linked Requirement:** REQ-013

**Preconditions:**
- Remote android.launchServer() running

**Steps:**
1. Get WebSocket endpoint
2. Connect via /android/connect
3. Execute action
4. Verify remote device responds

**Expected Results:**
- Connection established
- Actions execute on remote device

---

### TEST-031: Action Latency

**Linked Requirement:** NFR-001

**Steps:**
1. Execute 100 tap actions
2. Measure response times
3. Calculate 95th percentile

**Expected Results:**
- 95th percentile ≤ 500ms

---

### TEST-032: Concurrent Sessions

**Linked Requirement:** NFR-002

**Steps:**
1. Start 5 emulators
2. Create 5 concurrent sessions
3. Execute actions on all simultaneously
4. Measure latencies

**Expected Results:**
- All sessions functional
- No significant latency increase

---

### TEST-033: Memory Usage

**Linked Requirement:** NFR-003

**Steps:**
1. Measure baseline memory
2. Create session
3. Execute 50 actions
4. Measure memory increase
5. Close session
6. Verify cleanup

**Expected Results:**
- Peak ≤ 200MB per session
- Memory released on close

---

### TEST-034: Connection Resilience

**Linked Requirement:** NFR-004

**Steps:**
1. Create session
2. Briefly kill ADB server (<5s)
3. Restart ADB
4. Execute action

**Expected Results:**
- Session survives
- Action succeeds after reconnection

---

### TEST-035: Replay Accuracy

**Linked Requirement:** NFR-005

**Steps:**
1. Record 20 diverse actions
2. Replay 10 times
3. Calculate success rate

**Expected Results:**
- ≥ 95% steps pass across runs

---

## Observability Specifications

### OBS-001: Device Discovery Metrics

**Metric:** `android.devices.discovered`
- Type: Gauge
- Labels: `status` (device/offline/unauthorized)
- Purpose: Track connected device inventory

**Log:** Device discovery events
- Level: INFO
- Fields: serial, model, status, discovery_time_ms

---

### OBS-002: Session Lifecycle

**Metric:** `android.sessions.active`
- Type: Gauge
- Purpose: Track concurrent session count

**Metric:** `android.sessions.created_total`
- Type: Counter
- Labels: `status` (success/failure)

**Log:** Session create/close events
- Level: INFO
- Fields: session_id, device_serial, duration_ms

---

### OBS-003: Action Execution

**Metric:** `android.actions.duration_ms`
- Type: Histogram
- Labels: `action_type`, `status`
- Buckets: 50, 100, 250, 500, 1000, 2500, 5000

**Metric:** `android.actions.total`
- Type: Counter
- Labels: `action_type`, `status`

**Log:** Action execution
- Level: DEBUG
- Fields: session_id, action_type, selector, duration_ms, success

---

### OBS-004: WebView/Browser Events

**Metric:** `android.webview.connections`
- Type: Counter
- Labels: `package`

**Log:** WebView lifecycle
- Level: INFO
- Fields: session_id, webview_id, package, pid, event (connect/close)

---

### OBS-005: Screenshot Capture

**Metric:** `android.screenshots.total`
- Type: Counter

**Metric:** `android.screenshots.size_bytes`
- Type: Histogram

---

### OBS-006: File Operations

**Metric:** `android.file_ops.total`
- Type: Counter
- Labels: `operation` (push/install)

**Log:** File operations
- Level: INFO
- Fields: operation, path, size_bytes, duration_ms

---

### OBS-007: Shell Commands

**Metric:** `android.shell.commands_total`
- Type: Counter
- Labels: `exit_code`

**Log:** Shell execution (sanitized)
- Level: DEBUG
- Fields: command_prefix, exit_code, duration_ms

---

### OBS-008: Recording Export

**Metric:** `android.recordings.exported_total`
- Type: Counter

**Metric:** `android.recordings.steps`
- Type: Histogram
- Purpose: Distribution of recording lengths

---

### OBS-009: Replay Execution

**Metric:** `android.replay.total`
- Type: Counter
- Labels: `status` (completed/failed/cancelled)

**Metric:** `android.replay.step_success_rate`
- Type: Gauge
- Purpose: Track replay reliability

---

### OBS-010: Remote Connections

**Metric:** `android.remote.connections`
- Type: Counter
- Labels: `status`

---

### OBS-011 through OBS-015: NFR Monitoring

Metrics for latency percentiles, concurrency, memory, resilience, and accuracy as defined in NFR specifications.

---

## Implementation Plan

### Phase 1: Core Infrastructure

1. Add Android device discovery to Playwright service
2. Implement Android session management (create/close)
3. Add basic action execution (tap, swipe, fill)
4. Implement screenshot capture
5. Write integration tests for core actions

### Phase 2: Complete Native Support

1. Implement all native actions (pinch, fling, drag, scroll, wait)
2. Add APK installation endpoint
3. Add shell command execution
4. Add file push functionality
5. Comprehensive action test coverage

### Phase 3: WebView & Browser

1. Implement WebView detection and connection
2. Bridge WebView to existing page action handlers
3. Implement browser launch endpoint
4. Integrate browser context with session recording
5. Test hybrid native+web workflows

### Phase 4: Recording & Replay

1. Extend recording format for Android actions
2. Implement session commit with Android format
3. Build replay engine for Android recordings
4. Add replay status tracking
5. Test recording/replay round-trips

### Phase 5: Advanced Features

1. Implement remote WebSocket connection
2. Add observability instrumentation
3. Performance optimization
4. Documentation and examples

---

## Open Questions

1. **Multi-device orchestration:** Should a single session support controlling multiple devices simultaneously for cross-device testing scenarios?

2. **Device provisioning:** Should the system support starting/stopping emulators, or assume they're externally managed?

3. **Physical device support:** While the spec focuses on emulators, Playwright supports physical devices. What additional considerations are needed?

4. **Recording portability:** How should recordings handle device-specific selectors when replaying on different screen sizes or Android versions?

5. **CI/CD integration:** What container/cloud emulator configurations should be documented for CI environments?

---

## References

- [Playwright Android API](https://playwright.dev/docs/api/class-android)
- [Chrome DevTools Recorder Format](https://developer.chrome.com/docs/devtools/recorder/)
- [Android Debug Bridge (ADB)](https://developer.android.com/tools/adb)
- [UIAutomator Selector Specification](https://developer.android.com/reference/androidx/test/uiautomator/UiSelector)

---

**END OF SPECIFICATION**
