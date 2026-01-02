# Bug: Parent Mode Extraction Returns False for Valid XPaths

## Status
- [x] Confirmed
- [ ] Fixed

## Description
When using `ar-crawl extract` with `--parent` and `--fields` to extract repeating items (like links, products, articles), the extraction returns `false` for fields even when the XPath expressions should match valid elements in the HTML.

## Reproduction

```bash
# Crawl a simple page
ar-crawl crawl https://example.com -o example.json

# Try to extract links using parent mode
ar-crawl extract example.json \
  --parent "//a" \
  --fields '{"url": "./@href", "text": "./text()"}' \
  --format json
```

## Output Observed

```json
{
  "data": [
    {
      "source_url": "https://example.com",
      "text": false,
      "url": false
    }
  ],
  "metadata": {
    "record_count": 1,
    "source": "example.json",
    "xpath_map": {
      "fields": {
        "text": "./text()",
        "url": "./@href"
      },
      "parent": "//a"
    }
  },
  "timestamp": "2026-01-02T09:55:04Z"
}
```

## Expected Output

The page contains: `<a href="https://iana.org/domains/example">Learn more</a>`

Expected extraction:
```json
{
  "data": [
    {
      "source_url": "https://example.com",
      "text": "Learn more",
      "url": "https://iana.org/domains/example"
    }
  ],
  ...
}
```

## Workaround

Using `--xpath-map` instead of `--parent` mode works correctly:

```bash
ar-crawl extract example.json \
  --xpath-map '{"link_url": "//a/@href", "link_text": "//a"}' \
  --format json
```

Output:
```json
{
  "data": [
    {
      "link_text": "Learn more",
      "link_url": "https://iana.org/domains/example",
      ...
    }
  ]
}
```

## Impact

The `--parent` mode is specifically designed for extracting repeating items (like multiple product cards, article listings, file download links). This is a **critical feature** for the file-downloader user persona who needs to extract multiple downloadable files from a page.

Without working parent mode extraction, users cannot:
- Extract multiple file links with their metadata (title, size, type)
- Process repeating HTML patterns efficiently
- Use the documented pattern from user workflows

## Use Case: File Download List

A file-downloader user wants to extract all downloadable files with their titles:

```html
<div class="file-list">
  <div class="file-item">
    <a href="/downloads/report-2024.pdf">Annual Report 2024</a>
    <span class="file-size">2.3 MB</span>
  </div>
  <div class="file-item">
    <a href="/downloads/budget-2024.pdf">Budget Report 2024</a>
    <span class="file-size">1.8 MB</span>
  </div>
</div>
```

**Expected command**:
```bash
ar-crawl extract page.json \
  --parent "//div[@class='file-item']" \
  --fields '{"url": ".//a/@href", "title": ".//a/text()", "size": ".//span[@class=\"file-size\"]"}' \
  --format json
```

**Expected result**: A list of objects, one for each file, with url, title, and size.

**Actual result**: Returns false for all fields.

## Investigation Needed

- Is the relative XPath context (`.//` vs `//`) being handled correctly?
- Are text nodes (`./@href`, `./text()`) being extracted properly in parent mode?
- Does parent mode work when there are multiple matching parent elements?
