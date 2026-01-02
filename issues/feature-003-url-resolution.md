# Feature: Automatic URL Resolution to Absolute URLs

## Status
- [x] Proposed
- [ ] Implemented

## User Perspective
**As a file-downloader user**, when I extract URLs from a crawled page (especially for images, PDFs, or other downloadable files), I need them to be absolute URLs so I can directly download them using wget, curl, or other download tools.

## Problem
When extracting URLs using XPath, ar-crawl returns the URLs exactly as they appear in the HTML, which often includes:
- Relative paths: `/WAI/WCAG22/quickref/img/w3c.svg`
- Protocol-relative URLs: `//www.w3.org/analytics/piwik/piwik.php?idsite=328`
- Relative URLs: `../docs/file.pdf`

These cannot be used directly for downloading without manual URL resolution.

## Current Behavior

```bash
ar-crawl crawl https://w3.org/WAI/WCAG21/quickref/ -o page.json
ar-crawl extract page.json --xpath-map '{"images": "//img/@src"}' --format json
```

Output:
```json
{
  "data": [{
    "images": [
      "/WAI/WCAG22/quickref/img/w3c.svg",
      "//www.w3.org/analytics/piwik/piwik.php?idsite=328"
    ]
  }]
}
```

**Problem**: These URLs can't be downloaded directly:
```bash
wget "/WAI/WCAG22/quickref/img/w3c.svg"  # FAILS - not a valid URL
```

## Desired Behavior

Add a `--resolve-urls` flag (or make it default) that resolves all extracted URLs to absolute URLs based on the source page's base URL.

```bash
ar-crawl extract page.json --xpath-map '{"images": "//img/@src"}' --resolve-urls --format json
```

Output:
```json
{
  "data": [{
    "images": [
      "https://www.w3.org/WAI/WCAG22/quickref/img/w3c.svg",
      "https://www.w3.org/analytics/piwik/piwik.php?idsite=328"
    ],
    "source_url": "https://www.w3.org/WAI/WCAG21/quickref/"
  }]
}
```

**Now these work**:
```bash
cat output.json | jq -r '.data[].images[]' | while read url; do
  wget "$url" -P downloads/
done
```

## Implementation Considerations

1. **Detect URL fields**: Could automatically detect fields that contain URLs (contain `@href`, `@src`, or end with `_url`, `_link`)
2. **Base URL**: Use the `source_url` from the crawl data as the base for resolution
3. **Handle edge cases**:
   - Already absolute URLs (http://, https://) → leave unchanged
   - Protocol-relative URLs (//example.com) → add `https:`
   - Root-relative URLs (/path) → combine with domain
   - Relative URLs (../file.pdf) → resolve relative to page path
4. **Opt-in vs opt-out**: Consider making it default for convenience, with `--no-resolve-urls` to disable

## Use Cases

### Use Case 1: Bulk Image Download
```bash
# Extract all images as absolute URLs
ar-crawl crawl https://portfolio.com/gallery -o gallery.json
ar-crawl extract gallery.json \
  --xpath-map '{"image_url": "//img[@class=\"full-res\"]/@src"}' \
  --resolve-urls \
  -o images.json

# Download all images
cat images.json | jq -r '.data[].image_url' | xargs -I {} wget {}
```

### Use Case 2: PDF Archive
```bash
# Extract all PDF links as absolute URLs
ar-crawl crawl https://research.edu/papers -o papers.json
ar-crawl extract papers.json \
  --xpath-map '{"pdf_url": "//a[contains(@href, \".pdf\")]/@href"}' \
  --resolve-urls \
  -o pdf-links.json

# Download all PDFs
cat pdf-links.json | jq -r '.data[].pdf_url' | while read url; do
  wget "$url" -P downloads/papers/
done
```

## Impact
This feature is **critical** for the file-downloader user persona. Without it, users must manually resolve URLs using external tools or scripts, which is error-prone and creates unnecessary friction.

## Related Issues
- Could be combined with a `--download` flag in the future to handle downloads directly in ar-crawl
