# Feature: Direct File Download Capability

## Status
- [x] Proposed
- [x] Implemented

## User Perspective
**As a file-downloader user**, after extracting file URLs, I want ar-crawl to download the files directly instead of having to pipe to wget/curl manually.

## Problem
Current workflow requires multiple steps and external tools:

```bash
# Step 1: Crawl
ar-crawl crawl https://site.com/resources -o page.json

# Step 2: Extract
ar-crawl extract page.json --file-type pdf -o pdfs.json

# Step 3: Download manually with external tools
cat pdfs.json | jq -r '.data[].url' | while read url; do
  wget "$url" -P downloads/
  sleep 1  # Rate limiting
done
```

This workflow has issues:
- Requires knowledge of `jq`, `wget`/`curl`, bash loops
- No progress tracking across all downloads
- No built-in rate limiting
- No automatic retry on failure
- No deduplication
- Manual organization of downloaded files

## Desired Behavior

Add a `--download` flag to the `extract` command (or a new `download` command):

### Option 1: Extend Extract Command

```bash
# Extract and download in one command
ar-crawl extract page.json \
  --file-type pdf \
  --download \
  --download-dir downloads/papers/ \
  --rate-limit 1000  # ms between downloads
```

### Option 2: New Download Command

```bash
# Extract first
ar-crawl extract page.json --file-type pdf -o pdfs.json

# Then download
ar-crawl download pdfs.json --output-dir downloads/papers/
```

### Option 3: All-in-One Workflow

```bash
# Crawl, extract, and download in one command
ar-crawl crawl-site https://research.edu/papers \
  --max-pages 50 \
  --collect-files pdf \
  --download \
  --download-dir papers/ \
  --format json
```

## Features to Include

### 1. Progress Tracking
```
Downloading files: 15/47 (32%)
Current: annual-report-2024.pdf (2.3 MB)
Completed: 35 MB / 120 MB estimated
Rate: 450 KB/s
ETA: 3m 15s
```

### 2. Smart Naming
```bash
# Preserve original filename
downloads/
  annual-report-2024.pdf
  budget-report-2024.pdf

# Or use metadata for naming
--name-from "title"  # Use extracted title field

downloads/
  Annual_Report_2024.pdf
  Budget_Report_2024.pdf
```

### 3. Deduplication
```bash
# Skip already downloaded files
--skip-existing

# Or check by content hash
--dedupe-by-hash
```

### 4. Rate Limiting
```bash
# Delay between downloads (milliseconds)
--rate-limit 1000  # 1 second between downloads

# Max concurrent downloads
--concurrent 3  # Download 3 files in parallel
```

### 5. Retry Logic
```bash
# Retry failed downloads
--retry 3  # Retry up to 3 times
--retry-delay 5000  # 5 seconds between retries
```

### 6. Size Filtering
```bash
# Only download files within size range
--min-size 100KB
--max-size 50MB
```

### 7. Resume Support
```bash
# Resume interrupted downloads
--resume

# Saves state to a download manifest:
downloads/.ar-crawl-manifest.json
```

### 8. Selective Download
```bash
# Interactive mode - prompt for each file
--interactive

# Pattern matching
--include-pattern "2024.*report"
--exclude-pattern "draft"
```

## Output Format

### JSON Output (with --format json)
```json
{
  "downloads": [
    {
      "url": "https://site.com/report-2024.pdf",
      "filename": "annual-report-2024.pdf",
      "local_path": "downloads/papers/annual-report-2024.pdf",
      "size_bytes": 2415901,
      "status": "completed",
      "checksum": "sha256:abc123...",
      "downloaded_at": "2026-01-02T10:15:23Z"
    },
    {
      "url": "https://site.com/budget.pdf",
      "filename": "budget-report-2024.pdf",
      "local_path": "downloads/papers/budget-report-2024.pdf",
      "size_bytes": 1887436,
      "status": "completed",
      "checksum": "sha256:def456...",
      "downloaded_at": "2026-01-02T10:15:27Z"
    }
  ],
  "summary": {
    "total_files": 47,
    "completed": 45,
    "failed": 2,
    "skipped": 0,
    "total_bytes": 125829401,
    "duration_seconds": 185.3
  },
  "errors": [
    {
      "url": "https://site.com/broken.pdf",
      "error": "404 Not Found",
      "retries": 3
    }
  ]
}
```

