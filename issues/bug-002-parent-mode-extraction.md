# Bug: Parent Mode Extraction Returns False for Valid XPaths

## Status
- [x] Confirmed
- [x] Fixed

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

## Root Cause

The issue was in the `extract-items` function in `src/html-extractor.rkt`. When applying relative XPath expressions to parent nodes, the code was wrapping each parent node in a `*TOP*` wrapper:

```racket
[nodes (xpath-fn (list '*TOP* parent))]
```

This caused issues with current-node XPath queries:
- `./@href` (attribute of current node) looked for attributes on `*TOP*` instead of the parent element
- `./text()` (text of current node) looked for text of `*TOP*` instead of the parent element
- Descendant queries like `.//tag` worked because they search descendants of `*TOP*`, which includes the parent

## Fix

Changed line 128 in `src/html-extractor.rkt` to apply XPath directly to the parent node without the `*TOP*` wrapper:

```racket
[nodes (xpath-fn parent)]
```

Also updated the value extraction logic to properly handle:
- Text strings (returned by `./text()`)
- Attribute nodes (returned by `./@href`) - format: `(attr-name "value")`
- Element nodes (returned by `.//tag`) - format: `(tag ... content)`

The fix correctly distinguishes between these node types by checking:
1. If it's a plain string → use directly
2. If it's a 2-element list `(symbol string)` → extract attribute value
3. Otherwise → extract text using `sxml->text`

## Verification

All existing tests pass, and the fix now correctly handles:
- Current node queries: `./@href`, `./text()`
- Descendant queries: `.//tag`, `.//tag/@attr`
- Both work correctly in parent mode extraction
