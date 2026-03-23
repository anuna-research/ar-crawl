const http = require('http');
const { chromium } = require('playwright-extra');
const { _android } = require('playwright');
const StealthPlugin = require('puppeteer-extra-plugin-stealth');
const crypto = require('crypto');
const { PNG } = require('pngjs');

// Session storage
const sessions = new Map();
const androidSessions = new Map();

// Baseline storage for visual regression
const baselines = new Map();

// Helper for session IDs without external deps
function uuidv4() {
  return crypto.randomUUID();
}

// Add stealth plugin to avoid bot detection
chromium.use(StealthPlugin());

const PORT = process.env.PLAYWRIGHT_SERVICE_PORT || 3033;
const VERBOSE = process.env.VERBOSE === '1' || process.env.VERBOSE === 'true';

let browser = null;

// Logging helper - only logs if verbose mode is enabled
function log(...args) {
  if (VERBOSE) console.log(...args);
}

// Convert session step to Chrome DevTools Recorder format
// Returns null for steps that should not be recorded
// See: https://github.com/niconiahi/replay/blob/main/src/Schema.ts
function toDevToolsFormat(action) {
  // Filter out unsupported/internal step types
  // Chrome DevTools Recorder doesn't support: wait*, screenshot, evaluate
  const unsupportedTypes = ['waitForLoadState', 'waitForTimeout', 'waitForNavigation', 'screenshot', 'evaluate'];
  if (unsupportedTypes.includes(action.type)) {
    return null;
  }

  const step = { type: action.type };

  // Map action types to DevTools Recorder types
  const typeMap = {
    'goto': 'navigate',
    'dblclick': 'doubleClick',
    'fill': 'change',
    'type': 'keyDown'  // keySequence not valid, use keyDown
  };

  if (typeMap[action.type]) {
    step.type = typeMap[action.type];
  }

  // Copy URL for navigation
  if (action.url) {
    step.url = action.url;
  }

  // Convert selector to selectors array (DevTools format)
  // Chrome DevTools Recorder uses: CSS, XPath, aria/, pierce/, xpath/
  // Playwright uses: text=, css=, xpath=, etc.
  if (action.selector) {
    let selector = action.selector;

    // Convert Playwright text= selector to XPath contains() for partial matching
    // Playwright's text= does partial matching, Chrome's aria/ needs exact match
    if (selector.startsWith('text=')) {
      const text = selector.slice(5); // Remove 'text='
      // Escape quotes in text for XPath
      const escapedText = text.replace(/'/g, "\\'");
      selector = `xpath///*[contains(text(), '${escapedText}')]`;
    }

    step.selectors = [[selector]];
  }

  // Click and doubleClick require offsetX and offsetY
  if (step.type === 'click' || step.type === 'doubleClick') {
    step.offsetX = action.offsetX || 1;
    step.offsetY = action.offsetY || 1;
  }

  // Copy value for input/change actions
  if (action.value !== undefined) {
    step.value = action.value;
  }

  // Copy text for type actions
  if (action.text) {
    step.text = action.text;
  }

  // Copy key for keyboard actions
  if (action.key) {
    step.key = action.key;
  }

  // Copy expression for evaluate
  if (action.expression) {
    step.expression = action.expression;
  }

  // For customStep, use standard format with name and parameters
  // Chrome DevTools Recorder displays the title field
  if (action.type === 'customStep') {
    step.name = action.name || 'note';
    // Only include title (from note), not the original note field
    step.parameters = {
      title: (action.parameters && action.parameters.note) || ''
    };
  }

  return step;
}

// Convert Android action to DevTools Recorder format with android/ prefix
function toAndroidDevToolsFormat(action) {
  const step = {
    type: `android/${action.type}`,
    timestamp: action.timestamp || Date.now()
  };

  // Copy selector
  if (action.selector) {
    step.selector = action.selector;
  }

  // Copy direction for swipe/scroll/fling
  if (action.direction) {
    step.direction = action.direction;
  }

  // Copy percent for swipe/scroll/pinch
  if (action.percent !== undefined) {
    step.percent = action.percent;
  }

  // Copy speed for gestures
  if (action.speed !== undefined) {
    step.speed = action.speed;
  }

  // Copy duration for tap
  if (action.duration !== undefined) {
    step.duration = action.duration;
  }

  // Copy text/value for fill
  if (action.text !== undefined) {
    step.text = action.text;
  }
  if (action.value !== undefined) {
    step.value = action.value;
  }

  // Copy URL for browser launch
  if (action.url) {
    step.url = action.url;
  }

  // Copy destination for drag
  if (action.dest) {
    step.dest = action.dest;
  }

  // Copy key for press
  if (action.key) {
    step.key = action.key;
  }

  // Copy command for shell
  if (action.command) {
    step.command = action.command;
  }

  // Copy options if present
  if (action.options) {
    step.options = action.options;
  }

  return step;
}

// Parse Android selector string to Playwright selector object
// Formats: res=id, text=Submit, desc=Menu, class=Button, compound: res=btn&&text=OK
function parseAndroidSelector(selectorStr) {
  if (typeof selectorStr === 'object') {
    return selectorStr; // Already an object
  }

  if (typeof selectorStr !== 'string') {
    throw new Error('Selector must be a string or object');
  }

  // Handle compound selectors (res=btn&&text=OK)
  if (selectorStr.includes('&&')) {
    const parts = selectorStr.split('&&');
    const result = {};
    for (const part of parts) {
      const parsed = parseAndroidSelector(part.trim());
      Object.assign(result, parsed);
    }
    return result;
  }

  // Parse single selector
  const match = selectorStr.match(/^(res|text|desc|class)=(.+)$/);
  if (!match) {
    throw new Error(`Invalid Android selector format: ${selectorStr}. Use res=, text=, desc=, or class=`);
  }

  const [, type, value] = match;
  switch (type) {
    case 'res':
      return { res: value };
    case 'text':
      return { text: value };
    case 'desc':
      return { desc: value };
    case 'class':
      return { clazz: value }; // Playwright uses 'clazz' not 'class'
    default:
      throw new Error(`Unknown selector type: ${type}`);
  }
}

async function initBrowser() {
  if (!browser) {
    browser = await chromium.launch({
      headless: true,
      args: [
        '--no-sandbox',
        '--disable-setuid-sandbox',
        '--disable-blink-features=AutomationControlled',
        '--disable-features=IsolateOrigins,site-per-process'
      ]
    });
    log('Browser initialized with stealth mode');
  }
  return browser;
}

// ============================================================================
// Android Emulator Support
// ============================================================================

// Discover connected Android devices via ADB
async function discoverAndroidDevices(options = {}) {
  const { host, port } = options;

  // Wrap in a promise to catch both thrown errors and emitted errors
  return new Promise(async (resolve, reject) => {
    try {
      // Set a timeout for the connection attempt
      const timeoutId = setTimeout(() => {
        reject(new Error('ADB connection timeout. Run "adb start-server" first.'));
      }, 5000);

      const devices = await _android.devices({
        host: host || undefined,
        port: port || undefined
      });

      clearTimeout(timeoutId);

      const deviceList = await Promise.all(devices.map(async (device) => {
        // Get device info
        const model = device.model();
        const serial = device.serial();

        // Get Android version via shell
        let androidVersion = 'unknown';
        try {
          const versionBuffer = await device.shell('getprop ro.build.version.release');
          androidVersion = versionBuffer.toString().trim();
        } catch (e) {
          log(`Could not get Android version for ${serial}: ${e.message}`);
        }

        return {
          serial,
          model,
          status: 'device',
          androidVersion
        };
      }));

      resolve({ devices: deviceList });
    } catch (error) {
      if (error.message.includes('ECONNREFUSED') || error.message.includes('adb') || error.code === 'ECONNREFUSED') {
        reject(new Error('ADB daemon not accessible. Run "adb start-server" first.'));
      } else {
        reject(error);
      }
    }
  });
}

// Create an Android automation session
async function createAndroidSession(options = {}) {
  const { serial, timeout = 30000, omitDriverInstall = false } = options;

  if (!serial) {
    throw new Error('Device serial required');
  }

  // Find the device
  const devices = await _android.devices();
  const device = devices.find(d => d.serial() === serial);

  if (!device) {
    const available = devices.map(d => d.serial()).join(', ') || 'none';
    throw new Error(`Device not found: ${serial}. Available: ${available}`);
  }

  const sessionId = `android-${uuidv4()}`;
  const model = device.model();

  // Get screen info
  let screen = { width: 0, height: 0 };
  try {
    const info = await device.info();
    screen = { width: info.width || 0, height: info.height || 0 };
  } catch (e) {
    log(`Could not get screen info for ${serial}: ${e.message}`);
  }

  const session = {
    id: sessionId,
    device,
    serial,
    model,
    screen,
    createdAt: Date.now(),
    lastActivity: Date.now(),
    steps: [],
    webViews: new Map(),
    browserContext: null
  };

  androidSessions.set(sessionId, session);
  log(`Android session created: ${sessionId} on ${model} (${serial})`);

  return {
    sessionId,
    device: { serial, model },
    screen,
    createdAt: new Date(session.createdAt).toISOString()
  };
}

// Close an Android session
async function closeAndroidSession(sessionId) {
  const session = androidSessions.get(sessionId);
  if (!session) {
    throw new Error('Android session not found');
  }

  // Close browser context if open
  if (session.browserContext) {
    try {
      await session.browserContext.close();
    } catch (e) {
      log(`Error closing browser context: ${e.message}`);
    }
  }

  // Close WebView connections
  for (const [, webView] of session.webViews) {
    try {
      // WebViews are cleaned up automatically
    } catch (e) {
      log(`Error closing WebView: ${e.message}`);
    }
  }

  // Close device connection
  try {
    await session.device.close();
  } catch (e) {
    log(`Error closing device: ${e.message}`);
  }

  androidSessions.delete(sessionId);
  log(`Android session closed: ${sessionId}`);
}

// Execute an Android action
async function executeAndroidAction(sessionId, action) {
  const session = androidSessions.get(sessionId);
  if (!session) {
    throw new Error('Android session not found');
  }

  session.lastActivity = Date.now();
  const { device } = session;
  const result = { success: true };
  const stepRecord = {
    type: action.type,
    ...action,
    timestamp: Date.now()
  };

  const timeout = action.timeout || action.options?.timeout || 30000;

  try {
    switch (action.type) {
      // ========== Tap Actions ==========
      case 'tap': {
        const selector = parseAndroidSelector(action.selector);
        await device.tap(selector, {
          duration: action.duration || action.options?.duration,
          timeout
        });
        result.action = 'tap';
        break;
      }

      case 'longTap': {
        const selector = parseAndroidSelector(action.selector);
        await device.longTap(selector, { timeout });
        result.action = 'longTap';
        break;
      }

      // ========== Swipe/Scroll Actions ==========
      case 'swipe': {
        const selector = parseAndroidSelector(action.selector);
        const direction = action.direction || 'up';
        const percent = action.percent || 50;
        await device.swipe(selector, direction, percent, {
          speed: action.speed || action.options?.speed,
          timeout
        });
        result.action = 'swipe';
        result.direction = direction;
        break;
      }

      case 'scroll': {
        const direction = action.direction || 'down';
        const percent = action.percent || 50;

        if (action.selector) {
          // Scroll a specific scrollable element
          const selector = parseAndroidSelector(action.selector);
          await device.scroll(selector, direction, percent, {
            speed: action.speed || action.options?.speed,
            timeout
          });
        } else {
          // Selectorless screen scroll via input swipe
          const info = await device.shell('wm size');
          const sizeMatch = info.toString().match(/(\d+)x(\d+)/);
          const screenW = sizeMatch ? parseInt(sizeMatch[1]) : 1080;
          const screenH = sizeMatch ? parseInt(sizeMatch[2]) : 1920;
          const cx = Math.round(screenW / 2);
          const cy = Math.round(screenH / 2);
          const distance = Math.round(Math.min(screenW, screenH) * (percent / 100));
          const duration = action.speed || 300;

          let x1, y1, x2, y2;
          switch (direction) {
            case 'up':
              x1 = cx; y1 = cy; x2 = cx; y2 = cy + distance;
              break;
            case 'down':
              x1 = cx; y1 = cy; x2 = cx; y2 = cy - distance;
              break;
            case 'left':
              x1 = cx; y1 = cy; x2 = cx + distance; y2 = cy;
              break;
            case 'right':
              x1 = cx; y1 = cy; x2 = cx - distance; y2 = cy;
              break;
            default:
              x1 = cx; y1 = cy; x2 = cx; y2 = cy - distance;
          }

          await device.shell(`input swipe ${x1} ${y1} ${x2} ${y2} ${duration}`);
        }

        result.action = 'scroll';
        result.direction = direction;
        break;
      }

      case 'fling': {
        const selector = parseAndroidSelector(action.selector);
        const direction = action.direction || 'down';
        await device.fling(selector, direction, {
          speed: action.speed || action.options?.speed,
          timeout
        });
        result.action = 'fling';
        result.direction = direction;
        break;
      }

      // ========== Pinch Actions ==========
      case 'pinchOpen': {
        const selector = parseAndroidSelector(action.selector);
        const percent = action.percent || 50;
        await device.pinchOpen(selector, percent, {
          speed: action.speed || action.options?.speed,
          timeout
        });
        result.action = 'pinchOpen';
        break;
      }

      case 'pinchClose': {
        const selector = parseAndroidSelector(action.selector);
        const percent = action.percent || 50;
        await device.pinchClose(selector, percent, {
          speed: action.speed || action.options?.speed,
          timeout
        });
        result.action = 'pinchClose';
        break;
      }

      // ========== Drag Action ==========
      case 'drag': {
        const selector = parseAndroidSelector(action.selector);
        const dest = action.dest || { x: 0, y: 0 };
        await device.drag(selector, dest, {
          speed: action.speed || action.options?.speed,
          timeout
        });
        result.action = 'drag';
        result.dest = dest;
        break;
      }

      // ========== Text Input Actions ==========
      case 'fill': {
        const selector = parseAndroidSelector(action.selector);
        const text = action.text || action.value || '';
        await device.fill(selector, text, { timeout });
        result.action = 'fill';
        result.text = text;
        break;
      }

      case 'type': {
        // Type text character by character to focused element
        const text = action.text || action.value || '';
        for (const char of text) {
          await device.press(char);
        }
        result.action = 'type';
        result.text = text;
        break;
      }

      case 'press': {
        // Press a specific key
        const key = action.key;
        if (!key) {
          throw new Error('Key is required for press action');
        }
        await device.press(key);
        result.action = 'press';
        result.key = key;
        break;
      }

      // ========== Wait Action ==========
      case 'wait': {
        const selector = parseAndroidSelector(action.selector);
        const state = action.state || action.options?.state || 'visible';
        await device.wait(selector, {
          state, // 'visible' or 'gone'
          timeout
        });
        result.action = 'wait';
        result.state = state;
        break;
      }

      // ========== Screenshot ==========
      case 'screenshot': {
        const buffer = await device.screenshot({
          path: action.path || action.options?.path
        });
        result.action = 'screenshot';
        result.size = buffer.length;
        if (!action.path && !action.options?.path) {
          result.buffer = buffer.toString('base64');
        }
        break;
      }

      case 'elementScreenshot': {
        const selector = action.selector ? parseAndroidSelector(action.selector) : null;
        if (!selector) {
          throw new Error('Selector is required for elementScreenshot action');
        }

        log('Android elementScreenshot: capturing element with selector', action.selector);

        // Get element bounds
        const info = await device.info(selector);
        if (!info) {
          throw new Error('Could not find element with selector: ' + action.selector);
        }

        // Parse bounds format: [left,top][right,bottom]
        const boundsMatch = JSON.stringify(info).match(/bounds.*?\[(\d+),(\d+)\]\[(\d+),(\d+)\]/);
        let bounds;

        if (boundsMatch) {
          bounds = {
            left: parseInt(boundsMatch[1]),
            top: parseInt(boundsMatch[2]),
            right: parseInt(boundsMatch[3]),
            bottom: parseInt(boundsMatch[4])
          };
        } else if (info.visibleBounds) {
          bounds = info.visibleBounds;
        } else {
          throw new Error('Could not parse element bounds');
        }

        log('Android elementScreenshot: element bounds', bounds);

        // Take full screenshot
        const fullBuffer = await device.screenshot();

        // Crop to element bounds using sharp or jimp
        // For simplicity, store bounds info and let client crop
        // Or use screencap with coordinates if available

        result.action = 'elementScreenshot';
        result.selector = action.selector;
        result.bounds = bounds;
        result.width = bounds.right - bounds.left;
        result.height = bounds.bottom - bounds.top;
        result.screenshot = fullBuffer.toString('base64');
        result.fullSize = fullBuffer.length;

        // Optionally store as baseline
        if (action.asBaseline) {
          const baselineName = action.baselineName || `element-${Date.now()}`;
          const baseline = {
            name: baselineName,
            timestamp: Date.now(),
            session: sessionId,
            device: {
              serial: session.serial,
              model: session.model,
              screen: session.screen
            },
            screenshot: fullBuffer.toString('base64'),
            size: fullBuffer.length,
            selector: action.selector,
            bounds,
            metadata: action.metadata || {}
          };
          baselines.set(baselineName, baseline);
          result.baselineName = baselineName;
          log('Android elementScreenshot: stored baseline', baselineName);
        }

        // Save to file if path provided
        if (action.path) {
          const fs = require('fs');
          fs.writeFileSync(action.path, fullBuffer);
          result.path = action.path;
          log('Android elementScreenshot: saved to', action.path);
        }

        break;
      }

      // ========== Device Info ==========
      case 'info': {
        const selector = action.selector ? parseAndroidSelector(action.selector) : null;
        if (selector) {
          const info = await device.info(selector);
          result.widgetInfo = info;
        } else {
          // Get general device info
          const info = await device.info();
          result.deviceInfo = info;
        }
        result.action = 'info';
        break;
      }

      // ========== Shell Command ==========
      case 'shell': {
        const command = action.command;
        if (!command) {
          throw new Error('Command is required for shell action');
        }
        const output = await device.shell(command);
        result.action = 'shell';
        result.output = output.toString();
        break;
      }

      // ========== File Operations ==========
      case 'push': {
        const file = action.file;
        const path = action.path;
        if (!file || !path) {
          throw new Error('Both file and path are required for push action');
        }
        await device.push(file, path, {
          mode: action.mode || action.options?.mode
        });
        result.action = 'push';
        result.path = path;
        break;
      }

      case 'install': {
        const apk = action.apk;
        if (!apk) {
          throw new Error('APK path is required for install action');
        }

        // Get package name from APK before install (using aapt if available, otherwise install first)
        let packageName = action.pkg; // Allow pre-specifying package name

        // Install the APK
        await device.installApk(apk, {
          args: action.args || action.options?.args
        });

        result.action = 'install';
        result.apk = apk;
        result.success = true;

        // If package name provided, verify installation and get info
        if (packageName || action.verify !== false) {
          try {
            // Try to detect package name from recent install
            if (!packageName) {
              // Get recently modified packages
              const listOutput = await device.shell('pm list packages -f | tail -5');
              const lines = listOutput.toString().trim().split('\n');
              // The APK filename might give us a hint
              const apkBasename = apk.split('/').pop().replace('.apk', '').toLowerCase();
              for (const line of lines) {
                const match = line.match(/package:(.+)=(.+)/);
                if (match && match[1].toLowerCase().includes(apkBasename)) {
                  packageName = match[2];
                  break;
                }
              }
            }

            if (packageName) {
              // Verify package is installed
              const verifyOutput = await device.shell(`pm list packages | grep ${packageName}`);
              result.verified = verifyOutput.toString().includes(packageName);
              result.pkg = packageName;

              // Get package info
              const infoOutput = await device.shell(`dumpsys package ${packageName} | head -30`);
              const versionMatch = infoOutput.toString().match(/versionName=([^\s]+)/);
              const versionCodeMatch = infoOutput.toString().match(/versionCode=(\d+)/);

              result.packageInfo = {
                name: packageName,
                versionName: versionMatch ? versionMatch[1] : null,
                versionCode: versionCodeMatch ? parseInt(versionCodeMatch[1]) : null
              };
            }
          } catch (verifyError) {
            result.verifyError = verifyError.message;
          }
        }

        break;
      }

      case 'uninstall': {
        const pkg = action.pkg || action.package;
        if (!pkg) {
          throw new Error('Package name (pkg) is required for uninstall action');
        }

        // Check if package exists first
        const checkOutput = await device.shell(`pm list packages | grep "^package:${pkg}$"`);
        if (!checkOutput.toString().includes(pkg)) {
          result.action = 'uninstall';
          result.pkg = pkg;
          result.existed = false;
          result.success = true; // Not an error if not installed
          break;
        }

        // Uninstall the package
        const uninstallOutput = await device.shell(`pm uninstall ${action.keepData ? '-k' : ''} ${pkg}`);
        const outputStr = uninstallOutput.toString().trim();

        result.action = 'uninstall';
        result.pkg = pkg;
        result.existed = true;
        result.output = outputStr;
        result.success = outputStr.includes('Success');

        if (!result.success) {
          throw new Error(`Uninstall failed: ${outputStr}`);
        }

        break;
      }

      case 'clearData': {
        const pkg = action.pkg || action.package;
        if (!pkg) {
          throw new Error('Package name (pkg) is required for clearData action');
        }

        // Check if package exists
        const checkOutput = await device.shell(`pm list packages | grep "^package:${pkg}$"`);
        if (!checkOutput.toString().includes(pkg)) {
          throw new Error(`Package not found: ${pkg}`);
        }

        // Clear app data
        const clearOutput = await device.shell(`pm clear ${pkg}`);
        const outputStr = clearOutput.toString().trim();

        result.action = 'clearData';
        result.pkg = pkg;
        result.output = outputStr;
        result.success = outputStr.includes('Success');

        if (!result.success) {
          throw new Error(`Clear data failed: ${outputStr}`);
        }

        break;
      }

      case 'forceStop': {
        const pkg = action.pkg || action.package;
        if (!pkg) {
          throw new Error('Package name (pkg) is required for forceStop action');
        }

        // Force stop the app
        const stopOutput = await device.shell(`am force-stop ${pkg}`);

        result.action = 'forceStop';
        result.pkg = pkg;
        result.success = true;
        break;
      }

      // ========== WebView Actions ==========
      case 'listWebViews': {
        const webViews = await device.webViews();
        result.webViews = webViews.map(wv => ({
          pkg: wv.pkg(),
          pid: wv.pid()
        }));
        result.action = 'listWebViews';
        break;
      }

      case 'connectWebView': {
        const selector = action.selector || {};
        const webView = await device.webView(selector);
        const page = await webView.page();

        const webViewId = `wv-${uuidv4()}`;
        session.webViews.set(webViewId, { webView, page });

        result.webViewId = webViewId;
        result.pkg = webView.pkg();
        result.pid = webView.pid();
        result.url = page.url();
        result.action = 'connectWebView';
        break;
      }

      case 'disconnectWebView': {
        const webViewId = action.webViewId;
        if (!webViewId || !session.webViews.has(webViewId)) {
          throw new Error('Invalid WebView ID');
        }
        session.webViews.delete(webViewId);
        result.action = 'disconnectWebView';
        break;
      }

      // ========== Browser Launch ==========
      case 'launchBrowser': {
        const url = action.url;
        const browserContext = await device.launchBrowser({
          pkg: action.pkg || 'com.android.chrome',
          ...action.options
        });

        session.browserContext = browserContext;
        const pages = browserContext.pages();
        const page = pages[0] || await browserContext.newPage();

        if (url) {
          await page.goto(url, {
            waitUntil: action.waitUntil || 'networkidle',
            timeout
          });
        }

        result.action = 'launchBrowser';
        result.url = page.url();
        result.title = await page.title();
        break;
      }

      // ========== App Launch ==========
      case 'launchApp': {
        const pkg = action.pkg || action.package;
        if (!pkg) {
          throw new Error('Package name (pkg) is required for launchApp action');
        }
        // Launch app using shell am start
        const activity = action.activity;
        let command;
        if (activity) {
          command = `am start -n ${pkg}/${activity}`;
        } else {
          // Use monkey to launch the main activity
          command = `monkey -p ${pkg} -c android.intent.category.LAUNCHER 1`;
        }
        const output = await device.shell(command);
        result.action = 'launchApp';
        result.pkg = pkg;
        result.output = output.toString();
        // Wait a moment for app to launch
        await new Promise(r => setTimeout(r, action.delay || 1000));
        break;
      }

      // ========== List Packages ==========
      case 'listPackages': {
        // Get list of installed packages
        const filter = action.filter || '';
        const includeSystem = action.includeSystem || false;

        let command = 'pm list packages';
        if (!includeSystem) {
          command += ' -3'; // Third-party apps only
        }
        if (filter) {
          command += ` | grep -i "${filter}"`;
        }

        const listOutput = await device.shell(command);
        const lines = listOutput.toString().trim().split('\n').filter(l => l.startsWith('package:'));

        const packages = [];
        for (const line of lines.slice(0, action.limit || 100)) {
          const pkgName = line.replace('package:', '').trim();
          if (!pkgName) continue;

          const pkg = { name: pkgName };

          // Get version info if requested
          if (action.includeVersions !== false) {
            try {
              const infoOutput = await device.shell(`dumpsys package ${pkgName} | grep -E "versionName|versionCode" | head -2`);
              const infoStr = infoOutput.toString();
              const versionMatch = infoStr.match(/versionName=([^\s]+)/);
              const codeMatch = infoStr.match(/versionCode=(\d+)/);
              if (versionMatch) pkg.versionName = versionMatch[1];
              if (codeMatch) pkg.versionCode = parseInt(codeMatch[1]);
            } catch (e) {
              // Skip version info on error
            }
          }

          packages.push(pkg);
        }

        result.action = 'listPackages';
        result.packages = packages;
        result.count = packages.length;
        break;
      }

      // ========== App State ==========
      case 'appState': {
        // Get current foreground app info
        const activityOutput = await device.shell('dumpsys activity activities | grep mResumedActivity');
        const match = activityOutput.toString().match(/u0 ([^\s]+)/);
        result.currentActivity = match ? match[1] : null;

        // Get device info
        const info = await device.info();
        result.deviceInfo = info;

        result.action = 'appState';
        break;
      }

      // ========== Assert Action ==========
      case 'assert': {
        const selector = action.selector ? parseAndroidSelector(action.selector) : null;
        if (!selector) {
          throw new Error('Selector is required for assert action');
        }

        const assertions = action.assertions || {};
        const results = { passed: true, checks: [] };

        try {
          // Get element info
          const info = await device.info(selector);

          // Check existence - if we got here, element exists
          if (assertions.exists !== undefined) {
            const check = {
              type: 'exists',
              expected: assertions.exists,
              actual: true,
              passed: assertions.exists === true
            };
            results.checks.push(check);
            if (!check.passed) results.passed = false;
          }

          // Check visibility
          if (assertions.visible !== undefined) {
            const actual = info.visible !== false; // Default true if not specified
            const check = {
              type: 'visible',
              expected: assertions.visible,
              actual,
              passed: assertions.visible === actual
            };
            results.checks.push(check);
            if (!check.passed) results.passed = false;
          }

          // Check enabled
          if (assertions.enabled !== undefined) {
            const actual = info.enabled !== false;
            const check = {
              type: 'enabled',
              expected: assertions.enabled,
              actual,
              passed: assertions.enabled === actual
            };
            results.checks.push(check);
            if (!check.passed) results.passed = false;
          }

          // Check text content
          if (assertions.text !== undefined) {
            const actual = info.text || '';
            const check = {
              type: 'text',
              expected: assertions.text,
              actual,
              passed: assertions.text === actual
            };
            results.checks.push(check);
            if (!check.passed) results.passed = false;
          }

          // Check text contains
          if (assertions.textContains !== undefined) {
            const actual = info.text || '';
            const check = {
              type: 'textContains',
              expected: assertions.textContains,
              actual,
              passed: actual.includes(assertions.textContains)
            };
            results.checks.push(check);
            if (!check.passed) results.passed = false;
          }

          // Check text matches regex
          if (assertions.textMatches !== undefined) {
            const actual = info.text || '';
            const regex = new RegExp(assertions.textMatches);
            const check = {
              type: 'textMatches',
              expected: assertions.textMatches,
              actual,
              passed: regex.test(actual)
            };
            results.checks.push(check);
            if (!check.passed) results.passed = false;
          }

          // Check content description
          if (assertions.contentDesc !== undefined) {
            const actual = info.desc || '';
            const check = {
              type: 'contentDesc',
              expected: assertions.contentDesc,
              actual,
              passed: assertions.contentDesc === actual
            };
            results.checks.push(check);
            if (!check.passed) results.passed = false;
          }

          // Check class name
          if (assertions.className !== undefined) {
            const actual = info.clazz || '';
            const check = {
              type: 'className',
              expected: assertions.className,
              actual,
              passed: actual.includes(assertions.className)
            };
            results.checks.push(check);
            if (!check.passed) results.passed = false;
          }

        } catch (error) {
          // Element not found
          if (assertions.exists === false) {
            results.checks.push({
              type: 'exists',
              expected: false,
              actual: false,
              passed: true
            });
          } else {
            results.passed = false;
            results.error = error.message;
            results.checks.push({
              type: 'exists',
              expected: true,
              actual: false,
              passed: false
            });
          }
        }

        result.action = 'assert';
        result.selector = action.selector;
        result.assertions = results;
        result.success = results.passed;

        // Throw if assertions failed and strict mode
        if (!results.passed && action.strict !== false) {
          throw new Error(`Assertion failed: ${JSON.stringify(results.checks.filter(c => !c.passed))}`);
        }

        break;
      }

      // ========== Visual Regression Baselines ==========
      case 'captureBaseline': {
        const name = action.name || `baseline-${Date.now()}`;

        // Capture screenshot
        const buffer = await device.screenshot();

        // Store baseline with metadata
        const baseline = {
          name,
          timestamp: Date.now(),
          session: sessionId,
          device: {
            serial: session.serial,
            model: session.model,
            screen: session.screen
          },
          screenshot: buffer.toString('base64'),
          size: buffer.length,
          selector: action.selector || null,
          metadata: action.metadata || {}
        };

        baselines.set(name, baseline);

        result.action = 'captureBaseline';
        result.name = name;
        result.size = buffer.length;
        result.timestamp = baseline.timestamp;

        // Optionally save to file
        if (action.path) {
          const fs = require('fs');
          fs.writeFileSync(action.path, buffer);
          result.path = action.path;
        }

        break;
      }

      case 'getBaseline': {
        const name = action.name;
        if (!name) {
          throw new Error('Baseline name is required');
        }

        const baseline = baselines.get(name);
        if (!baseline) {
          throw new Error(`Baseline not found: ${name}`);
        }

        result.action = 'getBaseline';
        result.baseline = {
          name: baseline.name,
          timestamp: baseline.timestamp,
          size: baseline.size,
          device: baseline.device,
          metadata: baseline.metadata
        };

        // Include image data if requested
        if (action.includeImage) {
          result.baseline.screenshot = baseline.screenshot;
        }

        break;
      }

      case 'listBaselines': {
        const list = [];
        for (const [name, baseline] of baselines) {
          list.push({
            name,
            timestamp: baseline.timestamp,
            size: baseline.size,
            device: baseline.device,
            metadata: baseline.metadata
          });
        }

        result.action = 'listBaselines';
        result.baselines = list;
        result.count = list.length;
        break;
      }

      case 'deleteBaseline': {
        const name = action.name;
        if (!name) {
          throw new Error('Baseline name is required');
        }

        const deleted = baselines.delete(name);
        result.action = 'deleteBaseline';
        result.name = name;
        result.deleted = deleted;
        break;
      }

      // ========== Enhanced Wait Conditions ==========
      case 'waitFor': {
        const startTime = Date.now();
        const waitTimeout = action.timeout || 30000;
        const interval = action.interval || 500;
        let lastError = null;

        while (Date.now() - startTime < waitTimeout) {
          try {
            // Wait for element
            if (action.selector) {
              const selector = parseAndroidSelector(action.selector);
              await device.wait(selector, {
                state: action.state || 'visible',
                timeout: Math.min(interval * 2, waitTimeout - (Date.now() - startTime))
              });
              result.action = 'waitFor';
              result.condition = 'element';
              result.selector = action.selector;
              result.elapsed = Date.now() - startTime;
              break;
            }

            // Wait for text on screen
            if (action.text) {
              // Use UI dump to find text
              const uiDump = await device.shell('uiautomator dump /dev/tty');
              const uiStr = uiDump.toString();
              if (uiStr.includes(action.text)) {
                result.action = 'waitFor';
                result.condition = 'text';
                result.text = action.text;
                result.elapsed = Date.now() - startTime;
                break;
              }
              throw new Error('Text not found');
            }

            // Wait for specific activity
            if (action.activity) {
              const activityOutput = await device.shell('dumpsys activity activities | grep mResumedActivity');
              const actStr = activityOutput.toString();
              if (actStr.includes(action.activity)) {
                result.action = 'waitFor';
                result.condition = 'activity';
                result.activity = action.activity;
                result.elapsed = Date.now() - startTime;
                break;
              }
              throw new Error('Activity not found');
            }

            // Wait for package to be in foreground
            if (action.pkg) {
              const activityOutput = await device.shell('dumpsys activity activities | grep mResumedActivity');
              const actStr = activityOutput.toString();
              if (actStr.includes(action.pkg)) {
                result.action = 'waitFor';
                result.condition = 'package';
                result.pkg = action.pkg;
                result.elapsed = Date.now() - startTime;
                break;
              }
              throw new Error('Package not in foreground');
            }

            // Wait for text to disappear
            if (action.textGone) {
              const uiDump = await device.shell('uiautomator dump /dev/tty');
              const uiStr = uiDump.toString();
              if (!uiStr.includes(action.textGone)) {
                result.action = 'waitFor';
                result.condition = 'textGone';
                result.textGone = action.textGone;
                result.elapsed = Date.now() - startTime;
                break;
              }
              throw new Error('Text still present');
            }

          } catch (error) {
            lastError = error;
          }

          // Wait before retry
          await new Promise(r => setTimeout(r, interval));
        }

        // Check if we timed out
        if (!result.condition) {
          result.action = 'waitFor';
          result.success = false;
          result.timedOut = true;
          result.elapsed = Date.now() - startTime;
          result.error = lastError?.message || 'Condition not met';
          throw new Error(`Wait timed out after ${waitTimeout}ms: ${lastError?.message || 'condition not met'}`);
        }

        break;
      }

      case 'waitForIdle': {
        // Wait for device to be idle (no animations, UI settled)
        const idleTimeout = action.timeout || 10000;

        // Use wait-for-device-idle if available, or just wait
        try {
          await device.shell(`timeout ${Math.floor(idleTimeout/1000)} wait-for-device-idle`);
        } catch (e) {
          // Fallback: just wait a bit
          await new Promise(r => setTimeout(r, action.delay || 2000));
        }

        result.action = 'waitForIdle';
        result.success = true;
        break;
      }

      // ========== Crash Detection ==========
      case 'checkCrash': {
        const pkg = action.pkg || action.package;
        const since = action.since || 'boot';

        const crashInfo = {
          hasCrash: false,
          hasANR: false,
          crashes: [],
          anrs: []
        };

        // Check for crashes in logcat
        try {
          const crashOutput = await device.shell(`logcat -d -v time *:E | grep -iE "(FATAL|crash|exception|error)" | tail -50`);
          const crashLines = crashOutput.toString().trim().split('\n').filter(l => l.length > 0);

          for (const line of crashLines) {
            if (pkg && !line.includes(pkg)) continue;

            crashInfo.crashes.push({
              line,
              timestamp: line.substring(0, 18).trim()
            });
          }

          crashInfo.hasCrash = crashInfo.crashes.length > 0;
        } catch (e) {
          crashInfo.crashCheckError = e.message;
        }

        // Check for ANRs
        try {
          const anrOutput = await device.shell(`logcat -d -v time | grep -i "ANR in" | tail -10`);
          const anrLines = anrOutput.toString().trim().split('\n').filter(l => l.length > 0);

          for (const line of anrLines) {
            if (pkg && !line.includes(pkg)) continue;

            crashInfo.anrs.push({
              line,
              timestamp: line.substring(0, 18).trim()
            });
          }

          crashInfo.hasANR = crashInfo.anrs.length > 0;
        } catch (e) {
          crashInfo.anrCheckError = e.message;
        }

        // Check if app is still running
        if (pkg) {
          try {
            const pidOutput = await device.shell(`pidof ${pkg}`);
            crashInfo.appRunning = pidOutput.toString().trim().length > 0;
          } catch (e) {
            crashInfo.appRunning = false;
          }
        }

        result.action = 'checkCrash';
        result.pkg = pkg;
        result.crashInfo = crashInfo;
        result.success = !crashInfo.hasCrash && !crashInfo.hasANR;
        break;
      }

      case 'getLogcat': {
        const pkg = action.pkg;
        const lines = action.lines || 100;
        const level = action.level || 'V'; // V, D, I, W, E
        const filter = action.filter || '';

        let command = `logcat -d -v threadtime`;

        // Add level filter
        if (level !== 'V') {
          command += ` *:${level}`;
        }

        // Add line limit
        command += ` | tail -${lines}`;

        // Add grep filter for package or custom filter
        if (pkg) {
          command += ` | grep -i "${pkg}"`;
        } else if (filter) {
          command += ` | grep -i "${filter}"`;
        }

        const logOutput = await device.shell(command);

        result.action = 'getLogcat';
        result.lines = logOutput.toString().trim().split('\n');
        result.count = result.lines.length;
        break;
      }

      case 'clearLogcat': {
        await device.shell('logcat -c');
        result.action = 'clearLogcat';
        result.success = true;
        break;
      }

      case 'watchCrash': {
        // Check for crash and capture detailed info
        const pkg = action.pkg;

        const info = {
          hasCrash: false,
          stack: null
        };

        // Get tombstones (native crashes)
        try {
          const tombOutput = await device.shell('ls -lt /data/tombstones/ 2>/dev/null | head -5');
          info.tombstones = tombOutput.toString().trim();
        } catch (e) {
          // No tombstones access
        }

        // Get dropbox entries (app crashes/ANRs)
        try {
          const dropboxOutput = await device.shell('dumpsys dropbox --print 2>/dev/null | tail -100');
          const dropStr = dropboxOutput.toString();

          if (pkg && dropStr.includes(pkg)) {
            info.hasCrash = true;
            info.dropboxEntry = dropStr;
          } else if (dropStr.includes('crash') || dropStr.includes('ANR')) {
            info.hasCrash = true;
            info.dropboxEntry = dropStr;
          }
        } catch (e) {
          // No dropbox access
        }

        result.action = 'watchCrash';
        result.crashInfo = info;
        break;
      }

      // ========== Performance Metrics ==========
      case 'perfMetrics': {
        const pkg = action.pkg || action.package;

        const metrics = {
          timestamp: Date.now()
        };

        // Get memory info
        try {
          if (pkg) {
            const memOutput = await device.shell(`dumpsys meminfo ${pkg} | head -20`);
            const memStr = memOutput.toString();

            // Parse total PSS
            const pssMatch = memStr.match(/TOTAL\s+(\d+)/);
            if (pssMatch) {
              metrics.memoryPSS = parseInt(pssMatch[1]); // KB
            }

            // Parse native heap
            const nativeMatch = memStr.match(/Native Heap\s+(\d+)/);
            if (nativeMatch) {
              metrics.nativeHeap = parseInt(nativeMatch[1]); // KB
            }

            // Parse Java heap
            const javaMatch = memStr.match(/Java Heap\s+(\d+)/);
            if (javaMatch) {
              metrics.javaHeap = parseInt(javaMatch[1]); // KB
            }
          }
        } catch (e) {
          metrics.memoryError = e.message;
        }

        // Get CPU info
        try {
          if (pkg) {
            const cpuOutput = await device.shell(`top -n 1 | grep ${pkg}`);
            const cpuStr = cpuOutput.toString();
            const cpuMatch = cpuStr.match(/(\d+(?:\.\d+)?)\s*%/);
            if (cpuMatch) {
              metrics.cpuPercent = parseFloat(cpuMatch[1]);
            }
          }
        } catch (e) {
          metrics.cpuError = e.message;
        }

        // Get battery info
        try {
          const batteryOutput = await device.shell('dumpsys battery | grep -E "level|temperature|status"');
          const batteryStr = batteryOutput.toString();

          const levelMatch = batteryStr.match(/level:\s*(\d+)/);
          if (levelMatch) metrics.batteryLevel = parseInt(levelMatch[1]);

          const tempMatch = batteryStr.match(/temperature:\s*(\d+)/);
          if (tempMatch) metrics.batteryTemp = parseInt(tempMatch[1]) / 10; // Convert to Celsius
        } catch (e) {
          metrics.batteryError = e.message;
        }

        // Get frame stats if available
        try {
          if (pkg) {
            const gfxOutput = await device.shell(`dumpsys gfxinfo ${pkg} | grep -A5 "Total frames"`);
            const gfxStr = gfxOutput.toString();

            const framesMatch = gfxStr.match(/Total frames rendered:\s*(\d+)/);
            if (framesMatch) metrics.totalFrames = parseInt(framesMatch[1]);

            const jankMatch = gfxStr.match(/Janky frames:\s*(\d+)/);
            if (jankMatch) metrics.jankyFrames = parseInt(jankMatch[1]);
          }
        } catch (e) {
          metrics.gfxError = e.message;
        }

        result.action = 'perfMetrics';
        result.metrics = metrics;
        result.pkg = pkg;
        break;
      }

      case 'measureLaunchTime': {
        const pkg = action.pkg || action.package;
        if (!pkg) {
          throw new Error('Package name (pkg) is required');
        }

        const activity = action.activity || '';

        // Force stop first
        await device.shell(`am force-stop ${pkg}`);
        await new Promise(r => setTimeout(r, 500));

        // Launch with timing
        let command;
        if (activity) {
          command = `am start -W -n ${pkg}/${activity}`;
        } else {
          command = `am start -W $(pm dump ${pkg} | grep -A1 "android.intent.action.MAIN" | grep -o "\\S*/\\S*" | head -1)`;
        }

        const startTime = Date.now();
        const launchOutput = await device.shell(command);
        const launchStr = launchOutput.toString();

        // Parse timing from am output
        const timing = {
          wallTime: Date.now() - startTime
        };

        // Parse ThisTime (time to display)
        const thisTimeMatch = launchStr.match(/ThisTime:\s*(\d+)/);
        if (thisTimeMatch) timing.thisTime = parseInt(thisTimeMatch[1]);

        // Parse TotalTime (total time including app init)
        const totalTimeMatch = launchStr.match(/TotalTime:\s*(\d+)/);
        if (totalTimeMatch) timing.totalTime = parseInt(totalTimeMatch[1]);

        // Parse WaitTime
        const waitTimeMatch = launchStr.match(/WaitTime:\s*(\d+)/);
        if (waitTimeMatch) timing.waitTime = parseInt(waitTimeMatch[1]);

        result.action = 'measureLaunchTime';
        result.pkg = pkg;
        result.timing = timing;
        result.output = launchStr;
        break;
      }

      // ========== Test Script Execution ==========
      case 'runTest': {
        const steps = action.steps || [];
        if (!steps.length) {
          throw new Error('Test steps are required');
        }

        const testResult = {
          name: action.name || 'Unnamed Test',
          startTime: Date.now(),
          steps: [],
          passed: true,
          failedStep: null
        };

        for (let i = 0; i < steps.length; i++) {
          const step = steps[i];
          const stepResult = {
            index: i,
            type: step.type,
            startTime: Date.now()
          };

          try {
            // Execute the step action recursively
            const actionResult = await executeAndroidAction(sessionId, {
              ...step,
              // Don't throw on assert failures during test
              strict: step.type === 'assert' ? false : step.strict
            });

            stepResult.result = actionResult;
            stepResult.success = actionResult.success !== false;
            stepResult.duration = Date.now() - stepResult.startTime;

            // For assertions, check the assertions result
            if (step.type === 'assert' && actionResult.assertions) {
              stepResult.success = actionResult.assertions.passed;
            }

            // If step failed and stopOnFailure is true (default), stop
            if (!stepResult.success) {
              testResult.passed = false;
              testResult.failedStep = i;
              testResult.failureReason = actionResult.error || 'Step failed';
              testResult.steps.push(stepResult);

              if (action.stopOnFailure !== false) {
                break;
              }
            }

          } catch (error) {
            stepResult.success = false;
            stepResult.error = error.message;
            stepResult.duration = Date.now() - stepResult.startTime;

            testResult.passed = false;
            testResult.failedStep = i;
            testResult.failureReason = error.message;
            testResult.steps.push(stepResult);

            if (action.stopOnFailure !== false) {
              break;
            }
          }

          testResult.steps.push(stepResult);

          // Optional delay between steps
          if (step.delay || action.stepDelay) {
            await new Promise(r => setTimeout(r, step.delay || action.stepDelay));
          }
        }

        testResult.endTime = Date.now();
        testResult.duration = testResult.endTime - testResult.startTime;
        testResult.stepsExecuted = testResult.steps.length;
        testResult.stepsPassed = testResult.steps.filter(s => s.success).length;

        result.action = 'runTest';
        result.test = testResult;
        result.success = testResult.passed;

        break;
      }

      // ========== Screenshot Comparison ==========
      case 'compareScreenshot': {
        const baselineName = action.baseline || action.baselineName;
        const inlineBaseline = action.baselineData; // Accept inline base64 data

        if (!baselineName && !inlineBaseline) {
          throw new Error('Baseline name or data is required for comparison');
        }

        // Try to get baseline from session storage, or use inline data
        let baseline = baselines.get(baselineName);
        let baselineBuffer;
        let baselineSize;

        if (baseline) {
          // Use stored baseline
          baselineBuffer = Buffer.from(baseline.screenshot, 'base64');
          baselineSize = baseline.size;
        } else if (inlineBaseline) {
          // Use inline base64 data directly
          baselineBuffer = Buffer.from(inlineBaseline, 'base64');
          baselineSize = baselineBuffer.length;
        } else {
          throw new Error(`Baseline not found: ${baselineName}`);
        }

        // Capture current screenshot
        const currentBuffer = await device.screenshot();
        const currentBase64 = currentBuffer.toString('base64');

        // Compare screenshots pixel by pixel
        // Since we don't have image processing libs, do a simple comparison
        const comparison = {
          baselineName: baselineName || 'inline',
          baselineSize: baselineSize,
          currentSize: currentBuffer.length,
          timestamp: Date.now()
        };

        // Decode PNGs and compare pixels
        let baselinePng, currentPng;
        try {
          baselinePng = PNG.sync.read(baselineBuffer);
          currentPng = PNG.sync.read(currentBuffer);
        } catch (e) {
          // Fall back to byte comparison if PNG decode fails
          log('PNG decode failed, falling back to byte comparison:', e.message);
          const minLength = Math.min(baselineBuffer.length, currentBuffer.length);
          let diffBytes = 0;
          for (let i = 0; i < minLength; i++) {
            if (baselineBuffer[i] !== currentBuffer[i]) diffBytes++;
          }
          diffBytes += Math.abs(baselineBuffer.length - currentBuffer.length);
          comparison.identical = diffBytes === 0;
          comparison.diffBytes = diffBytes;
          comparison.diffPercent = (diffBytes / Math.max(baselineBuffer.length, currentBuffer.length)) * 100;
          comparison.method = 'byte';
        }

        if (baselinePng && currentPng) {
          // Pixel-level comparison
          comparison.method = 'pixel';
          comparison.baselineWidth = baselinePng.width;
          comparison.baselineHeight = baselinePng.height;
          comparison.currentWidth = currentPng.width;
          comparison.currentHeight = currentPng.height;

          if (baselinePng.width !== currentPng.width || baselinePng.height !== currentPng.height) {
            // Different dimensions = fail
            comparison.identical = false;
            comparison.diffPercent = 100;
            comparison.dimensionMismatch = true;
          } else {
            // Compare pixels (RGBA = 4 bytes per pixel)
            const totalPixels = baselinePng.width * baselinePng.height;
            let diffPixels = 0;

            for (let i = 0; i < baselinePng.data.length; i += 4) {
              // Compare R, G, B (ignore alpha for minor rendering diffs)
              const dr = Math.abs(baselinePng.data[i] - currentPng.data[i]);
              const dg = Math.abs(baselinePng.data[i + 1] - currentPng.data[i + 1]);
              const db = Math.abs(baselinePng.data[i + 2] - currentPng.data[i + 2]);

              // Allow small per-channel tolerance for anti-aliasing
              if (dr > 2 || dg > 2 || db > 2) {
                diffPixels++;
              }
            }

            comparison.identical = diffPixels === 0;
            comparison.diffPixels = diffPixels;
            comparison.totalPixels = totalPixels;
            comparison.diffPercent = (diffPixels / totalPixels) * 100;
          }
        }

        // Apply threshold
        const threshold = action.threshold || 0; // Default: exact match
        comparison.passed = comparison.diffPercent <= threshold;
        comparison.threshold = threshold;

        // Include screenshots if requested
        if (action.includeScreenshots) {
          comparison.baseline = baseline ? baseline.screenshot : inlineBaseline;
          comparison.current = currentBase64;
        }

        // Store comparison result
        if (action.saveName) {
          const comparisonRecord = {
            name: action.saveName,
            timestamp: Date.now(),
            baseline: baselineName,
            ...comparison
          };
          // Store in session for later retrieval
          if (!session.comparisons) session.comparisons = new Map();
          session.comparisons.set(action.saveName, comparisonRecord);
        }

        result.action = 'compareScreenshot';
        result.comparison = comparison;
        result.success = comparison.passed;

        log('Android compareScreenshot:', baselineName, '- diff:', comparison.diffPercent.toFixed(2) + '%', '- passed:', comparison.passed);
        break;
      }

      case 'compareElement': {
        // Compare a specific element against baseline
        const baselineName = action.baseline || action.baselineName;
        const selector = action.selector ? parseAndroidSelector(action.selector) : null;

        if (!baselineName) {
          throw new Error('Baseline name is required');
        }
        if (!selector) {
          throw new Error('Selector is required for element comparison');
        }

        const baseline = baselines.get(baselineName);
        if (!baseline) {
          throw new Error(`Baseline not found: ${baselineName}`);
        }

        // Get current element bounds and screenshot
        const info = await device.info(selector);
        const currentBuffer = await device.screenshot();

        const comparison = {
          baselineName,
          selector: action.selector,
          timestamp: Date.now()
        };

        // Check if element bounds match baseline
        if (baseline.bounds && info.bounds) {
          // Parse and compare bounds
          comparison.boundsMatch = JSON.stringify(baseline.bounds) === JSON.stringify(info.bounds);
        }

        // Simple byte comparison
        const baselineBuffer = Buffer.from(baseline.screenshot, 'base64');
        if (baselineBuffer.length === currentBuffer.length) {
          let diffBytes = 0;
          for (let i = 0; i < baselineBuffer.length; i++) {
            if (baselineBuffer[i] !== currentBuffer[i]) {
              diffBytes++;
            }
          }
          comparison.identical = diffBytes === 0;
          comparison.diffPercent = (diffBytes / baselineBuffer.length) * 100;
        } else {
          comparison.identical = false;
          comparison.diffPercent = 100;
        }

        const threshold = action.threshold || 0;
        comparison.passed = comparison.diffPercent <= threshold;
        comparison.threshold = threshold;

        result.action = 'compareElement';
        result.comparison = comparison;
        result.success = comparison.passed;

        log('Android compareElement:', baselineName, '- selector:', action.selector, '- diff:', comparison.diffPercent.toFixed(2) + '%', '- passed:', comparison.passed);
        break;
      }

      // ========== Visual Diff Report Generation ==========
      case 'generateDiffReport': {
        const baselineName = action.baseline;
        const comparisons = action.comparisons || [];

        if (!baselineName && comparisons.length === 0) {
          throw new Error('Either baseline name or comparisons array is required');
        }

        const report = {
          timestamp: Date.now(),
          summary: {
            total: 0,
            passed: 0,
            failed: 0
          },
          comparisons: []
        };

        // If single baseline provided, compare against current
        if (baselineName) {
          const baseline = baselines.get(baselineName);
          if (!baseline) {
            throw new Error(`Baseline not found: ${baselineName}`);
          }

          // Capture current screenshot
          const currentBuffer = await device.screenshot();
          const baselineBuffer = Buffer.from(baseline.screenshot, 'base64');

          // Simple pixel diff analysis
          const comparison = {
            baseline: baselineName,
            timestamp: Date.now()
          };

          if (baselineBuffer.length === currentBuffer.length) {
            // Count different bytes and their positions
            let diffBytes = 0;
            const diffRegions = [];
            let regionStart = null;

            for (let i = 0; i < baselineBuffer.length; i++) {
              if (baselineBuffer[i] !== currentBuffer[i]) {
                diffBytes++;
                if (regionStart === null) regionStart = i;
              } else if (regionStart !== null) {
                diffRegions.push({ start: regionStart, end: i - 1 });
                regionStart = null;
              }
            }
            if (regionStart !== null) {
              diffRegions.push({ start: regionStart, end: baselineBuffer.length - 1 });
            }

            comparison.identical = diffBytes === 0;
            comparison.diffBytes = diffBytes;
            comparison.diffPercent = ((diffBytes / baselineBuffer.length) * 100).toFixed(2);
            comparison.diffRegions = diffRegions.length;

            // Create a simple "diff visualization" by marking changed bytes
            // In a real implementation, you'd use a library like pixelmatch
            comparison.analysis = {
              totalBytes: baselineBuffer.length,
              changedBytes: diffBytes,
              changeRegions: diffRegions.slice(0, 10), // First 10 regions
              moreRegions: Math.max(0, diffRegions.length - 10)
            };
          } else {
            comparison.identical = false;
            comparison.diffPercent = 100;
            comparison.sizeDiff = currentBuffer.length - baselineBuffer.length;
            comparison.analysis = {
              baselineSize: baselineBuffer.length,
              currentSize: currentBuffer.length,
              note: 'Screenshots have different sizes - cannot perform byte comparison'
            };
          }

          const threshold = action.threshold || 0;
          comparison.passed = parseFloat(comparison.diffPercent) <= threshold;
          comparison.threshold = threshold;

          report.comparisons.push(comparison);
          report.summary.total = 1;
          report.summary.passed = comparison.passed ? 1 : 0;
          report.summary.failed = comparison.passed ? 0 : 1;
        }

        // Process multiple comparisons if provided
        for (const comp of comparisons) {
          const baseline = baselines.get(comp.baseline);
          if (!baseline) continue;

          const compResult = {
            baseline: comp.baseline,
            name: comp.name || comp.baseline,
            passed: false,
            note: 'Comparison queued'
          };

          // You would perform the comparison here
          report.comparisons.push(compResult);
          report.summary.total++;
        }

        // Generate HTML report if requested
        if (action.format === 'html') {
          const html = `<!DOCTYPE html>
<html>
<head>
  <title>Visual Diff Report - ${new Date(report.timestamp).toISOString()}</title>
  <style>
    body { font-family: sans-serif; margin: 20px; }
    .summary { background: #f5f5f5; padding: 15px; border-radius: 5px; margin-bottom: 20px; }
    .passed { color: green; }
    .failed { color: red; }
    .comparison { border: 1px solid #ddd; padding: 15px; margin-bottom: 10px; border-radius: 5px; }
    .comparison.failed { border-color: #f88; background: #fff5f5; }
    .comparison.passed { border-color: #8f8; background: #f5fff5; }
  </style>
</head>
<body>
  <h1>Visual Diff Report</h1>
  <div class="summary">
    <h2>Summary</h2>
    <p>Total: ${report.summary.total}</p>
    <p class="passed">Passed: ${report.summary.passed}</p>
    <p class="failed">Failed: ${report.summary.failed}</p>
    <p>Generated: ${new Date(report.timestamp).toISOString()}</p>
  </div>
  <h2>Comparisons</h2>
  ${report.comparisons.map(c => `
    <div class="comparison ${c.passed ? 'passed' : 'failed'}">
      <h3>${c.baseline}</h3>
      <p>Status: <strong>${c.passed ? 'PASSED' : 'FAILED'}</strong></p>
      <p>Diff: ${c.diffPercent || 'N/A'}% (threshold: ${c.threshold || 0}%)</p>
      ${c.analysis ? `<pre>${JSON.stringify(c.analysis, null, 2)}</pre>` : ''}
    </div>
  `).join('')}
</body>
</html>`;
          report.html = html;

          if (action.path) {
            const fs = require('fs');
            fs.writeFileSync(action.path, html);
            report.savedTo = action.path;
          }
        }

        result.action = 'generateDiffReport';
        result.report = report;
        result.success = report.summary.failed === 0;

        log('Android generateDiffReport: total:', report.summary.total, 'passed:', report.summary.passed, 'failed:', report.summary.failed);
        break;
      }

      default:
        throw new Error(`Unknown Android action type: ${action.type}`);
    }
  } catch (error) {
    result.success = false;
    result.error = error.message;
    stepRecord.error = error.message;
    throw error;
  } finally {
    // Record step in Android DevTools format
    const devToolsStep = toAndroidDevToolsFormat(stepRecord);
    session.steps.push(devToolsStep);
  }

  return result;
}

// Replay an Android recording
async function replayAndroidRecording(options = {}) {
  const { recording, serial, speed = 1.0, screenshotPerStep = false, stopOnError = true } = options;

  if (!recording || !recording.steps) {
    throw new Error('Recording with steps array is required');
  }

  const targetSerial = serial || recording.device?.serial;
  if (!targetSerial) {
    throw new Error('Target device serial is required');
  }

  // Create session for replay
  const sessionResult = await createAndroidSession({ serial: targetSerial });
  const sessionId = sessionResult.sessionId;
  const session = androidSessions.get(sessionId);

  const results = [];
  const screenshots = [];
  let failed = 0;

  try {
    for (let i = 0; i < recording.steps.length; i++) {
      const step = recording.steps[i];
      const stepResult = {
        step: i,
        type: step.type,
        status: 'pending'
      };

      const startTime = Date.now();

      try {
        // Convert android/* type back to action type
        const actionType = step.type.startsWith('android/')
          ? step.type.slice(8)
          : step.type;

        await executeAndroidAction(sessionId, {
          type: actionType,
          ...step,
          // Apply speed modifier to timeouts
          timeout: (step.timeout || 30000) / speed
        });

        stepResult.status = 'passed';
        stepResult.duration = Date.now() - startTime;

        // Capture screenshot if requested
        if (screenshotPerStep) {
          try {
            const screenshotResult = await executeAndroidAction(sessionId, {
              type: 'screenshot'
            });
            screenshots.push({
              step: i,
              buffer: screenshotResult.buffer
            });
          } catch (e) {
            log(`Screenshot failed at step ${i}: ${e.message}`);
          }
        }

        // Add delay between steps based on speed
        if (i < recording.steps.length - 1) {
          const delay = Math.max(100, 500 / speed);
          await new Promise(resolve => setTimeout(resolve, delay));
        }
      } catch (error) {
        stepResult.status = 'failed';
        stepResult.error = error.message;
        stepResult.duration = Date.now() - startTime;
        failed++;

        if (stopOnError) {
          results.push(stepResult);
          break;
        }
      }

      results.push(stepResult);
    }

    return {
      status: failed === 0 ? 'completed' : 'failed',
      progress: {
        completed: results.length,
        total: recording.steps.length,
        failed
      },
      results,
      screenshots: screenshotPerStep ? screenshots : undefined
    };
  } finally {
    // Clean up session
    await closeAndroidSession(sessionId);
  }
}

// Session management
async function createSession(options = {}) {
  const sessionId = uuidv4();
  const {
    viewport = { width: 1920, height: 1080 },
    userAgent = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
  } = options;

  const b = await initBrowser();
  const context = await b.newContext({ viewport, userAgent });
  const page = await context.newPage();

  // Initialize session state
  const session = {
    id: sessionId,
    context,
    page,
    createdAt: Date.now(),
    lastActivity: Date.now(),
    steps: [],
    viewport,
    userAgent
  };

  sessions.set(sessionId, session);
  log(`Session created: ${sessionId}`);

  return sessionId;
}

async function executeAction(sessionId, action) {
  const session = sessions.get(sessionId);
  if (!session) {
    throw new Error('Session not found');
  }

  session.lastActivity = Date.now();
  const { page, context } = session;
  const result = { success: true };
  const stepRecord = {
    type: action.type,
    ...action,
    timestamp: new Date().toISOString()
  };

  try {
    switch (action.type) {
      // Navigation actions (matching Playwright API)
      case 'goto':
      case 'navigate':
        await page.goto(action.url, {
          waitUntil: action.waitUntil || 'networkidle',
          timeout: action.timeout || 30000
        });
        result.url = page.url();
        result.title = await page.title();
        break;

      case 'goBack':
        await page.goBack({ timeout: action.timeout || 30000 });
        result.url = page.url();
        break;

      case 'goForward':
        await page.goForward({ timeout: action.timeout || 30000 });
        result.url = page.url();
        break;

      case 'reload':
        await page.reload({
          waitUntil: action.waitUntil || 'networkidle',
          timeout: action.timeout || 30000
        });
        result.url = page.url();
        break;

      // Click actions
      case 'click':
        const clickSelector = action.selector || resolveSelector(action.selectors);
        await page.click(clickSelector, {
          button: action.button || 'left',
          clickCount: action.clickCount || 1,
          delay: action.delay,
          force: action.force,
          modifiers: action.modifiers,
          position: action.position,
          timeout: action.timeout || 30000
        });
        result.selector = clickSelector;
        break;

      case 'dblclick':
      case 'doubleClick':
        const dblSelector = action.selector || resolveSelector(action.selectors);
        await page.dblclick(dblSelector, {
          button: action.button || 'left',
          delay: action.delay,
          force: action.force,
          modifiers: action.modifiers,
          position: action.position,
          timeout: action.timeout || 30000
        });
        result.selector = dblSelector;
        break;

      // Input actions
      case 'fill':
      case 'change':
        const fillSelector = action.selector || resolveSelector(action.selectors);
        await page.fill(fillSelector, action.value, {
          force: action.force,
          timeout: action.timeout || 30000
        });
        result.selector = fillSelector;
        break;

      case 'type':
        const typeSelector = action.selector || resolveSelector(action.selectors);
        await page.type(typeSelector, action.text || action.value, {
          delay: action.delay,
          timeout: action.timeout || 30000
        });
        result.selector = typeSelector;
        break;

      case 'clear':
        const clearSelector = action.selector || resolveSelector(action.selectors);
        await page.fill(clearSelector, '', { timeout: action.timeout || 30000 });
        result.selector = clearSelector;
        break;

      case 'selectOption':
        const selectSelector = action.selector || resolveSelector(action.selectors);
        const selected = await page.selectOption(selectSelector, action.values || action.value, {
          force: action.force,
          timeout: action.timeout || 30000
        });
        result.selector = selectSelector;
        result.selected = selected;
        break;

      case 'check':
        const checkSelector = action.selector || resolveSelector(action.selectors);
        await page.check(checkSelector, {
          force: action.force,
          position: action.position,
          timeout: action.timeout || 30000
        });
        result.selector = checkSelector;
        break;

      case 'uncheck':
        const uncheckSelector = action.selector || resolveSelector(action.selectors);
        await page.uncheck(uncheckSelector, {
          force: action.force,
          position: action.position,
          timeout: action.timeout || 30000
        });
        result.selector = uncheckSelector;
        break;

      case 'setChecked':
        const setCheckedSelector = action.selector || resolveSelector(action.selectors);
        await page.setChecked(setCheckedSelector, action.checked, {
          force: action.force,
          position: action.position,
          timeout: action.timeout || 30000
        });
        result.selector = setCheckedSelector;
        break;

      // Hover and focus
      case 'hover':
        const hoverSelector = action.selector || resolveSelector(action.selectors);
        await page.hover(hoverSelector, {
          force: action.force,
          modifiers: action.modifiers,
          position: action.position,
          timeout: action.timeout || 30000
        });
        result.selector = hoverSelector;
        break;

      case 'focus':
        const focusSelector = action.selector || resolveSelector(action.selectors);
        await page.focus(focusSelector, { timeout: action.timeout || 30000 });
        result.selector = focusSelector;
        break;

      // Keyboard actions
      case 'keyDown':
        await page.keyboard.down(action.key);
        break;

      case 'keyUp':
        await page.keyboard.up(action.key);
        break;

      case 'press':
        if (action.selector) {
          await page.press(action.selector, action.key, {
            delay: action.delay,
            timeout: action.timeout || 30000
          });
        } else {
          await page.keyboard.press(action.key, { delay: action.delay });
        }
        break;

      case 'insertText':
        await page.keyboard.insertText(action.text);
        break;

      // Scroll actions
      case 'scroll':
        if (action.selector || action.selectors) {
          const scrollSelector = action.selector || resolveSelector(action.selectors);
          await page.evaluate(({ selector, x, y }) => {
            const el = document.querySelector(selector);
            if (el) el.scrollTo(x || 0, y || 0);
          }, { selector: scrollSelector, x: action.x, y: action.y });
        } else {
          await page.evaluate(({ x, y }) => {
            window.scrollTo(x || 0, y || 0);
          }, { x: action.x, y: action.y });
        }
        break;

      case 'scrollIntoView':
        const scrollIntoViewSelector = action.selector || resolveSelector(action.selectors);
        await page.locator(scrollIntoViewSelector).scrollIntoViewIfNeeded({
          timeout: action.timeout || 30000
        });
        result.selector = scrollIntoViewSelector;
        break;

      // Wait actions
      case 'waitForSelector':
      case 'waitForElement':
        const waitSelector = action.selector || resolveSelector(action.selectors);
        await page.waitForSelector(waitSelector, {
          state: action.state || (action.visible === false ? 'hidden' : 'visible'),
          timeout: action.timeout || 30000
        });
        result.selector = waitSelector;
        break;

      case 'waitForNavigation':
        await page.waitForNavigation({
          url: action.url,
          waitUntil: action.waitUntil || 'networkidle',
          timeout: action.timeout || 30000
        });
        result.url = page.url();
        break;

      case 'waitForLoadState':
        await page.waitForLoadState(action.state || 'networkidle', {
          timeout: action.timeout || 30000
        });
        break;

      case 'waitForFunction':
      case 'waitForExpression':
        await page.waitForFunction(action.expression || action.pageFunction, {
          timeout: action.timeout || 30000,
          polling: action.polling
        });
        break;

      case 'waitForTimeout':
        await page.waitForTimeout(action.timeout || 1000);
        break;

      // Screenshot and content
      case 'screenshot':
        const screenshotOptions = {
          fullPage: action.fullPage,
          type: action.format || 'png',
          quality: action.quality,
          omitBackground: action.omitBackground
        };
        if (action.selector) {
          const element = page.locator(action.selector);
          const buffer = await element.screenshot(screenshotOptions);
          result.screenshot = buffer.toString('base64');
        } else {
          const buffer = await page.screenshot(screenshotOptions);
          result.screenshot = buffer.toString('base64');
        }
        break;

      // Evaluate JavaScript
      case 'evaluate':
        result.value = await page.evaluate(action.expression || action.pageFunction);
        break;

      case 'evaluateHandle':
        const handle = await page.evaluateHandle(action.expression || action.pageFunction);
        result.value = await handle.jsonValue().catch(() => 'Handle cannot be serialized');
        break;

      // Frame handling
      case 'frame':
        const frame = page.frame(action.name || action.url);
        if (!frame) throw new Error(`Frame not found: ${action.name || action.url}`);
        // Store current frame context for subsequent actions
        session.currentFrame = frame;
        result.frameName = frame.name();
        break;

      case 'mainFrame':
        session.currentFrame = null;
        break;

      // File upload
      case 'setInputFiles':
        const fileSelector = action.selector || resolveSelector(action.selectors);
        await page.setInputFiles(fileSelector, action.files, {
          timeout: action.timeout || 30000
        });
        result.selector = fileSelector;
        break;

      // Dialog handling
      case 'acceptDialog':
        session.dialogHandler = (dialog) => dialog.accept(action.promptText);
        page.once('dialog', session.dialogHandler);
        break;

      case 'dismissDialog':
        session.dialogHandler = (dialog) => dialog.dismiss();
        page.once('dialog', session.dialogHandler);
        break;

      // Viewport and emulation
      case 'setViewport':
      case 'setViewportSize':
        await page.setViewportSize({
          width: action.width,
          height: action.height
        });
        session.viewport = { width: action.width, height: action.height };
        break;

      case 'emulateMedia':
        await page.emulateMedia({
          media: action.media,
          colorScheme: action.colorScheme,
          reducedMotion: action.reducedMotion,
          forcedColors: action.forcedColors
        });
        break;

      case 'setGeolocation':
        await context.setGeolocation({
          latitude: action.latitude,
          longitude: action.longitude,
          accuracy: action.accuracy
        });
        break;

      case 'emulateNetworkConditions':
        const client = await context.newCDPSession(page);
        await client.send('Network.emulateNetworkConditions', {
          offline: action.offline || false,
          latency: action.latency || 0,
          downloadThroughput: action.download !== undefined ? action.download : -1,
          uploadThroughput: action.upload !== undefined ? action.upload : -1
        });
        break;

      // Locator-based actions (for complex queries)
      case 'locator':
        // Execute action on a locator chain
        let locator = page.locator(action.selector);
        if (action.filter) {
          locator = locator.filter(action.filter);
        }
        if (action.nth !== undefined) {
          locator = locator.nth(action.nth);
        }
        if (action.first) locator = locator.first();
        if (action.last) locator = locator.last();

        // Execute the method
        switch (action.method) {
          case 'click': await locator.click(action.options); break;
          case 'fill': await locator.fill(action.value, action.options); break;
          case 'type': await locator.type(action.text, action.options); break;
          case 'check': await locator.check(action.options); break;
          case 'uncheck': await locator.uncheck(action.options); break;
          case 'hover': await locator.hover(action.options); break;
          case 'focus': await locator.focus(action.options); break;
          case 'press': await locator.press(action.key, action.options); break;
          case 'selectOption': await locator.selectOption(action.values, action.options); break;
          case 'scrollIntoViewIfNeeded': await locator.scrollIntoViewIfNeeded(action.options); break;
          case 'screenshot':
            const locBuffer = await locator.screenshot(action.options);
            result.screenshot = locBuffer.toString('base64');
            break;
          case 'textContent':
            result.value = await locator.textContent(action.options);
            break;
          case 'innerText':
            result.value = await locator.innerText(action.options);
            break;
          case 'innerHTML':
            result.value = await locator.innerHTML(action.options);
            break;
          case 'getAttribute':
            result.value = await locator.getAttribute(action.name, action.options);
            break;
          case 'inputValue':
            result.value = await locator.inputValue(action.options);
            break;
          case 'isVisible':
            result.value = await locator.isVisible(action.options);
            break;
          case 'isEnabled':
            result.value = await locator.isEnabled(action.options);
            break;
          case 'isChecked':
            result.value = await locator.isChecked(action.options);
            break;
          case 'count':
            result.value = await locator.count();
            break;
          default:
            throw new Error(`Unknown locator method: ${action.method}`);
        }
        result.selector = action.selector;
        break;

      // Custom step (for recording agent thoughts/notes)
      case 'customStep':
        // Just record it, no browser action
        break;

      // Get element info (useful for agents)
      case 'getElementInfo':
        const infoSelector = action.selector || resolveSelector(action.selectors);
        const element = page.locator(infoSelector);
        result.info = {
          visible: await element.isVisible().catch(() => false),
          enabled: await element.isEnabled().catch(() => false),
          checked: await element.isChecked().catch(() => null),
          text: await element.textContent().catch(() => null),
          value: await element.inputValue().catch(() => null),
          tagName: await element.evaluate(el => el.tagName.toLowerCase()).catch(() => null),
          attributes: await element.evaluate(el => {
            const attrs = {};
            for (const attr of el.attributes) {
              attrs[attr.name] = attr.value;
            }
            return attrs;
          }).catch(() => {})
        };
        result.selector = infoSelector;
        break;

      // Query - extract specific data from page (for LLM agents)
      case 'query':
        const querySelector = action.selector;
        const extractProps = action.extract || ['text'];
        const limit = action.limit || 20;

        result.results = await page.evaluate(({ selector, props, limit }) => {
          const elements = document.querySelectorAll(selector);
          const results = [];

          for (let i = 0; i < Math.min(elements.length, limit); i++) {
            const el = elements[i];
            const item = {};

            for (const prop of props) {
              switch (prop) {
                case 'text':
                  item.text = (el.textContent || '').trim().slice(0, 100);
                  break;
                case 'href':
                  item.href = el.href || el.getAttribute('href') || null;
                  break;
                case 'value':
                  item.value = el.value || null;
                  break;
                case 'src':
                  item.src = el.src || el.getAttribute('src') || null;
                  break;
                case 'id':
                  item.id = el.id || null;
                  break;
                case 'class':
                  item.class = el.className || null;
                  break;
                case 'name':
                  item.name = el.name || el.getAttribute('name') || null;
                  break;
                case 'type':
                  item.type = el.type || el.getAttribute('type') || null;
                  break;
                case 'placeholder':
                  item.placeholder = el.placeholder || el.getAttribute('placeholder') || null;
                  break;
                case 'checked':
                  item.checked = el.checked;
                  break;
                case 'disabled':
                  item.disabled = el.disabled;
                  break;
                case 'html':
                  item.html = el.innerHTML.slice(0, 200);
                  break;
                case 'tag':
                  item.tag = el.tagName.toLowerCase();
                  break;
                case 'selector':
                  // Generate a unique selector for this element
                  if (el.id) {
                    item.selector = '#' + el.id;
                  } else if (el.getAttribute('data-testid')) {
                    item.selector = `[data-testid="${el.getAttribute('data-testid')}"]`;
                  } else if (el.name) {
                    item.selector = `[name="${el.name}"]`;
                  } else {
                    // nth-child selector
                    const parent = el.parentElement;
                    if (parent) {
                      const siblings = Array.from(parent.children).filter(c => c.tagName === el.tagName);
                      const idx = siblings.indexOf(el) + 1;
                      item.selector = `${el.tagName.toLowerCase()}:nth-of-type(${idx})`;
                    } else {
                      item.selector = el.tagName.toLowerCase();
                    }
                  }
                  break;
              }
            }

            // Only add non-empty items
            if (Object.keys(item).some(k => item[k] !== null && item[k] !== '')) {
              results.push(item);
            }
          }

          return results;
        }, { selector: querySelector, props: extractProps, limit });

        result.count = result.results.length;
        result.selector = querySelector;
        break;

      default:
        // Try to handle as evaluating JS if it's not a standard action
        if (action.expression) {
          result.value = await page.evaluate(action.expression);
        } else {
          log(`Unknown action type: ${action.type}`);
          stepRecord.warning = `Unknown action type: ${action.type}`;
        }
    }
  } catch (error) {
    result.success = false;
    result.error = error.message;
    stepRecord.error = error.message;
    throw error;
  } finally {
    // Record step in Chrome DevTools Recorder format (for compatibility)
    // Skip unsupported step types (toDevToolsFormat returns null for these)
    const devToolsStep = toDevToolsFormat(stepRecord);
    if (devToolsStep) {
      session.steps.push(devToolsStep);
    }
  }

  // Get current state
  result.url = page.url();
  result.title = await page.title();

  return result;
}

async function getSessionState(sessionId, options = {}) {
  const session = sessions.get(sessionId);
  if (!session) {
    throw new Error('Session not found');
  }

  const { page } = session;
  const {
    view = 'minimal',  // minimal, actions, forms, full
    query = null,      // CSS selector to query specific elements
    includeHtml = false
  } = options;

  // Always include basic info
  const result = {
    url: page.url(),
    title: await page.title()
  };

  // Handle different view modes
  switch (view) {
    case 'minimal':
      // Just URL and title - nothing else needed
      break;

    case 'actions':
      // Only clickable elements
      result.actions = await page.evaluate(() => {
        const elements = [];
        const seen = new Set();
        document.querySelectorAll('a[href], button, [role="button"], input[type="submit"], [onclick]').forEach(el => {
          if (elements.length >= 30) return;
          const text = (el.textContent || el.value || el.getAttribute('aria-label') || '').trim().slice(0, 50);
          if (!text || seen.has(text)) return;
          seen.add(text);

          let selector;
          if (el.id) selector = '#' + el.id;
          else if (el.getAttribute('data-testid')) selector = `[data-testid="${el.getAttribute('data-testid')}"]`;
          else if (el.name) selector = `[name="${el.name}"]`;
          else if (el.getAttribute('aria-label')) selector = `[aria-label="${el.getAttribute('aria-label')}"]`;
          else selector = null;

          const item = { text };
          if (selector) item.selector = selector;
          if (el.tagName === 'A' && el.href) item.href = el.href.slice(0, 80);
          elements.push(item);
        });
        return elements;
      });
      break;

    case 'forms':
      // Only form inputs
      result.inputs = await page.evaluate(() => {
        const elements = [];
        document.querySelectorAll('input:not([type="hidden"]), textarea, select').forEach(el => {
          if (elements.length >= 20) return;
          const item = {
            type: el.type || el.tagName.toLowerCase(),
            name: el.name || el.id || el.getAttribute('aria-label') || el.placeholder || null
          };

          if (el.id) item.selector = '#' + el.id;
          else if (el.name) item.selector = `[name="${el.name}"]`;
          else if (el.getAttribute('aria-label')) item.selector = `[aria-label="${el.getAttribute('aria-label')}"]`;

          if (el.value) item.value = el.value.slice(0, 50);
          if (el.placeholder) item.placeholder = el.placeholder.slice(0, 30);
          if (el.type === 'checkbox' || el.type === 'radio') item.checked = el.checked;

          elements.push(item);
        });
        return elements;
      });
      break;

    case 'full':
      // Full snapshot (legacy behavior)
      result.snapshot = await getAccessibilitySnapshot(page);
      break;
  }

  // Query specific elements if requested
  if (query) {
    result.query = await page.evaluate((selector) => {
      const elements = [];
      document.querySelectorAll(selector).forEach(el => {
        if (elements.length >= 20) return;
        const text = (el.textContent || '').trim().slice(0, 100);
        const item = { text };
        if (el.id) item.selector = '#' + el.id;
        else if (el.name) item.selector = `[name="${el.name}"]`;
        if (el.href) item.href = el.href;
        if (el.value) item.value = el.value;
        elements.push(item);
      });
      return elements;
    }, query);
  }

  // Only include raw HTML if explicitly requested
  if (includeHtml) {
    result.html = await page.content();
  }

  return result;
}

// Get concise page snapshot for LLM agents
async function getAccessibilitySnapshot(page) {
  try {
    // Extract key interactive elements and page structure
    const snapshot = await page.evaluate(() => {
      const result = {
        elements: [],
        headings: [],
        text: ''
      };
      const maxElements = 50;

      // Get page text content (truncated)
      const bodyText = (document.body?.innerText || '').replace(/\s+/g, ' ').trim();
      result.text = bodyText.slice(0, 500) + (bodyText.length > 500 ? '...' : '');

      // Get headings for structure
      document.querySelectorAll('h1, h2, h3').forEach((el, i) => {
        if (result.headings.length >= 10) return;
        const text = el.textContent.trim().slice(0, 60);
        if (text) result.headings.push({ level: el.tagName.toLowerCase(), text });
      });

      // Get clickable elements
      const clickable = document.querySelectorAll('a, button, [role="button"], [onclick], input[type="submit"]');
      clickable.forEach((el) => {
        if (result.elements.length >= maxElements) return;
        const text = (el.textContent || el.value || el.getAttribute('aria-label') || '').trim().slice(0, 50);
        if (!text) return;
        const selector = getUniqueSelector(el);
        const href = el.tagName === 'A' ? el.getAttribute('href') : null;
        result.elements.push({
          type: el.tagName.toLowerCase(),
          text,
          selector,
          ...(href && { href: href.slice(0, 100) })
        });
      });

      // Get input fields
      const inputs = document.querySelectorAll('input:not([type="hidden"]):not([type="submit"]), textarea, select');
      inputs.forEach((el) => {
        if (result.elements.length >= maxElements) return;
        const label = el.getAttribute('aria-label') || el.getAttribute('placeholder') ||
                      el.getAttribute('name') || el.id || '';
        const selector = getUniqueSelector(el);
        const inputType = el.type || el.tagName.toLowerCase();
        result.elements.push({
          type: 'input',
          inputType,
          label: label.slice(0, 30),
          selector
        });
      });

      function getUniqueSelector(el) {
        if (el.id) return '#' + el.id;
        if (el.getAttribute('data-testid')) return '[data-testid="' + el.getAttribute('data-testid') + '"]';
        if (el.getAttribute('aria-label')) return '[aria-label="' + el.getAttribute('aria-label') + '"]';
        if (el.name) return '[name="' + el.name + '"]';
        // Fallback to CSS path
        const path = [];
        let current = el;
        while (current && current.nodeType === Node.ELEMENT_NODE && path.length < 3) {
          let selector = current.tagName.toLowerCase();
          if (current.className && typeof current.className === 'string') {
            const classes = current.className.trim().split(/\s+/).filter(c => c && !c.includes(':'));
            if (classes.length) selector += '.' + classes.slice(0, 2).join('.');
          }
          path.unshift(selector);
          current = current.parentNode;
        }
        return path.join(' > ');
      }

      return result;
    });

    return snapshot;
  } catch (e) {
    return { error: e.message };
  }
}

async function closeSession(sessionId) {
  const session = sessions.get(sessionId);
  if (session) {
    await session.context.close();
    sessions.delete(sessionId);
    log(`Session closed: ${sessionId}`);
  }
}

// Resolve Chrome DevTools Recorder selector format to Playwright selector

async function probePage(options) {
  const {
    url,
    timeout = 30000,
    viewport = { width: 1920, height: 1080 },
    userAgent = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
  } = options;

  const probeStart = Date.now();
  const b = await initBrowser();
  const context = await b.newContext({ viewport, userAgent });
  const page = await context.newPage();

  // Track network requests
  const requests = [];
  page.on('request', req => {
    requests.push({
      url: req.url(),
      resourceType: req.resourceType(),
      startTime: Date.now() - probeStart
    });
  });

  page.on('response', res => {
    const req = requests.find(r => r.url === res.url());
    if (req) {
      req.status = res.status();
      req.endTime = Date.now() - probeStart;
      const headers = res.headers();
      req.contentLength = parseInt(headers['content-length'] || '0', 10);
      req.contentType = headers['content-type'] || 'unknown';
    }
  });

  try {
    // Navigate with 'commit' to start timing from first byte
    const navigationStart = Date.now();

    // First, wait for domcontentloaded
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout });
    const domContentLoaded = Date.now() - navigationStart;

    // Then wait for load
    await page.waitForLoadState('load', { timeout });
    const loadComplete = Date.now() - navigationStart;

    // Then wait for networkidle
    const networkIdleStart = Date.now();
    await page.waitForLoadState('networkidle', { timeout }).catch(() => {});
    const networkIdleTime = Date.now() - navigationStart;
    const networkIdleWait = Date.now() - networkIdleStart;

    // Get Performance API timing
    const performanceTiming = await page.evaluate(() => {
      const timing = performance.timing;
      const navStart = timing.navigationStart;
      return {
        // Connection timing
        dnsLookup: timing.domainLookupEnd - timing.domainLookupStart,
        tcpConnect: timing.connectEnd - timing.connectStart,
        ttfb: timing.responseStart - navStart,

        // Page timing
        responseTime: timing.responseEnd - timing.responseStart,
        domParsing: timing.domInteractive - timing.domLoading,
        domContentLoaded: timing.domContentLoadedEventEnd - navStart,
        loadComplete: timing.loadEventEnd - navStart,

        // Derived metrics
        domInteractive: timing.domInteractive - navStart,
        domComplete: timing.domComplete - navStart
      };
    });

    // Get resource breakdown
    const resourceMetrics = await page.evaluate(() => {
      const resources = performance.getEntriesByType('resource');
      const byType = {};
      let totalTransfer = 0;

      resources.forEach(r => {
        const type = r.initiatorType || 'other';
        if (!byType[type]) {
          byType[type] = { count: 0, totalDuration: 0, totalSize: 0 };
        }
        byType[type].count++;
        byType[type].totalDuration += r.duration;
        byType[type].totalSize += r.transferSize || 0;
        totalTransfer += r.transferSize || 0;
      });

      return {
        totalRequests: resources.length,
        totalTransferSize: totalTransfer,
        byType
      };
    });

    // Calculate JS execution estimate (time from DOMContentLoaded to Load)
    const jsExecutionEstimate = loadComplete - domContentLoaded;

    // Generate recommendations
    const recommendations = {
      pwDelay: Math.max(1000, Math.ceil((jsExecutionEstimate + networkIdleWait) * 1.5 / 500) * 500),
      timeout: Math.max(30000, Math.ceil(networkIdleTime * 2 / 5000) * 5000),
      scrollDelay: Math.max(1000, Math.ceil(jsExecutionEstimate / 500) * 500)
    };

    return {
      url: page.url(),
      timing: {
        domContentLoaded,
        loadComplete,
        networkIdleTime,
        jsExecutionEstimate,
        performance: performanceTiming
      },
      resources: resourceMetrics,
      networkRequests: {
        total: requests.length,
        byType: requests.reduce((acc, r) => {
          acc[r.resourceType] = (acc[r.resourceType] || 0) + 1;
          return acc;
        }, {})
      },
      recommendations,
      probeTime: Date.now() - probeStart
    };
  } finally {
    await context.close();
  }
}

