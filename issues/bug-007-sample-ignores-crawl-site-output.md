# Bug 007: `sample` cannot read `crawl-site` output

## Status
✅ Fixed

## Category
CLI / Data Extraction

## Description
`ar-crawl sample results.json` reported `no items found` when
`results.json` was written by `crawl-site`. `sample` read only the `data`
key, but `crawl-site` writes its pages under `pages`. `extract` already
accepted either key, so the documented workflow crawl-site → sample →
extract broke at its middle step.

## First-Time User Impact
**Medium** — the documentation presents `sample` as the way to discover
XPaths before `extract`, and site crawls are the common input.

## Reproduction
```
$ ar-crawl crawl-site https://example.com --max-pages 3 -o site.json
$ ar-crawl sample site.json
error: no items found in site.json
```

## Root Cause
`cmd-sample` used `(hash-ref input-data 'data '())` where `cmd-extract`
uses `(or (hash-ref input-data 'data #f) (hash-ref input-data 'pages #f) '())`.

## Fix
`cmd-sample` now loads items the same way `cmd-extract` does. Smoke-verified
against a three-page site crawl.
