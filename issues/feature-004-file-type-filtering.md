# Feature: Simple File Type Filtering for Downloads

## Status
- [x] Proposed
- [ ] Implemented

## User Perspective
**As a file-downloader user**, I want a simple way to extract all files of a specific type (PDFs, images, videos, archives) without having to write complex XPath expressions.

## Problem
Currently, to extract files of a specific type, users must:
1. Know XPath syntax
2. Write expressions like `//a[contains(@href, ".pdf")]/@href`
3. Handle edge cases (uppercase extensions, query parameters, etc.)

This creates friction for users who just want to "download all PDFs from this page."

## Current Behavior

To extract PDF links:
```bash
ar-crawl extract page.json \
  --xpath-map '{"pdf_url": "//a[contains(@href, \".pdf\")]/@href"}' \
  --format json
```

**Problems with this approach**:
- Requires XPath knowledge
- `contains(@href, ".pdf")` might match `/path.pdf/page` (false positive)
- Doesn't handle `file.PDF` (uppercase)
- Doesn't handle `file.pdf?download=true` (query params)
- Doesn't distinguish between `<a href>` links and `<img src>` or other tags

## Desired Behavior

Add a `--file-type` or `--filter-by-extension` flag for common use cases:

### Option 1: File Type Presets

```bash
# Extract all PDF links
ar-crawl extract page.json --file-type pdf -o pdfs.json

# Extract all images
ar-crawl extract page.json --file-type image -o images.json

# Extract all videos
ar-crawl extract page.json --file-type video -o videos.json

# Extract all archives
ar-crawl extract page.json --file-type archive -o archives.json

# Extract multiple types
ar-crawl extract page.json --file-type pdf --file-type doc -o documents.json
```

### Option 2: Extension-Based Filtering

```bash
# Extract files with specific extensions
ar-crawl extract page.json --extension pdf --extension docx -o docs.json

# Works with any extension
ar-crawl extract page.json --extension zip --extension tar.gz -o archives.json
```

### Output Format

```json
{
  "data": [
    {
      "url": "/downloads/report-2024.pdf",
      "extension": "pdf",
      "link_text": "Annual Report 2024",
      "source_url": "https://example.com/downloads"
    },
    {
      "url": "/downloads/budget-2024.pdf",
      "extension": "pdf",
      "link_text": "Budget Report",
      "source_url": "https://example.com/downloads"
    }
  ],
  "metadata": {
    "file_types": ["pdf"],
    "total_files": 2
  }
}
```

## Suggested File Type Presets

```
pdf       → .pdf
image     → .jpg, .jpeg, .png, .gif, .svg, .webp, .bmp, .ico
video     → .mp4, .webm, .mov, .avi, .mkv, .flv, .wmv
audio     → .mp3, .wav, .ogg, .flac, .aac, .m4a
archive   → .zip, .tar, .tar.gz, .tgz, .rar, .7z, .bz2
document  → .pdf, .doc, .docx, .txt, .rtf, .odt
spreadsheet → .xls, .xlsx, .csv, .ods
presentation → .ppt, .pptx, .odp
code      → .js, .py, .rb, .java, .cpp, .c, .go, .rs, .sh
```

## Implementation Considerations

1. **Case-insensitive matching**: Handle `.PDF`, `.Pdf`, `.pdf`
2. **Query parameters**: Match `file.pdf?download=true`
3. **Fragment identifiers**: Match `file.pdf#page=2`
4. **URL encoding**: Handle `file%20name.pdf`
5. **Source tags**: Prioritize `<a href>` for downloadable files, but also check `<img src>`, `<video src>`, etc. based on type
6. **Metadata extraction**: Automatically extract useful metadata like:
   - Link text/title
   - File size (if available in HTML)
   - MIME type (from headers or content-type attributes)

## Use Cases

### Use Case 1: Download All PDFs from Research Site

```bash
# Simple one-liner to get all PDFs
ar-crawl crawl https://research.edu/papers -o papers.json
ar-crawl extract papers.json --file-type pdf --resolve-urls -o pdf-list.json

# Download them
cat pdf-list.json | jq -r '.data[].url' | xargs -I {} wget {}
```

### Use Case 2: Archive All Images from Gallery

```bash
# Get all images
ar-crawl crawl-site https://gallery.com --max-pages 50 -o gallery.json
ar-crawl extract gallery.json --file-type image --resolve-urls -o images.json

# Download high-quality images only (filter by URL pattern)
cat images.json | jq -r '.data[] | select(.url | contains("full-res")) | .url' | \
  xargs -I {} wget {}
```

### Use Case 3: Download Software Archives

```bash
# Get all downloadable archives
ar-crawl crawl https://software.com/downloads -o downloads.json
ar-crawl extract downloads.json --file-type archive --resolve-urls -o archives.json

# Show what will be downloaded
cat archives.json | jq '.data[] | "\(.link_text): \(.url)"'
```

### Use Case 4: Mixed Document Types

```bash
# Get PDFs and Word documents
ar-crawl crawl https://legal-docs.com -o docs.json
ar-crawl extract docs.json \
  --extension pdf --extension docx --extension doc \
  --resolve-urls \
  -o legal-docs.json
```

## Relationship to Other Features

This feature would work well with:
- **Feature-003 (URL Resolution)**: Combined with `--resolve-urls` for download-ready URLs
- **Future download feature**: Could add `--download` to automatically download matched files
  ```bash
  ar-crawl extract page.json --file-type pdf --download -o downloads/
  ```

## Impact

**High impact** for file-downloader user persona. This feature transforms ar-crawl from a generic extraction tool into a specialized file discovery and download preparation tool.

Current workflow (complex):
```bash
# Requires XPath knowledge + manual URL resolution + filtering
ar-crawl extract page.json --xpath-map '{"url": "//a[contains(@href,\".pdf\")]/@href"}'
# ...then resolve URLs manually
# ...then filter out false matches
```

Proposed workflow (simple):
```bash
# Simple, discoverable, handles edge cases automatically
ar-crawl extract page.json --file-type pdf --resolve-urls
```

## Alternative: Combine with crawl-site

Could also integrate with `crawl-site` command:

```bash
# Crawl site and extract all PDFs in one command
ar-crawl crawl-site https://site.com \
  --max-pages 100 \
  --collect-files pdf \
  --resolve-urls \
  -o pdfs.json
```