async function replayRecording(options) {
  const {
    recording,
    timeout = 30000,
    viewport = { width: 1920, height: 1080 },
    userAgent = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    extractLinks = true
  } = options;

  const startTime = Date.now();
  const b = await initBrowser();
  const context = await b.newContext({ viewport, userAgent });
  const page = await context.newPage();

  const stepResults = [];

  try {
    for (let i = 0; i < recording.steps.length; i++) {
      const step = recording.steps[i];
      const stepStart = Date.now();
      let stepResult = { index: i, type: step.type, success: true };

      try {
        switch (step.type) {
          case 'setViewport':
            await page.setViewportSize({
              width: step.width,
              height: step.height
            });
            break;

          case 'navigate':
          case 'goto':
            await page.goto(step.url, { waitUntil: 'networkidle', timeout });
            stepResult.url = step.url;
            break;

          case 'click':
            // Support both DevTools Recorder format (selectors array) and session format (selector string)
            const clickSelector = step.selector || resolveSelector(step.selectors);
            await page.click(clickSelector, {
              button: step.button || 'left',
              clickCount: step.clickCount || 1,
              timeout
            });
            stepResult.selector = clickSelector;
            break;

          case 'doubleClick':
          case 'dblclick':
            const dblClickSelector = step.selector || resolveSelector(step.selectors);
            await page.dblclick(dblClickSelector, { timeout });
            stepResult.selector = dblClickSelector;
            break;

          case 'change':
          case 'fill':
            const changeSelector = step.selector || resolveSelector(step.selectors);
            await page.fill(changeSelector, step.value, { timeout });
            stepResult.selector = changeSelector;
            stepResult.value = step.value;
            break;

          case 'type':
            const typeSelector = step.selector || resolveSelector(step.selectors);
            await page.type(typeSelector, step.text, { timeout });
            stepResult.selector = typeSelector;
            stepResult.text = step.text;
            break;

          case 'keyDown':
            await page.keyboard.down(step.key);
            stepResult.key = step.key;
            break;

          case 'keyUp':
            await page.keyboard.up(step.key);
            stepResult.key = step.key;
            break;

          case 'scroll':
            if (step.selectors) {
              const scrollSelector = resolveSelector(step.selectors);
              await page.evaluate(({ selector, x, y }) => {
                const el = document.querySelector(selector);
                if (el) el.scrollTo(x || 0, y || 0);
              }, { selector: scrollSelector, x: step.x, y: step.y });
            } else {
              await page.evaluate(({ x, y }) => {
                window.scrollTo(x || 0, y || 0);
              }, { x: step.x, y: step.y });
            }
            break;

          case 'hover':
            const hoverSelector = step.selector || resolveSelector(step.selectors);
            await page.hover(hoverSelector, { timeout });
            stepResult.selector = hoverSelector;
            break;

          case 'press':
            await page.keyboard.press(step.key);
            stepResult.key = step.key;
            break;

          case 'screenshot':
            // Skip screenshot during replay - just record it happened
            stepResult.skipped = true;
            break;

          case 'evaluate':
            const evalResult = await page.evaluate(step.expression);
            stepResult.result = evalResult;
            break;

          case 'goBack':
            await page.goBack({ timeout });
            break;

          case 'goForward':
            await page.goForward({ timeout });
            break;

          case 'reload':
            await page.reload({ timeout });
            break;

          case 'waitForElement':
            const waitSelector = resolveSelector(step.selectors);
            await page.waitForSelector(waitSelector, {
              state: step.visible === false ? 'hidden' : 'visible',
              timeout
            });
            stepResult.selector = waitSelector;
            break;

          case 'waitForExpression':
            await page.waitForFunction(step.expression, { timeout });
            stepResult.expression = step.expression;
            break;

          case 'emulateNetworkConditions':
            const client = await page.context().newCDPSession(page);
            await client.send('Network.emulateNetworkConditions', {
              offline: step.offline || false,
              latency: step.latency || 0,
              downloadThroughput: step.download !== undefined ? step.download : -1,
              uploadThroughput: step.upload !== undefined ? step.upload : -1
            });
            break;

          case 'setGeolocation':
            await context.setGeolocation({
              latitude: step.latitude,
              longitude: step.longitude,
              accuracy: step.accuracy
            });
            break;

          case 'customStep':
            log(`Skipping custom step: ${step.name}`);
            stepResult.warning = `Skipped custom step: ${step.name}`;
            break;

          case 'close':
            // Skip close step - we handle cleanup ourselves
            break;

          default:
            log(`Unknown step type: ${step.type}`);
            stepResult.warning = `Unknown step type: ${step.type}`;
        }
      } catch (stepError) {
        stepResult.success = false;
        stepResult.error = stepError.message;
        log(`Step ${i} (${step.type}) failed: ${stepError.message}`);
        // Continue to next step unless it's critical
        if (step.type === 'navigate') {
          throw stepError; // Navigation failures are fatal
        }
      }

      stepResult.duration = Date.now() - stepStart;
      stepResults.push(stepResult);
    }

    // Get final page content
    const content = await page.content();
    const title = await page.title();
    const finalUrl = page.url();

    // Extract links if requested
    let links = [];
    if (extractLinks) {
      links = await page.evaluate(() => {
        const anchors = document.querySelectorAll('a[href]');
        const hrefs = [];
        anchors.forEach(a => {
          const href = a.href;
          if (href && (href.startsWith('http://') || href.startsWith('https://'))) {
            hrefs.push(href);
          }
        });
        return [...new Set(hrefs)];
      });
    }

    return {
      content,
      url: finalUrl,
      title,
      links,
      recording: {
        title: recording.title || 'untitled',
        stepsExecuted: stepResults.length,
        stepResults
      },
      metadata: {
        method: 'playwright-replay',
        viewport,
        contentLength: content.length,
        totalTime: Date.now() - startTime
      }
    };
  } finally {
    await context.close();
  }
}

