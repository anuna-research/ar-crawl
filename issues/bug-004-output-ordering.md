# Bug 004: JSON Output Appears Before Status Messages

## Status
✅ Fixed

## Category
CLI / User Experience

## Description
When running `ar-crawl crawl` without the `-o` flag, the JSON output is printed to stdout BEFORE the status messages "Crawling URL: ..." and "Done.". This creates confusing output where the user sees JSON data, then status messages appear after.

## First-Time User Impact
**Medium** - This is confusing for first-time users who expect status messages to appear first, then results. It breaks the mental model of "start message -> work -> results -> done message".

## Steps to Reproduce
```bash
ar-crawl crawl https://httpbin.org/html
```

## Expected Behavior
```
Crawling URL: https://httpbin.org/html...
{
  "data": [...],
  "metadata": {...}
}
Done.
```

## Actual Behavior
```
{
  "data": [...],
  "metadata": {...}
}
Crawling URL: https://httpbin.org/html...
Done.
```

## Root Cause
The crawl function likely:
1. Returns the result data
2. The result gets printed to stdout immediately
3. Then status messages are printed after

The output ordering should be:
1. Print "Crawling URL..." to stderr (or stdout before crawl)
2. Perform crawl
3. Print results to stdout
4. Print "Done." to stderr

## Suggested Fix
Option 1: Print status messages to stderr
```racket
(eprintf "Crawling URL: ~a...~n" url)
(define result (crawl url))
(displayln (jsexpr->string result))
(eprintf "Done.~n")
```

Option 2: Buffer output and print in correct order
```racket
(displayln (format "Crawling URL: ~a..." url))
(define result (crawl url))
(displayln (jsexpr->string result))
(displayln "Done.")
```

## Workaround
Use `-o` flag to save to file, then the console output is clean:
```bash
ar-crawl crawl https://example.com -o results.json
```

## Priority
Medium - Works fine functionally, but creates poor UX. When piping output to `jq` or other tools, this could cause parsing issues if they see the status messages.

## Related Files
- `src/cli.rkt` - Main command implementation
- `src/production-crawler.rkt` - Crawler execution

## Additional Notes
- This only affects commands without `-o` flag
- May also affect other commands (check `crawl-site`, `extract`, etc.)
- Using stderr for status messages is a common CLI pattern (allows piping data cleanly)

## Fix Applied
**File:** `src/cli.rkt` lines 272-280

**Change:** Swapped the order of `output-results` and status message printing:
```racket
;; Before (incorrect order):
(if verbose
    (printf "Crawl completed successfully~n")
    (eprintf "Done.~n"))
(output-results filtered-results output-file effective-format verbose)

;; After (correct order):
(output-results filtered-results output-file effective-format verbose)
(if verbose
    (printf "Crawl completed successfully~n")
    (eprintf "Done.~n"))
```

**Result:** Status messages now appear in correct order:
1. "Crawling URL: ..." (stderr)
2. JSON output (stdout)
3. "Done." (stderr)
