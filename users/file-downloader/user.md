# File Downloader User Profile

## Who They Are

**Name:** Alex Chen
**Role:** Research Assistant / Digital Archivist / Media Collector
**Organization:** University, archive project, or freelance media work
**Technical Level:** Medium (command line comfortable, basic scripting)

## Daily Context

Alex needs to download specific file types from websites. They typically:

- Download PDF research papers from academic sites
- Collect images from photography or design portfolios
- Archive media files (videos, audio) from content sites
- Harvest documents from resource pages

## Goals

1. Download all files of a specific type from a page or site
2. Filter files by extension, size, or naming patterns
3. Organize downloads with proper naming and metadata
4. Handle bulk downloads efficiently

## Pain Points

- Manual right-click-save is too slow for dozens of files
- Need to find all file links on complex pages
- Want to filter by file type without downloading everything
- Need to handle different URL patterns (direct links, query params)

## Technical Environment

- macOS or Linux workstation
- Command line for automation
- Local storage or network drives
- Basic bash scripting for workflows

---

# Happy Path Flows

## Flow 1: Download All PDFs from a Page

Alex finds a resource page with 50+ research papers and needs them all.

```bash
# Crawl the page to find all PDF links
ar-crawl crawl https://research-site.edu/papers \
  --output papers.json

# Extract all PDF URLs
ar-crawl extract papers.json \
  --format json \
  --fields '{"pdf_url": "//a[ends-with(@href, \".pdf\")]/@href"}' \
  --output pdf-links.json

# Download each PDF (using jq and wget/curl)
cat pdf-links.json | jq -r '.data[].pdf_url' | while read url; do
  wget "$url" -P downloads/papers/
done
```

**Expected Outcome:** All PDFs downloaded to local folder.

**Success Criteria:**
- Finds all PDF links on page
- Downloads complete files
- Organizes in target directory

---

## Flow 2: Download Images from Multiple Pages

Alex needs to download all images from a photographer's portfolio spanning multiple pages.

```bash
# Crawl the portfolio site
ar-crawl crawl-site https://photo-portfolio.com/gallery \
  --url-pattern ".*/gallery/.*" \
  --max-depth 2 \
  --max-pages 50 \
  --output portfolio.db --format sqlite

# Extract high-res image URLs
ar-crawl extract portfolio.db \
  --format json \
  --fields '{"image_url": "//img[@class=\"full-res\"]/@src", "alt_text": "//img/@alt"}' \
  --output images.json

# Download images with metadata
cat images.json | jq -r '.data[] | "\(.image_url)\t\(.alt_text)"' | while IFS=$'\t' read url alt; do
  filename=$(echo "$alt" | sed 's/[^a-zA-Z0-9]/_/g')
  wget "$url" -O "downloads/portfolio/${filename}.jpg"
done
```

**Expected Outcome:** All portfolio images downloaded with descriptive names.

**Success Criteria:**
- Collects images from multiple pages
- Preserves metadata for naming
- Handles high-resolution versions

---

## Flow 3: Download Specific File Types by Extension

Alex needs to download all ZIP archives from a software downloads page.

```bash
# Crawl downloads page
ar-crawl crawl https://software-site.com/downloads \
  --output downloads-page.json

# Extract all archive file links (zip, tar.gz, etc.)
ar-crawl extract downloads-page.json \
  --format json \
  --fields '{"file_url": "//a[contains(@href, \".zip\") or contains(@href, \".tar.gz\")]/@href", "file_name": "//a[contains(@href, \".zip\") or contains(@href, \".tar.gz\")]/text()"}' \
  --output archives.json

# Download with original filenames
cat archives.json | jq -r '.data[] | "\(.file_url)\t\(.file_name)"' | while IFS=$'\t' read url name; do
  wget "$url" -O "downloads/software/$name"
done
```

**Expected Outcome:** All archive files downloaded with proper names.

**Success Criteria:**
- Identifies multiple file extensions
- Preserves original filenames
- Filters out non-archive links

---

## Flow 4: Download Media Files with Size Filtering

Alex wants to download only large video files, excluding previews/thumbnails.

```bash
# Crawl video library page
ar-crawl crawl https://video-library.com/archive \
  --output videos.json

# Extract video URLs with metadata
ar-crawl extract videos.json \
  --format json \
  --fields '{"video_url": "//a[ends-with(@href, \".mp4\")]/@href", "title": "//a[ends-with(@href, \".mp4\")]/text()", "size": "//span[@class=\"file-size\"]/text()"}' \
  --output video-list.json

# Download only videos larger than 10MB
# (requires checking HEAD request or parsing size field)
cat video-list.json | jq -r '.data[] | "\(.video_url)\t\(.title)"' | while IFS=$'\t' read url title; do
  # Check file size
  size=$(curl -sI "$url" | grep -i Content-Length | awk '{print $2}' | tr -d '\r')
  if [ "$size" -gt 10485760 ]; then
    filename=$(echo "$title" | sed 's/[^a-zA-Z0-9]/_/g')
    echo "Downloading: $filename ($(($size / 1048576))MB)"
    wget "$url" -O "downloads/videos/${filename}.mp4"
  fi
done
```