// Resolve Chrome DevTools Recorder selector format to Playwright selector
function resolveSelector(selectors) {
  if (!selectors || selectors.length === 0) {
    throw new Error('No selectors provided');
  }

  // Chrome DevTools Recorder provides an array of selectors in order of preference
  // Try each until one works; for simplicity, take the first CSS or XPath selector
  for (const selector of selectors) {
    if (Array.isArray(selector)) {
      // Nested array - use first element
      return selector[0];
    }
    if (typeof selector === 'string') {
      // ARIA selectors start with 'aria/'
      if (selector.startsWith('aria/')) {
        // Convert to Playwright role selector
        const ariaLabel = selector.slice(5);
        return `text=${ariaLabel}`;
      }
      // XPath selectors start with 'xpath/'
      if (selector.startsWith('xpath/')) {
        return selector.slice(6);
      }
      // Pierce selectors (shadow DOM) start with 'pierce/'
      if (selector.startsWith('pierce/')) {
        return selector.slice(7);
      }
      // Text selectors start with 'text/'
      if (selector.startsWith('text/')) {
        return `text=${selector.slice(5)}`;
      }
      // Otherwise it's a CSS selector
      return selector;
    }
  }

  // Fallback to first selector
  return Array.isArray(selectors[0]) ? selectors[0][0] : selectors[0];
}

