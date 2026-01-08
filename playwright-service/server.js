const http = require('http');
const { chromium } = require('playwright-extra');
const StealthPlugin = require('puppeteer-extra-plugin-stealth');
const crypto = require('crypto');

// Session storage
const sessions = new Map();

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

  if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', browser: browser ? 'running' : 'not started' }));
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Not found' }));
});

// Graceful shutdown
process.on('SIGINT', async () => {
  console.log('\nShutting down...');
  if (browser) {
    await browser.close();
  }
  process.exit(0);
});

process.on('SIGTERM', async () => {
  if (browser) {
    await browser.close();
  }
  process.exit(0);
});

server.listen(PORT, () => {
  log(`Playwright service running on http://localhost:${PORT}`);
  log('Endpoints:');
  log('  POST /fetch    - Fetch and render a page');
  log('  POST /probe    - Probe page load performance metrics');
  log('  POST /replay   - Replay a Chrome DevTools Recorder JSON recording');
  log('  GET  /health   - Health check');
});
