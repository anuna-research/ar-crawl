const http = require('http');
const { chromium } = require('playwright');

const PORT = process.env.PLAYWRIGHT_SERVICE_PORT || 3033;

let browser = null;

async function initBrowser() {
  if (!browser) {
    browser = await chromium.launch({
      headless: true,
      args: ['--no-sandbox', '--disable-setuid-sandbox']
    });
    console.log('Browser initialized');
  }
  return browser;
}

async function fetchPage(options) {
  const {
    url,
    waitFor = 'networkidle',
    timeout = 30000,
    viewport = { width: 1920, height: 1080 },
    userAgent = 'AR-Crawl/1.0 Playwright (+https://github.com/anuna-research/ar-crawl)',
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

      console.log(`Fetching: ${options.url}`);
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
  console.log(`Playwright service running on http://localhost:${PORT}`);
  console.log('Endpoints:');
  console.log('  POST /fetch  - Fetch and render a page');
  console.log('  GET  /health - Health check');
});