### SQLite Output (with --format sqlite)
```bash
ar-crawl extract page.json \
  --file-type pdf \
  --download \
  --format sqlite \
  -o downloads.db

# Query the database
sqlite3 downloads.db "
  SELECT filename, size_bytes, status
  FROM downloads
  WHERE status = 'completed'
"
```

## Use Cases

### Use Case 1: Research Paper Archive
```bash
# Download all PDFs from multiple pages
ar-crawl crawl-site https://research.edu/papers \
  --max-pages 100 \
  --url-pattern ".*/papers/.*" \
  --collect-files pdf \
  --download \
  --download-dir papers/2024/ \
  --skip-existing \
  --rate-limit 2000 \
  --format json \
  -o download-log.json

# Review results
cat download-log.json | jq '.summary'
```

### Use Case 2: Image Gallery Download
```bash
# Download all high-res images
ar-crawl crawl https://gallery.com/portfolio -o gallery.json

ar-crawl extract gallery.json \
  --xpath-map '{"image_url": "//img[@class=\"full-res\"]/@src"}' \
  --download \
  --download-dir images/ \
  --concurrent 5 \
  --min-size 500KB  # Skip thumbnails
```

### Use Case 3: Incremental Updates
```bash
# Daily download script
#!/bin/bash
DB_PATH="downloads/papers.db"

ar-crawl crawl-site https://site.com/new-papers \
  --max-pages 50 \
  --collect-files pdf \
  --download \
  --download-dir papers/ \
  --format sqlite \
  -o "$DB_PATH" \
  --skip-existing \
  --resume

# Track what's new
sqlite3 "$DB_PATH" "
  SELECT filename, downloaded_at
  FROM downloads
  WHERE downloaded_at > datetime('now', '-1 day')
"
```

### Use Case 4: Selective Download with Preview
```bash
# Review before downloading
ar-crawl extract page.json --file-type pdf -o pdfs.json
cat pdfs.json | jq '.data[] | "\(.link_text): \(.url) (\(.size))"'

# Download only specific ones
ar-crawl download pdfs.json \
  --include-pattern "annual.*2024" \
  --download-dir reports/
```

## Implementation Considerations