async function fetchPage(options) {
  const {
    url,
    waitFor = 'load',
    timeout = 30000,
    delay = 0,  // Additional delay after page load (ms) - useful for SPAs
    scroll = false,  // Scroll to bottom of page
    scrollCount = 0,  // Number of scroll iterations (for infinite scroll)
    scrollDelay = 1000,  // Delay between scrolls (ms)
    clickSelector = null,  // CSS selector to click (e.g., "Load More" button)
    clickCount = 1,  // Number of times to click
    viewport = { width: 1920, height: 1080 },
    userAgent = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    blockResources = [],
    extractLinks = true
  } = options;

  const startTime = Date.now();
  const b = await initBrowser();
  const context = await b.newContext({
    viewport,
    userAgent
  });

  const page = await context.newPage();

  // Block specified resource types
  if (blockResources.length > 0) {
    await page.route('**/*', (route) => {
      const resourceType = route.request().resourceType();
      if (blockResources.includes(resourceType)) {
        route.abort();
      } else {
        route.continue();
      }
    });
  }

  try {
    // Determine wait strategy
    let waitUntil = 'networkidle';
    let waitSelector = null;

    if (waitFor === 'networkidle' || waitFor === 'domcontentloaded' || waitFor === 'load' || waitFor === 'commit') {
      waitUntil = waitFor;
    } else if (waitFor && waitFor.startsWith('selector:')) {
      waitUntil = 'domcontentloaded';
      waitSelector = waitFor.substring(9);
    }

    await page.goto(url, {
      waitUntil,
      timeout
    });

    // Wait for specific selector if provided
    if (waitSelector) {
      await page.waitForSelector(waitSelector, { timeout });
    }

    // Additional delay for SPA rendering
    if (delay > 0) {
      await new Promise(resolve => setTimeout(resolve, delay));
    }

    // Scroll to bottom (single scroll or multiple for infinite scroll)
    if (scroll || scrollCount > 0) {
      const iterations = scrollCount > 0 ? scrollCount : 1;
      for (let i = 0; i < iterations; i++) {
        await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
        await new Promise(resolve => setTimeout(resolve, scrollDelay));
        // Wait for any new content to load
        await page.waitForLoadState('networkidle').catch(() => {});
      }
      // Scroll back to top for consistent content extraction
      await page.evaluate(() => window.scrollTo(0, 0));
    }

    // Click element (e.g., "Load More" button)
    if (clickSelector) {
      for (let i = 0; i < clickCount; i++) {
        try {
          await page.click(clickSelector, { timeout: 5000 });
          await new Promise(resolve => setTimeout(resolve, scrollDelay));
          await page.waitForLoadState('networkidle').catch(() => {});
        } catch (e) {
          log(`Click ${i + 1}/${clickCount} failed: ${e.message}`);
          break;  // Stop if button not found
        }
      }
    }

    // Get page content and metadata
    const content = await page.content();
    const title = await page.title();
    const finalUrl = page.url();

    // Extract links if requested
    let links = [];
    if (extractLinks) {
      links = await page.evaluate(() => {
        const anchors = document.querySelectorAll('a[href]');
        const hrefs = [];
        anchors.forEach(a => {
          const href = a.href;
          if (href && (href.startsWith('http://') || href.startsWith('https://'))) {
            hrefs.push(href);
          }
        });
        return [...new Set(hrefs)];
      });
    }

    const loadTime = Date.now() - startTime;

    return {
      content,
      url: finalUrl,
      title,
      links,
      metadata: {
        method: 'playwright',
        viewport,
        contentLength: content.length,
        loadTime
      }
    };
  } finally {
    await context.close();
  }
}

function parseBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      try {
        resolve(JSON.parse(body));
      } catch (e) {
        reject(new Error('Invalid JSON'));
      }
    });
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  // CORS headers
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  if (req.method === 'POST' && req.url === '/fetch') {
    try {
      const options = await parseBody(req);

      if (!options.url) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'url is required' }));
        return;
      }

      log(`Fetching: ${options.url}`);
      const result = await fetchPage(options);

      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(result));
    } catch (error) {
      console.error('Fetch error:', error.message);
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: error.message }));
    }
    return;
  }

  if (req.method === 'POST' && req.url === '/probe') {
    try {
      const options = await parseBody(req);

      if (!options.url) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'url is required' }));
        return;
      }

      log(`Probing: ${options.url}`);
      const result = await probePage(options);

      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(result));
    } catch (error) {
      console.error('Probe error:', error.message);
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: error.message }));
    }
    return;
  }

  if (req.method === 'POST' && req.url === '/replay') {
    try {
      const options = await parseBody(req);

      if (!options.recording) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'recording is required (Chrome DevTools Recorder JSON format)' }));
        return;
      }

      log(`Replaying recording: ${options.recording.title || 'untitled'}`);
      const result = await replayRecording(options);

      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(result));
    } catch (error) {
      console.error('Replay error:', error.message);
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: error.message }));
    }
    return;
  }

  // Session endpoints
  if (req.url && req.url.startsWith('/session')) {
    const parts = req.url.split('/');
    // /session/create
    if (req.method === 'POST' && parts.length === 3 && parts[2] === 'create') {
        try {
            const options = await parseBody(req);
            const sessionId = await createSession(options);
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ sessionId }));
        } catch (error) {
            console.error('Session create error:', error.message);
            res.writeHead(500, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: error.message }));
        }
        return;
    }

    const sessionId = parts[2];

    // /session/{sessionId}/action
    if (req.method === 'POST' && parts.length === 4 && parts[3] === 'action') {
         try {
             const action = await parseBody(req);
             const result = await executeAction(sessionId, action);
             res.writeHead(200, { 'Content-Type': 'application/json' });
             res.end(JSON.stringify(result));
         } catch (error) {
             console.error('Session action error:', error.message);
             res.writeHead(500, { 'Content-Type': 'application/json' });
             res.end(JSON.stringify({ error: error.message }));
         }
         return;
    }

    // /session/{sessionId}/state - GET with query params or POST with body
    if (parts.length === 4 && parts[3].startsWith('state')) {
         try {
             let options = {};
             if (req.method === 'POST') {
                 options = await parseBody(req);
             } else {
                 // Parse query string for GET requests
                 const urlParts = req.url.split('?');
                 if (urlParts[1]) {
                     const params = new URLSearchParams(urlParts[1]);
                     if (params.get('view')) options.view = params.get('view');
                     if (params.get('query')) options.query = params.get('query');
                     if (params.get('html') === 'true') options.includeHtml = true;
                 }
             }
             const result = await getSessionState(sessionId, options);
             res.writeHead(200, { 'Content-Type': 'application/json' });
             res.end(JSON.stringify(result));
         } catch (error) {
             console.error('Session state error:', error.message);
             res.writeHead(500, { 'Content-Type': 'application/json' });
             res.end(JSON.stringify({ error: error.message }));
         }
         return;
    }

    // /session/{sessionId}/commit (end session and return recording)
    if (req.method === 'POST' && parts.length === 4 && parts[3] === 'commit') {
         try {
             const session = sessions.get(sessionId);
             if (!session) throw new Error('Session not found');

             // Auto-generate title from date and first URL
             const date = new Date(session.createdAt);
             const dateStr = date.toISOString().split('T')[0]; // YYYY-MM-DD
             const timeStr = date.toTimeString().slice(0, 5).replace(':', ''); // HHMM
             const firstNav = session.steps.find(s => s.type === 'navigate');
             let domain = '';
             if (firstNav && firstNav.url) {
               try {
                 domain = ' - ' + new URL(firstNav.url).hostname.replace('www.', '');
               } catch {}
             }
             const title = `Session ${dateStr} ${timeStr}${domain}`;

             const recording = {
                 title,
                 steps: session.steps
             };

             await closeSession(sessionId);

             res.writeHead(200, { 'Content-Type': 'application/json' });
             res.end(JSON.stringify({ recording }));
         } catch (error) {
             console.error('Session commit error:', error.message);
             res.writeHead(500, { 'Content-Type': 'application/json' });
             res.end(JSON.stringify({ error: error.message }));
         }
         return;
    }

    // /session/{sessionId} (DELETE)
    if (req.method === 'DELETE' && parts.length === 3) {
        try {
            await closeSession(sessionId);
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ success: true }));
        } catch (error) {
            console.error('Session close error:', error.message);
            res.writeHead(500, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: error.message }));
        }
        return;
    }
  }

  // ============================================================================
  // Android Endpoints
  // ============================================================================

  // GET /android/devices - List connected Android devices
  if (req.method === 'GET' && req.url.startsWith('/android/devices')) {
    try {
      const urlParts = req.url.split('?');
      let options = {};
      if (urlParts[1]) {
        const params = new URLSearchParams(urlParts[1]);
        if (params.get('host')) options.host = params.get('host');
        if (params.get('port')) options.port = parseInt(params.get('port'), 10);
      }
      const result = await discoverAndroidDevices(options);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(result));
    } catch (error) {
      console.error('Android device discovery error:', error.message);
      const status = error.message.includes('ADB') ? 500 : 500;
      res.writeHead(status, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        error: error.message,
        hint: error.message.includes('ADB') ? 'Run "adb start-server" first' : undefined
      }));
    }
    return;
  }

  // POST /android/replay - Replay an Android recording
  if (req.method === 'POST' && req.url === '/android/replay') {
    try {
      const options = await parseBody(req);
      if (!options.recording) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Recording is required' }));
        return;
      }
      log(`Replaying Android recording: ${options.recording.title || 'untitled'}`);
      const result = await replayAndroidRecording(options);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(result));
    } catch (error) {
      console.error('Android replay error:', error.message);
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: error.message }));
    }
    return;
  }

  // POST /android/connect - Connect to remote device via WebSocket
  if (req.method === 'POST' && req.url === '/android/connect') {
    try {
      const options = await parseBody(req);
      if (!options.wsEndpoint) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'wsEndpoint is required' }));
        return;
      }

      const device = await _android.connect(options.wsEndpoint, {
        headers: options.headers,
        slowMo: options.slowMo,
        timeout: options.timeout || 30000
      });

      const sessionId = `android-remote-${uuidv4()}`;
      const model = device.model();
      const serial = device.serial();

      let screen = { width: 0, height: 0 };
      try {
        const info = await device.info();
        screen = { width: info.width || 0, height: info.height || 0 };
      } catch (e) {
        log(`Could not get screen info: ${e.message}`);
      }

      const session = {
        id: sessionId,
        device,
        serial,
        model,
        screen,
        createdAt: Date.now(),
        lastActivity: Date.now(),
        steps: [],
        webViews: new Map(),
        browserContext: null,
        remote: true
      };

      androidSessions.set(sessionId, session);
      log(`Remote Android session created: ${sessionId}`);

      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        sessionId,
        device: { serial, model },
        screen
      }));
    } catch (error) {
      console.error('Android remote connect error:', error.message);
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: error.message }));
    }
    return;
  }

  // Android session endpoints
  if (req.url && req.url.startsWith('/android/session')) {
    const parts = req.url.split('/').filter(p => p);
    // parts: ['android', 'session', 'create'] or ['android', 'session', '{id}', 'action']

    // POST /android/session/create
    if (req.method === 'POST' && parts.length === 3 && parts[2] === 'create') {
      try {
        const options = await parseBody(req);
        const result = await createAndroidSession(options);
        res.writeHead(201, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error) {
        console.error('Android session create error:', error.message);
        const status = error.message.includes('not found') ? 404 :
                       error.message.includes('required') ? 400 : 500;
        res.writeHead(status, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: error.message }));
      }
      return;
    }

    // Get session ID from URL
    const sessionId = parts[2];

    // POST /android/session/{id}/action
    if (req.method === 'POST' && parts.length === 4 && parts[3] === 'action') {
      try {
        const action = await parseBody(req);
        const result = await executeAndroidAction(sessionId, action);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error) {
        console.error('Android action error:', error.message);
        const status = error.message.includes('not found') ? 404 :
                       error.message.includes('timeout') ? 408 : 500;
        res.writeHead(status, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          error: error.message,
          selector: error.message.includes('Widget') ? undefined : undefined
        }));
      }
      return;
    }

    // GET /android/session/{id}/screenshot
    if (req.method === 'GET' && parts.length === 4 && parts[3] === 'screenshot') {
      try {
        const session = androidSessions.get(sessionId);
        if (!session) {
          res.writeHead(404, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Android session not found' }));
          return;
        }

        // Parse query params for path and selector
        const urlParts = req.url.split('?');
        let options = {};
        if (urlParts[1]) {
          const params = new URLSearchParams(urlParts[1]);
          if (params.get('path')) options.path = params.get('path');
          if (params.get('selector')) options.selector = params.get('selector');
          if (params.get('format')) options.format = params.get('format'); // png, base64, json
        }

        // If selector provided, use element screenshot
        if (options.selector) {
          log('Android screenshot: element selector provided', options.selector);
          const result = await executeAndroidAction(sessionId, {
            type: 'elementScreenshot',
            selector: options.selector,
            path: options.path
          });

          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify(result));
          return;
        }

        // Regular full screenshot
        const buffer = await session.device.screenshot({
          path: options.path
        });

        if (options.path) {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ saved: true, path: options.path, size: buffer.length }));
        } else if (options.format === 'base64' || options.format === 'json') {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({
            screenshot: buffer.toString('base64'),
            size: buffer.length,
            format: 'base64'
          }));
        } else {
          res.writeHead(200, { 'Content-Type': 'image/png' });
          res.end(buffer);
        }
      } catch (error) {
        console.error('Android screenshot error:', error.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          error: error.message,
          hint: error.message.includes('screen') ? 'Wake device first' : undefined
        }));
      }
      return;
    }

    // POST /android/session/{id}/webview/connect
    if (req.method === 'POST' && parts.length === 5 && parts[3] === 'webview' && parts[4] === 'connect') {
      try {
        const options = await parseBody(req);
        const result = await executeAndroidAction(sessionId, {
          type: 'connectWebView',
          selector: options.selector,
          timeout: options.timeout
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error) {
        console.error('Android WebView connect error:', error.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: error.message }));
      }
      return;
    }

    // POST /android/session/{id}/browser/launch
    if (req.method === 'POST' && parts.length === 5 && parts[3] === 'browser' && parts[4] === 'launch') {
      try {
        const options = await parseBody(req);
        const result = await executeAndroidAction(sessionId, {
          type: 'launchBrowser',
          url: options.url,
          pkg: options.pkg,
          options: options.options
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error) {
        console.error('Android browser launch error:', error.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: error.message }));
      }
      return;
    }

    // POST /android/session/{id}/launch - Launch an app by package name
    if (req.method === 'POST' && parts.length === 4 && parts[3] === 'launch') {
      try {
        const options = await parseBody(req);
        const result = await executeAndroidAction(sessionId, {
          type: 'launchApp',
          pkg: options.pkg || options.package,
          activity: options.activity,
          delay: options.delay
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error) {
        console.error('Android launch app error:', error.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: error.message }));
      }
      return;
    }

    // POST /android/session/{id}/install
    if (req.method === 'POST' && parts.length === 4 && parts[3] === 'install') {
      try {
        const options = await parseBody(req);
        const result = await executeAndroidAction(sessionId, {
          type: 'install',
          apk: options.apk,
          pkg: options.pkg,
          args: options.args,
          verify: options.verify !== false // Default to true
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error) {
        console.error('Android install error:', error.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: error.message }));
      }
      return;
    }

    // POST /android/session/{id}/uninstall - Uninstall an app
    if (req.method === 'POST' && parts.length === 4 && parts[3] === 'uninstall') {
      try {
        const options = await parseBody(req);
        if (!options.pkg && !options.package) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Package name (pkg) is required' }));
          return;
        }
        const result = await executeAndroidAction(sessionId, {
          type: 'uninstall',
          pkg: options.pkg || options.package,
          keepData: options.keepData || false
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error) {
        console.error('Android uninstall error:', error.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: error.message }));
      }
      return;
    }

    // POST /android/session/{id}/clear-data - Clear app data
    if (req.method === 'POST' && parts.length === 4 && parts[3] === 'clear-data') {
      try {
        const options = await parseBody(req);
        if (!options.pkg && !options.package) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Package name (pkg) is required' }));
          return;
        }

        // Optionally force stop the app first
        if (options.forceStop !== false) {
          await executeAndroidAction(sessionId, {
            type: 'forceStop',
            pkg: options.pkg || options.package
          });
        }

        const result = await executeAndroidAction(sessionId, {
          type: 'clearData',
          pkg: options.pkg || options.package
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error) {
        console.error('Android clear data error:', error.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: error.message }));
      }
      return;
    }

    // POST /android/session/{id}/force-stop - Force stop an app
    if (req.method === 'POST' && parts.length === 4 && parts[3] === 'force-stop') {
      try {
        const options = await parseBody(req);
        if (!options.pkg && !options.package) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Package name (pkg) is required' }));
          return;
        }
        const result = await executeAndroidAction(sessionId, {
          type: 'forceStop',
          pkg: options.pkg || options.package
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error) {
        console.error('Android force stop error:', error.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: error.message }));
      }
      return;
    }

    // POST /android/session/{id}/shell
    if (req.method === 'POST' && parts.length === 4 && parts[3] === 'shell') {
      try {
        const options = await parseBody(req);
        const result = await executeAndroidAction(sessionId, {
          type: 'shell',
          command: options.command
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error) {
        console.error('Android shell error:', error.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: error.message }));
      }
      return;
    }

    // POST /android/session/{id}/push
    if (req.method === 'POST' && parts.length === 4 && parts[3] === 'push') {
      try {
        const options = await parseBody(req);
        const result = await executeAndroidAction(sessionId, {
          type: 'push',
          file: options.file,
          path: options.path,
          mode: options.mode
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error) {
        console.error('Android push error:', error.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: error.message }));
      }
      return;
    }

    // POST /android/session/{id}/baseline - Capture baseline screenshot
    if (req.method === 'POST' && parts.length === 4 && parts[3] === 'baseline') {
      try {
        const options = await parseBody(req);
        const result = await executeAndroidAction(sessionId, {
          type: 'captureBaseline',
          name: options.name,
          path: options.path,
          selector: options.selector,
          metadata: options.metadata
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error) {
        console.error('Android baseline capture error:', error.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: error.message }));
      }
      return;
    }

    // GET /android/session/{id}/baselines - List all baselines
    if (req.method === 'GET' && parts.length === 4 && parts[3] === 'baselines') {
      try {
        const result = await executeAndroidAction(sessionId, {
          type: 'listBaselines'
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error) {
        console.error('Android list baselines error:', error.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: error.message }));
      }
      return;
    }

    // DELETE /android/session/{id}/baseline/{name} - Delete a baseline
    if (req.method === 'DELETE' && parts.length === 5 && parts[3] === 'baseline') {
      try {
        const baselineName = decodeURIComponent(parts[4]);
        const result = await executeAndroidAction(sessionId, {
          type: 'deleteBaseline',
          name: baselineName
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error) {
        console.error('Android delete baseline error:', error.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: error.message }));
      }
      return;
    }

    // POST /android/session/{id}/compare - Compare screenshot with baseline
    if (req.method === 'POST' && parts.length === 4 && parts[3] === 'compare') {
      try {
        const options = await parseBody(req);

        const actionType = options.selector ? 'compareElement' : 'compareScreenshot';

        const result = await executeAndroidAction(sessionId, {
          type: actionType,
          baseline: options.baseline,
          baselineName: options.baselineName,
          selector: options.selector,
          threshold: options.threshold,
          includeScreenshots: options.includeScreenshots,
          saveName: options.saveName
        });

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error) {
        console.error('Android compare error:', error.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: error.message }));
      }
      return;
    }

    // POST /android/session/{id}/diff-report - Generate visual diff report
    if (req.method === 'POST' && parts.length === 4 && parts[3] === 'diff-report') {
      try {
        const options = await parseBody(req);
        const result = await executeAndroidAction(sessionId, {
          type: 'generateDiffReport',
          baseline: options.baseline,
          comparisons: options.comparisons,
          threshold: options.threshold,
          format: options.format,
          path: options.path
        });

        if (options.format === 'html' && result.report?.html && !options.json) {
          res.writeHead(200, { 'Content-Type': 'text/html' });
          res.end(result.report.html);
        } else {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify(result));
        }
      } catch (error) {
        console.error('Android diff report error:', error.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: error.message }));
      }
      return;
    }

    // POST /android/session/{id}/wait-for - Wait for condition
    if (req.method === 'POST' && parts.length === 4 && parts[3] === 'wait-for') {
      try {
        const options = await parseBody(req);
        const result = await executeAndroidAction(sessionId, {
          type: 'waitFor',
          selector: options.selector,
          text: options.text,
          textGone: options.textGone,
          activity: options.activity,
          pkg: options.pkg,
          state: options.state,
          timeout: options.timeout,
          interval: options.interval
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error) {
        console.error('Android wait-for error:', error.message);
        const status = error.message.includes('timed out') ? 408 : 500;
        res.writeHead(status, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          error: error.message,
          timedOut: error.message.includes('timed out')
        }));
      }
      return;
    }

    // POST /android/session/{id}/assert - Assert element properties
    if (req.method === 'POST' && parts.length === 4 && parts[3] === 'assert') {
      try {
        const options = await parseBody(req);
        const result = await executeAndroidAction(sessionId, {
          type: 'assert',
          selector: options.selector,
          assertions: options.assertions || options,
          strict: options.strict
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error) {
        console.error('Android assert error:', error.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          error: error.message,
          assertions: error.assertions
        }));
      }
      return;
    }

    // POST /android/session/{id}/test - Run a test script
    if (req.method === 'POST' && parts.length === 4 && parts[3] === 'test') {
      try {
        const options = await parseBody(req);
        const result = await executeAndroidAction(sessionId, {
          type: 'runTest',
          name: options.name,
          steps: options.steps,
          stopOnFailure: options.stopOnFailure,
          stepDelay: options.stepDelay
        });

        // Return 200 even for failed tests (it's not an error, just a failed test)
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error) {
        console.error('Android test error:', error.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: error.message }));
      }
      return;
    }

    // POST /android/session/{id}/commit
    if (req.method === 'POST' && parts.length === 4 && parts[3] === 'commit') {
      try {
        const session = androidSessions.get(sessionId);
        if (!session) {
          res.writeHead(404, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Android session not found' }));
          return;
        }

        const options = await parseBody(req);

        // Auto-generate title
        const date = new Date(session.createdAt);
        const dateStr = date.toISOString().split('T')[0];
        const timeStr = date.toTimeString().slice(0, 5).replace(':', '');
        const title = options.title || `Android Session ${dateStr} ${timeStr} - ${session.model}`;

        const recording = {
          title,
          device: {
            serial: session.serial,
            model: session.model,
            screen: session.screen
          },
          steps: session.steps,
          metadata: {
            ...options.metadata,
            recordedAt: new Date(session.createdAt).toISOString(),
            duration: Date.now() - session.createdAt
          }
        };

        await closeAndroidSession(sessionId);

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(recording));
      } catch (error) {
        console.error('Android commit error:', error.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: error.message }));
      }
      return;
    }

    // GET /android/session/{id}/state - Enhanced app state
    if ((req.method === 'GET' || req.method === 'POST') && parts.length === 4 && parts[3].startsWith('state')) {
      try {
        const session = androidSessions.get(sessionId);
        if (!session) {
          res.writeHead(404, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Android session not found' }));
          return;
        }

        // Parse query params for additional info
        const urlParts = req.url.split('?');
        let options = {};
        if (urlParts[1]) {
          const params = new URLSearchParams(urlParts[1]);
          if (params.get('ui')) options.includeUI = params.get('ui') === 'true';
          if (params.get('processes')) options.includeProcesses = params.get('processes') === 'true';
        }

        // For POST, parse body
        if (req.method === 'POST') {
          const body = await parseBody(req);
          if (body.includeUI !== undefined) options.includeUI = body.includeUI;
          if (body.includeProcesses !== undefined) options.includeProcesses = body.includeProcesses;
        }

        const result = {
          sessionId,
          device: {
            serial: session.serial,
            model: session.model,
            screen: session.screen
          },
          createdAt: new Date(session.createdAt).toISOString(),
          lastActivity: new Date(session.lastActivity).toISOString(),
          stepsRecorded: session.steps.length,
          webViews: session.webViews.size,
          browserLaunched: session.browserContext !== null
        };

        // Get current activity
        try {
          const activityOutput = await session.device.shell('dumpsys activity activities | grep mResumedActivity');
          const match = activityOutput.toString().match(/u0 ([^\s]+)/);
          result.currentActivity = match ? match[1] : null;
        } catch (e) {
          result.currentActivity = null;
        }

        // Get current focused window
        try {
          const windowOutput = await session.device.shell('dumpsys window windows | grep -E "mCurrentFocus|mFocusedApp"');
          result.focusedWindow = windowOutput.toString().trim();
        } catch (e) {
          result.focusedWindow = null;
        }

        // Optionally include UI hierarchy dump
        if (options.includeUI) {
          try {
            const uiOutput = await session.device.shell('uiautomator dump /dev/tty');
            result.uiHierarchy = uiOutput.toString();
          } catch (e) {
            result.uiHierarchy = null;
            result.uiError = e.message;
          }
        }

        // Optionally include running processes
        if (options.includeProcesses) {
          try {
            const psOutput = await session.device.shell('ps -A | head -50');
            result.processes = psOutput.toString();
          } catch (e) {
            result.processes = null;
          }
        }

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error) {
        console.error('Android state error:', error.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: error.message }));
      }
      return;
    }

    // GET /android/session/{id}/packages - List installed packages
    if (req.method === 'GET' && parts.length === 4 && parts[3] === 'packages') {
      try {
        const session = androidSessions.get(sessionId);
        if (!session) {
          res.writeHead(404, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Android session not found' }));
          return;
        }

        // Parse query params
        const urlParts = req.url.split('?');
        let options = {};
        if (urlParts[1]) {
          const params = new URLSearchParams(urlParts[1]);
          if (params.get('filter')) options.filter = params.get('filter');
          if (params.get('system')) options.includeSystem = params.get('system') === 'true';
          if (params.get('versions')) options.includeVersions = params.get('versions') !== 'false';
          if (params.get('limit')) options.limit = parseInt(params.get('limit'));
        }

        const result = await executeAndroidAction(sessionId, {
          type: 'listPackages',
          ...options
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error) {
        console.error('Android packages error:', error.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: error.message }));
      }
      return;
    }

    // GET /android/session/{id}/crash - Check for crashes
    if ((req.method === 'GET' || req.method === 'POST') && parts.length === 4 && parts[3] === 'crash') {
      try {
        let options = {};

        if (req.method === 'GET') {
          const urlParts = req.url.split('?');
          if (urlParts[1]) {
            const params = new URLSearchParams(urlParts[1]);
            if (params.get('pkg')) options.pkg = params.get('pkg');
          }
        } else {
          options = await parseBody(req);
        }

        const result = await executeAndroidAction(sessionId, {
          type: 'checkCrash',
          pkg: options.pkg
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error) {
        console.error('Android crash check error:', error.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: error.message }));
      }
      return;
    }

    // GET /android/session/{id}/perf - Get performance metrics
    if ((req.method === 'GET' || req.method === 'POST') && parts.length === 4 && parts[3] === 'perf') {
      try {
        let options = {};

        if (req.method === 'GET') {
          const urlParts = req.url.split('?');
          if (urlParts[1]) {
            const params = new URLSearchParams(urlParts[1]);
            if (params.get('pkg')) options.pkg = params.get('pkg');
          }
        } else {
          options = await parseBody(req);
        }

        const result = await executeAndroidAction(sessionId, {
          type: 'perfMetrics',
          pkg: options.pkg
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error) {
        console.error('Android perf error:', error.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: error.message }));
      }
      return;
    }

    // POST /android/session/{id}/launch-time - Measure app launch time
    if (req.method === 'POST' && parts.length === 4 && parts[3] === 'launch-time') {
      try {
        const options = await parseBody(req);
        const result = await executeAndroidAction(sessionId, {
          type: 'measureLaunchTime',
          pkg: options.pkg,
          activity: options.activity
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error) {
        console.error('Android launch time error:', error.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: error.message }));
      }
      return;
    }

    // GET /android/session/{id}/logcat - Get logcat output
    if ((req.method === 'GET' || req.method === 'POST') && parts.length === 4 && parts[3] === 'logcat') {
      try {
        let options = {};

        if (req.method === 'GET') {
          const urlParts = req.url.split('?');
          if (urlParts[1]) {
            const params = new URLSearchParams(urlParts[1]);
            if (params.get('pkg')) options.pkg = params.get('pkg');
            if (params.get('lines')) options.lines = parseInt(params.get('lines'));
            if (params.get('level')) options.level = params.get('level');
            if (params.get('filter')) options.filter = params.get('filter');
          }
        } else {
          options = await parseBody(req);
        }

        const result = await executeAndroidAction(sessionId, {
          type: 'getLogcat',
          ...options
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error) {
        console.error('Android logcat error:', error.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: error.message }));
      }
      return;
    }

    // DELETE /android/session/{id}/logcat - Clear logcat
    if (req.method === 'DELETE' && parts.length === 4 && parts[3] === 'logcat') {
      try {
        const result = await executeAndroidAction(sessionId, {
          type: 'clearLogcat'
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error) {
        console.error('Android clear logcat error:', error.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: error.message }));
      }
      return;
    }

    // DELETE /android/session/{id}
    if (req.method === 'DELETE' && parts.length === 3) {
      try {
        await closeAndroidSession(sessionId);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ success: true }));
      } catch (error) {
        console.error('Android session close error:', error.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: error.message }));
      }
      return;
    }
  }

  if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      status: 'ok',
      browser: browser ? 'running' : 'not started',
      androidSessions: androidSessions.size
    }));
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Not found' }));
});

