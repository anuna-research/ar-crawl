const http = require('http');
const { chromium } = require('playwright-extra');
const StealthPlugin = require('puppeteer-extra-plugin-stealth');

// Add stealth plugin to avoid bot detection
chromium.use(StealthPlugin());

const PORT = process.env.PLAYWRIGHT_SERVICE_PORT || 3033;
const VERBOSE = process.env.VERBOSE === '1' || process.env.VERBOSE === 'true';

let browser = null;

// Logging helper - only logs if verbose mode is enabled
function log(...args) {
  if (VERBOSE) console.log(...args);
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
            await page.goto(step.url, { waitUntil: 'networkidle', timeout });
            stepResult.url = step.url;
            break;

          case 'click':
            const clickSelector = resolveSelector(step.selectors);
            await page.click(clickSelector, {
              button: step.button || 'left',
              clickCount: step.clickCount || 1,
              timeout
            });
            stepResult.selector = clickSelector;
            break;

          case 'doubleClick':
            const dblClickSelector = resolveSelector(step.selectors);
            await page.dblclick(dblClickSelector, { timeout });
            stepResult.selector = dblClickSelector;
            break;

          case 'change':
            const changeSelector = resolveSelector(step.selectors);
            await page.fill(changeSelector, step.value, { timeout });
            stepResult.selector = changeSelector;
            stepResult.value = step.value;
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
            const hoverSelector = resolveSelector(step.selectors);
            await page.hover(hoverSelector, { timeout });
            stepResult.selector = hoverSelector;
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
