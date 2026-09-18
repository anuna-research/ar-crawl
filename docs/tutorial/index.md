---
title: Your first crawl
mode: tutorial
---

# Your first crawl

We are going to install ar-crawl, crawl one page, crawl a small site, and then query the result with SQL. At the end you have a database of pages and know which command produced each part of it. Allow fifteen minutes.

## Before you start

You need `curl` and a shell. Node.js 18+ is needed later for browser rendering; skip it for now.

## 1. Install

Run the installer:

```bash
curl -fsSL https://files.anuna.io/ar-crawl/latest/install.sh | bash
```

It places `ar-crawl` in `~/.local/bin`. WHEN that directory is not on your `PATH`, the installer prints the line to add to your shell profile; add it and open a new terminal.

Check the install:

```bash
ar-crawl --version
```

The terminal prints `ar-crawl` and a version number. No API key is needed for anything in this tutorial: the direct service works as installed.

## 2. Crawl one page

```bash
racket src/cli.rkt crawl https://example.com
```

The terminal prints a JSON document. Notice the `url`, `title` and `content` fields: that is the page, as the crawler saw it.

Now keep the result:

```bash
racket src/cli.rkt crawl https://example.com -o first.json
```

Open `first.json`. It holds the same document.

## 3. Crawl a small site

```bash
racket src/cli.rkt crawl-site https://example.com --max-pages 5 -v -o site.json
```

The `-v` flag prints one line per page as it is fetched. The run stops after five pages. Open `site.json` and find the `statistics` block; `pages-crawled` reads `5` or fewer.

## 4. Write the crawl to a database

```bash
racket src/cli.rkt crawl-site https://example.com --max-pages 5 -o site.db --format sqlite
```

Now query it:

```bash
sqlite3 site.db "SELECT url, title FROM crawled_pages"
```

The terminal lists the pages you crawled, one per row.

## 5. Check the services

```bash
racket src/cli.rkt health
```

Only the `direct` service is listed, and it reports healthy. Services without an API key are not configured yet, so they do not appear.

## What you have

A page in `first.json`, a site in `site.json`, and the same site in `site.db` with a table per concept. From here:

- To crawl a real site with filters, read [How to crawl a site](../how-to/how-to-crawl-a-site.md).
- To pull fields out of the pages, read [How to extract structured data](../how-to/how-to-extract-structured-data.md).
- To render JavaScript-heavy pages, read [How to probe a page before crawling](../how-to/how-to-probe-a-page-before-crawling.md).