// Graceful shutdown
// Graceful shutdown - close all sessions
async function shutdown() {
  console.log('\nShutting down...');

  // Close all Android sessions
  for (const [sessionId] of androidSessions) {
    try {
      await closeAndroidSession(sessionId);
    } catch (e) {
      console.error(`Error closing Android session ${sessionId}: ${e.message}`);
    }
  }

  // Close browser sessions
  for (const [sessionId] of sessions) {
    try {
      await closeSession(sessionId);
    } catch (e) {
      console.error(`Error closing session ${sessionId}: ${e.message}`);
    }
  }

  // Close browser
  if (browser) {
    await browser.close();
  }

  process.exit(0);
}

// Handle uncaught errors gracefully (especially ADB connection errors)
process.on('uncaughtException', (error) => {
  console.error('Uncaught exception:', error.message);
  // Don't exit for recoverable errors like ADB connection issues
  if (error.code === 'ECONNREFUSED' && error.port === 5037) {
    console.error('ADB connection refused - make sure "adb start-server" is running');
    return; // Don't crash
  }
  // For other errors, log but try to continue
  console.error('Stack:', error.stack);
});

process.on('unhandledRejection', (reason, promise) => {
  console.error('Unhandled rejection:', reason);
});

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

server.listen(PORT, () => {
  log(`Playwright service running on http://localhost:${PORT}`);
  log('Endpoints:');
  log('  POST /fetch    - Fetch and render a page');
  log('  POST /probe    - Probe page load performance metrics');
  log('  POST /replay   - Replay a Chrome DevTools Recorder JSON recording');
  log('  GET  /health   - Health check');
  log('');
  log('Android Endpoints:');
  log('  GET  /android/devices              - List connected Android devices');
  log('  POST /android/session/create       - Create Android session');
  log('  POST /android/session/{id}/action  - Execute Android action');
  log('  GET  /android/session/{id}/screenshot - Capture screenshot (supports ?selector=, ?format=base64)');
  log('  POST /android/session/{id}/launch  - Launch app by package name');
  log('  POST /android/session/{id}/install - Install APK');
  log('  POST /android/session/{id}/uninstall - Uninstall app by package name');
  log('  POST /android/session/{id}/clear-data - Clear app data');
  log('  POST /android/session/{id}/force-stop - Force stop an app');
  log('  GET  /android/session/{id}/packages - List installed packages');
  log('  GET  /android/session/{id}/crash   - Check for crashes and ANRs');
  log('  GET  /android/session/{id}/logcat  - Get logcat output');
  log('  DELETE /android/session/{id}/logcat - Clear logcat buffer');
  log('  POST /android/session/{id}/wait-for - Wait for element/text/activity condition');
  log('  POST /android/session/{id}/assert  - Assert element properties');
  log('  POST /android/session/{id}/test    - Run a test script with pass/fail results');
  log('  POST /android/session/{id}/baseline - Capture baseline screenshot');
  log('  GET  /android/session/{id}/baselines - List all baselines');
  log('  DELETE /android/session/{id}/baseline/{name} - Delete a baseline');
  log('  POST /android/session/{id}/compare - Compare screenshot with baseline');
  log('  POST /android/session/{id}/diff-report - Generate visual diff report');
  log('  POST /android/session/{id}/commit  - Export recording');
  log('  POST /android/replay               - Replay Android recording');
});
