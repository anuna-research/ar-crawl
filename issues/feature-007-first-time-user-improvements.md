# Feature 007: First-Time User Experience Improvements

## Status
🟢 Enhancement

## Category
Documentation / UX / Onboarding

## Description
After testing ar-crawl as a first-time user, here are several improvements that would enhance the initial experience and reduce friction.

## What Works Well ✅

1. **Excellent README** - Comprehensive, well-structured with clear examples
2. **Binary distribution** - Single binary with install script is ideal for new users
3. **No API keys required** - Direct crawling works out of the box
4. **Clear help messages** - Command help is detailed and includes examples
5. **Sample command workflow** - The `sample` → `extract` workflow is brilliant for XPath discovery
6. **Probe command** - Excellent tool for understanding page characteristics before crawling
7. **Multiple output formats** - JSON, CSV, SQLite gives users flexibility

## Suggested Improvements

### 1. Interactive Quick Start Guide
**Issue:** Users might not know where to start even with good docs.

**Solution:** Add an interactive first-run experience:
```bash
$ ar-crawl

Welcome to AR-Crawl! 🕷️

This appears to be your first time using ar-crawl.
Would you like to run a quick tutorial? (y/n)

> y

Great! Let's crawl a test page and extract some data.

Step 1: Crawling a single page
Running: ar-crawl crawl https://httpbin.org/html

[Shows output]

Step 2: Exploring the HTML
Running: ar-crawl sample results.json

[Shows sample]

Step 3: Extracting data with XPath
Running: ar-crawl extract results.json --xpath-map '{"title": "//h1/text()"}'

[Shows extracted data]

✅ Tutorial complete! Try: ar-crawl --examples for more examples
```

### 2. Better Error Messages for Common Mistakes

**Current:**
```
Error loading file: open-input-file: cannot open input file
  path: /home/user/results.json
  system error: No such file or directory; errno=2
```

**Suggested:**
```
Error: Could not find file 'results.json'

Did you mean to:
  • Create it first with: ar-crawl crawl <url> -o results.json
  • Check the path: /home/user/results.json
  • List available files: ls *.json
```

### 3. Examples Command

Add `ar-crawl --examples` or `ar-crawl examples` to show common use cases:

```bash
$ ar-crawl examples

Common AR-Crawl Examples
========================

1. Crawl a single page
   ar-crawl crawl https://example.com -o page.json

2. Crawl a website (max 50 pages)
   ar-crawl crawl-site https://example.com --max-pages 50 -o site.json

3. Extract structured data
   ar-crawl extract site.json --xpath-map '{"title": "//h1", "links": "//a/@href"}'

4. Extract repeating items (e.g., products)
   ar-crawl extract site.json --parent "//div[@class='product']" \
     --fields '{"name": ".//h2", "price": ".//span[@class=\"price\"]"}'

5. Save to SQLite for analysis
   ar-crawl crawl-site https://blog.example.com --output posts.db --format sqlite

6. Probe a page before crawling
   ar-crawl probe https://spa-site.com

Run 'ar-crawl help <command>' for detailed help on any command.
```

### 4. Validation and Helpful Suggestions

**XPath validation:**
```bash
$ ar-crawl extract results.json --xpath-map '{"title": "//h1}'

Error: Invalid JSON in --xpath-map: missing closing quote

Tip: JSON requires double quotes. Try:
  --xpath-map '{"title": "//h1/text()}"'
```

**URL validation:**
```bash
$ ar-crawl crawl example.com

Error: Invalid URL 'example.com'

Did you mean: https://example.com?

Tip: URLs must include the protocol (http:// or https://)
```

### 5. Progress Indication for Long Operations

For operations that take time, show a spinner or progress:
```bash
$ ar-crawl crawl-site https://large-site.com --max-pages 100

⠋ Crawling page 15/100 (https://large-site.com/page15)
  Queue: 85 URLs | Discovered: 247 | Speed: 2.3 pages/sec

[Instead of just static "[15/100] Crawling: ..."]
```

### 6. Config Setup Wizard

```bash
$ ar-crawl config setup

AR-Crawl Configuration Setup
=============================

Let's set up your API keys for external crawling services.
Press Enter to skip any service you don't need.

Note: The 'direct' service works without any API keys!

FireCrawl API Key: [press Enter to skip]
ScrapingBee API Key: [press Enter to skip]
Browserless API Key: [press Enter to skip]

Configuration saved to ~/.config/ar-crawl/config.json

Test your setup with: ar-crawl test
```

### 7. Shell Completion

Generate shell completion scripts:
```bash
$ ar-crawl completion bash > ~/.bash_completion.d/ar-crawl
$ ar-crawl completion zsh > ~/.zsh/completion/_ar-crawl
```

Enables tab-completion:
```bash
$ ar-crawl cr[TAB]
crawl       crawl-site
```

### 8. Common Workflows in README

Add a "Common Workflows" section showing end-to-end examples:

**Workflow 1: E-commerce Product Scraping**
```bash
# 1. Probe the site to check if it needs JS rendering
ar-crawl probe https://shop.example.com/products

# 2. Crawl product pages
ar-crawl crawl-site https://shop.example.com/products \
  --url-pattern ".*/product/.*" --max-pages 100 -o products.json

# 3. Explore HTML to find XPaths
ar-crawl sample products.json

# 4. Extract product data
ar-crawl extract products.json \
  --parent "//div[@class='product-card']" \
  --fields '{"name": ".//h2", "price": ".//span[@class=\"price\"]", "url": ".//a/@href"}' \
  --format csv -o products.csv

# 5. Open in spreadsheet
xdg-open products.csv
```

### 9. Quick Start Template Files

Ship example files in `~/.local/share/ar-crawl/examples/`:
- `example-crawl.json` - Sample crawl output
- `example-xpath-map.json` - Example XPath configurations
- `example-config.json` - Annotated config file

Users can reference these:
```bash
$ ar-crawl extract ~/.local/share/ar-crawl/examples/example-crawl.json \
    --xpath-map @~/.local/share/ar-crawl/examples/product-xpath-map.json
```

### 10. Version Check and Update Notification

```bash
$ ar-crawl crawl https://example.com

⚠ Update available: v1.2.0 → v1.3.0
  Run: curl -fsSL https://files.anuna.io/ar-crawl/latest/install.sh | bash

[continues with crawl...]
```

## Priority
Low-Medium - These are quality-of-life improvements that would make the tool more approachable for new users.

## Implementation Order
1. Better error messages (highest impact, lowest effort)
2. `--examples` command (high impact, low effort)
3. Shell completion (high impact for power users)
4. Quick start guide (medium effort, high impact for new users)
5. Config wizard (low priority, can be done later)
6. Update notifications (nice to have)

## Related Files
- `src/cli.rkt` - Command implementation
- `README.md` - Documentation
- `dist/install.sh` - Installation script

## Notes
These improvements focus on the "first 5 minutes" user experience - the most critical time for user adoption.