1. **HTTP Client**: Use existing crawling service infrastructure
2. **Streaming Downloads**: Stream large files to disk (don't load into memory)
3. **Parallel Downloads**: Use Racket threads or async I/O
4. **Progress UI**: Consider using a progress bar library
5. **Manifest File**: Track download state for resume capability
6. **Filename Sanitization**: Clean filenames (remove special chars, handle duplicates)
7. **Error Handling**: Gracefully handle network errors, 404s, timeouts

## Relationship to Other Features

Works best when combined with:
- **Feature-003 (URL Resolution)**: Ensures URLs are absolute and downloadable
- **Feature-004 (File Type Filtering)**: Easily select which files to download

## Impact

**Very high impact** for file-downloader user persona. This feature makes ar-crawl a complete solution for file downloading, not just URL extraction.

**Before** (requires external tools):
```bash
ar-crawl crawl site.com -o page.json
ar-crawl extract page.json --xpath-map '...' -o files.json
cat files.json | jq ... | while read url; do wget "$url"; done
```

**After** (one simple command):
```bash
ar-crawl crawl site.com \
  --collect-files pdf \
  --download \
  --download-dir papers/
```

## Priority

Consider implementing in phases:
1. **Phase 1**: Basic download support (`--download` flag with simple sequential downloads)
2. **Phase 2**: Add progress tracking, rate limiting, retry logic
3. **Phase 3**: Add advanced features (deduplication, resume, concurrent downloads)

## Implementation

**Status**: ✅ Implemented (Phase 1 + Phase 2)

Added `--download` flag to the `extract` command for direct file downloads with progress tracking and rate limiting.

### Changes Made

**File**: `src/cli.rkt`

1. **Download Helper Functions** (lines 509-625):
   - `sanitize-filename` - Cleans filenames for safe file system operations
   - `extract-filename-from-url` - Extracts filename from URL path
   - `download-file` - Downloads file using `net/url` library's `get-pure-port`
   - `download-files-from-results` - Batch downloads with progress tracking and rate limiting

2. **Command-Line Parameters** (lines 2330-2333):
   - `extract-download-param` - Enable download mode
   - `extract-download-dir-param` - Output directory (default: "downloads")
   - `extract-rate-limit-param` - Milliseconds between downloads (default: 0)
   - `extract-skip-existing-param` - Skip files that already exist

3. **Command-Line Flags** (lines 1461-1468):
   - `--download` - Enable file download mode
   - `--download-dir <dir>` - Specify download directory
   - `--rate-limit <ms>` - Rate limit between downloads
   - `--skip-existing` - Skip existing files

4. **Integration** (lines 764-774):
   - Downloads triggered after extraction when `--download` flag is present
   - Download statistics included in metadata output
   - Works seamlessly with `--file-type`, `--extension`, and `--resolve-urls`

### Features Implemented

- ✅ **Basic downloading**: Sequential HTTP downloads using `net/url`
- ✅ **Progress tracking**: Shows current/total progress for each file
- ✅ **Rate limiting**: Configurable delay between downloads
- ✅ **Skip existing**: Avoid re-downloading files that already exist
- ✅ **Error handling**: Gracefully handles download failures, continues with remaining files
- ✅ **Download stats**: Reports downloaded/skipped/failed counts
- ✅ **Filename extraction**: Automatically extracts filenames from URLs
- ✅ **Filename sanitization**: Removes unsafe characters from filenames

### Usage Examples

```bash
# Extract and download all PDFs
ar-crawl extract page.json --file-type pdf --resolve-urls --download -v

# Download to specific directory with rate limiting
ar-crawl extract page.json --file-type image --resolve-urls \
  --download --download-dir images/ --rate-limit 1000

# Skip existing files (useful for resuming interrupted downloads)
ar-crawl extract page.json --file-type pdf --resolve-urls \
  --download --download-dir pdfs/ --skip-existing -v
```

### Output Format

```json
{
  "data": [
    {
      "url": "https://example.com/file.pdf",
      "link_text": "Download File",
      "extension": "pdf",
      "source_url": "https://example.com"
    }
  ],
  "metadata": {
    "record_count": 1,
    "source": "page.json",
    "urls_resolved": true,
    "download_stats": {
      "downloaded": 1,
      "skipped": 0,
      "failed": 0,
      "total": 1
    }
  },
  "timestamp": "2026-01-02T11:08:05Z"
}
```

### Testing

Successfully tested with:
- ✅ Real HTTP downloads from W3C website (SVG images)
- ✅ Rate limiting (1000ms delays between downloads)
- ✅ Skip existing files functionality
- ✅ Download progress tracking with verbose output
- ✅ Error handling for failed downloads
- ✅ Download statistics in JSON output

### Example Test Run

```bash
$ racket src/cli.rkt extract test.json --file-type image --resolve-urls \
    --download --download-dir /tmp/downloads -v

Extracting from: test.json
File types: (image)
Extensions: (jpg jpeg png gif svg webp bmp ico)
Found 1 items to process
Resolving URLs to absolute form...
Extracted 2 records

Downloading files to: /tmp/downloads
[1/2] Downloading: w3c.svg
Downloading: https://www.w3.org/WAI/WCAG22/quickref/img/w3c.svg
[2/2] Downloading: wai.svg
Downloading: https://www.w3.org/WAI/WCAG22/quickref/img/wai.svg

Download complete:
  Downloaded: 2
  Skipped: 0
  Failed: 0
```

### Future Enhancements (Phase 3)

For future improvements, consider:
- Concurrent/parallel downloads
- Resume capability with manifest file
- Content-based deduplication
- File size limits and filtering
- Custom HTTP headers and authentication
- Retry logic with exponential backoff