**Expected Outcome:** Only full-size videos downloaded, thumbnails skipped.

**Success Criteria:**
- Filters by actual file size
- Skips small preview files
- Provides download progress info

---

## Flow 5: Download Files from JavaScript-Heavy Site

Alex needs to download files from a site that loads links dynamically.

```bash
# Use Playwright to render JavaScript
ar-crawl crawl https://dynamic-docs.com/resources \
  -s playwright \
  --pw-delay 5000 \
  --output dynamic-docs.json

# Extract download links that appeared after JS execution
ar-crawl extract dynamic-docs.json \
  --format json \
  --fields '{"doc_url": "//a[@class=\"download-link\"]/@href", "doc_name": "//a[@class=\"download-link\"]/text()"}' \
  --output docs-list.json

# Download documents
cat docs-list.json | jq -r '.data[] | "\(.doc_url)\t\(.doc_name)"' | while IFS=$'\t' read url name; do
  wget "$url" -O "downloads/docs/$name"
done
```

**Expected Outcome:** Files from dynamically-loaded links downloaded.

**Success Criteria:**
- Captures JS-rendered links
- Waits for page to fully load
- Downloads all dynamic content

---

## Flow 6: Batch Download with Pattern Matching

Alex needs to download all monthly report PDFs following a naming pattern.

```bash
# Crawl reports archive
ar-crawl crawl-site https://company.com/reports \
  --url-pattern ".*/reports/.*" \
  --max-depth 2 \
  --output reports.json

# Extract PDFs matching pattern (e.g., "monthly-report-2024-*.pdf")
ar-crawl extract reports.json \
  --format json \
  --fields '{"pdf_url": "//a[contains(@href, \"monthly-report\") and contains(@href, \".pdf\")]/@href", "month": "//a[contains(@href, \"monthly-report\")]/text()"}' \
  --output monthly-reports.json

# Download organized by year
cat monthly-reports.json | jq -r '.data[] | "\(.pdf_url)\t\(.month)"' | while IFS=$'\t' read url month; do
  year=$(echo "$url" | grep -oP '202[0-9]' | head -1)
  mkdir -p "downloads/reports/$year"
  wget "$url" -P "downloads/reports/$year/"
done
```

**Expected Outcome:** Reports organized by year in separate folders.

**Success Criteria:**
- Pattern matching works accurately
- Files organized by metadata
- Complete historical archive

---

## Flow 7: Download with Deduplication

Alex wants to avoid re-downloading files they already have.

```bash
#!/bin/bash
# smart-download.sh

DOWNLOAD_DIR="downloads/papers"
LOG_FILE="$DOWNLOAD_DIR/.download-log.txt"

mkdir -p "$DOWNLOAD_DIR"
touch "$LOG_FILE"

# Crawl for PDFs
ar-crawl crawl https://research-site.edu/papers \
  --output papers.json

# Extract PDF URLs
ar-crawl extract papers.json \
  --format json \
  --fields '{"pdf_url": "//a[ends-with(@href, \".pdf\")]/@href"}' \
  --output pdf-links.json

# Download only new files
cat pdf-links.json | jq -r '.data[].pdf_url' | while read url; do
  if grep -q "$url" "$LOG_FILE"; then
    echo "Skipping (already downloaded): $url"
  else
    echo "Downloading: $url"
    wget "$url" -P "$DOWNLOAD_DIR/"
    if [ $? -eq 0 ]; then
      echo "$url" >> "$LOG_FILE"
    fi
  fi
done

echo "Download complete. Total files: $(ls -1 $DOWNLOAD_DIR/*.pdf | wc -l)"
```

**Expected Outcome:** Only new files downloaded, duplicates skipped.

**Success Criteria:**
- Tracks previously downloaded files
- Skips duplicates efficiently
- Updates log after successful downloads

---

# Edge Cases and Recovery

## Handling Relative URLs

```bash
# Extract URLs and resolve relative paths
ar-crawl extract page.json \
  --format json \
  --fields '{"file_url": "//a/@href"}' | \
jq -r '.data[].file_url' | while read url; do
  # Convert relative to absolute
  absolute_url=$(python3 -c "from urllib.parse import urljoin; print(urljoin('https://base-site.com/path/', '$url'))")
  wget "$absolute_url"
done
```

## Files Behind Authentication

```bash
# Use cookies or headers with wget
wget --header="Authorization: Bearer TOKEN" \
     --header="Cookie: session=abc123" \
     "$file_url"
```

## Resume Interrupted Downloads

```bash
# wget with continue flag
wget -c "$large_file_url" -P downloads/
```

## Handle Rate Limiting

```bash
# Add delays between downloads
cat files.json | jq -r '.data[].url' | while read url; do
  wget "$url" -P downloads/
  sleep 2  # 2 second delay between downloads
done
```
