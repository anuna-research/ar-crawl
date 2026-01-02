# File-Downloader User Testing Notes

**Date**: 2026-01-02
**User**: Alex Chen (file-downloader persona)
**Goal**: Download all files of a certain type from web pages

---

## Testing Summary

I tested ar-crawl to see if it meets my needs for downloading PDFs, images, and other files from websites. While the tool shows promise, I encountered several significant issues that prevent it from being a complete solution for file downloading.

## What Works ✓

1. **Basic Crawling**: Successfully crawls pages and saves HTML content
2. **XPath Extraction**: Can extract URLs using `--xpath-map` with XPath expressions
3. **JSON Output**: Structured JSON output makes it easy to process results programmatically
4. **Multiple Output Formats**: Supports JSON, CSV, SQLite for different workflows

## Critical Issues Found ✗

### 1. Relative URLs Not Resolved
**Impact**: HIGH - Blocking issue for downloads

When extracting image or file URLs, ar-crawl returns them as-is from the HTML:
- `/WAI/WCAG22/quickref/img/w3c.svg` (relative path)
- `//www.w3.org/path/file.jpg` (protocol-relative)

These can't be downloaded directly with wget/curl without manual URL resolution.

**Issue filed**: `feature-003-url-resolution.md`

### 2. Parent Mode Extraction Broken
**Impact**: HIGH - Prevents extracting multiple files with metadata

The `--parent` mode with `--fields` returns `false` instead of extracting data:

```bash
ar-crawl extract page.json \
  --parent "//a" \
  --fields '{"url": "./@href", "text": "./text()"}' \
  --format json
# Returns: {"url": false, "text": false}
```

This is critical for extracting lists of downloadable files with their titles and metadata.

**Issue filed**: `bug-002-parent-mode-extraction.md`

### 3. No File Type Filtering
**Impact**: MEDIUM - Makes file discovery tedious

To find PDFs, I have to write XPath manually:
```bash
--xpath-map '{"pdf": "//a[contains(@href, \".pdf\")]/@href"}'
```

This is:
- Not beginner-friendly
- Doesn't handle edge cases (uppercase .PDF, query params)
- Requires XPath knowledge

Would prefer:
```bash
--file-type pdf  # or --extension pdf
```

**Issue filed**: `feature-004-file-type-filtering.md`

### 4. No Download Capability
**Impact**: MEDIUM - Requires external tools

After extracting URLs, I have to manually:
1. Parse JSON with jq
2. Loop through URLs
3. Download with wget/curl
4. Handle rate limiting, retries, progress tracking manually

**Issue filed**: `feature-005-direct-file-download.md`

---

## Attempted Workflows

### Workflow 1: Download All PDFs from a Page

**Goal**: Find and download all PDF files

```bash
# Step 1: Crawl the page
ar-crawl crawl https://site.com/resources -o page.json

# Step 2: Try to extract PDFs
ar-crawl extract page.json \
  --xpath-map '{"pdf_url": "//a[contains(@href, \".pdf\")]/@href"}' \
  --format json \
  -o pdfs.json

# Step 3: Check results
cat pdfs.json | jq '.data[].pdf_url'
# Result: Relative URLs like "/downloads/report.pdf"

# Step 4: BLOCKED - Can't download without resolving URLs first
# Would need to write a script to resolve URLs manually
```

**Status**: ❌ Blocked by relative URL issue

---

### Workflow 2: Download Images from Gallery

**Goal**: Download all images from a portfolio page

```bash
# Step 1: Crawl
ar-crawl crawl https://gallery.com -o gallery.json

# Step 2: Extract images
ar-crawl extract gallery.json \
  --xpath-map '{"images": "//img/@src"}' \
  --format json \
  -o images.json

# Step 3: Check results
cat images.json | jq '.data[].images'
# Result: Array of relative URLs
[
  "/images/photo1.jpg",
  "/images/photo2.jpg"
]

# Step 4: BLOCKED - Same relative URL problem
```

**Status**: ❌ Blocked by relative URL issue

---

### Workflow 3: Extract File List with Metadata

**Goal**: Get list of downloadable files with titles and sizes

```bash
# Assuming HTML like:
# <div class="file-item">
#   <a href="/downloads/report.pdf">Annual Report</a>
#   <span class="size">2.3 MB</span>
# </div>

ar-crawl extract page.json \
  --parent "//div[@class='file-item']" \
  --fields '{"url": ".//a/@href", "title": ".//a/text()", "size": ".//span/text()"}' \
  --format json

# Result: All fields return false
{"url": false, "title": false, "size": false}
```

**Status**: ❌ Blocked by parent mode bug

---

## What I Need

As a file-downloader user, here's what would make ar-crawl perfect for my use case:

### Must-Have (Blocking)
1. ✅ **Absolute URL resolution** - Convert relative URLs to downloadable absolute URLs
2. ✅ **Fix parent mode extraction** - So I can extract multiple files with metadata

### High Priority
3. ⏳ **Simple file type filtering** - `--file-type pdf` instead of complex XPath
4. ⏳ **Direct download capability** - `--download` flag to download files automatically

### Nice-to-Have
5. ⏳ Progress tracking for downloads
6. ⏳ Deduplication (skip already downloaded files)
7. ⏳ Rate limiting for respectful crawling
8. ⏳ Retry logic for failed downloads

---

## Workarounds Used

Until these issues are fixed, here are workarounds:

### Workaround 1: Manual URL Resolution

```bash
# Extract URLs
ar-crawl extract page.json --xpath-map '{"url": "//a/@href"}' -o links.json

# Resolve URLs with Python
python3 << 'EOF'
import json
from urllib.parse import urljoin

with open('links.json') as f:
    data = json.load(f)
    base_url = data['data'][0]['source_url']

    for item in data['data']:
        if item.get('url'):
            absolute = urljoin(base_url, item['url'])
            print(absolute)
EOF
```

### Workaround 2: Avoid Parent Mode

```bash
# Use --xpath-map instead of --parent mode
# Works but only gets first matching element, not all items
ar-crawl extract page.json \
  --xpath-map '{"file_url": "//a/@href", "file_name": "//a/text()"}' \
  --format json
```

---

## Conclusion

**Current State**: ar-crawl is a good web crawling and HTML extraction tool, but not yet optimized for the file-downloading use case.

**Recommendation**: Fix the two critical bugs (URL resolution + parent mode) to make it usable for file downloading. The feature requests (file-type filtering, direct downloads) would transform it into an excellent file downloading tool.

**Verdict**: ⭐⭐⭐☆☆ (3/5 stars)
- Great foundation
- Needs file-downloader-specific features to be truly useful for this use case
