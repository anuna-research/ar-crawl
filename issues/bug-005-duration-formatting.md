# Bug 005: Inconsistent Duration and Uptime Formatting

## Status
✅ Fixed

## Category
CLI / Output Formatting

## Description
Duration and uptime values are displayed in confusing fraction formats that don't make mathematical sense:
- "1657/1000 seconds" (should be "1.657 seconds" or "1657 ms")
- "5364 ms (1341/250 seconds)" (1341/250 = 5.364, not matching the ms value correctly in context)

## First-Time User Impact
**Low-Medium** - While not breaking functionality, it makes the tool look unpolished and confuses users trying to understand performance metrics.

## Examples

### Health Command
```
Overall Status: healthy
Uptime: 1657/1000 seconds
```
**Should be:** `Uptime: 1.657 seconds` or `Uptime: 1657 ms`

### Crawl-Site Command
```
Site Crawl Results:
Total Duration: 5364 ms (1341/250 seconds)
Average Time per Page: 2682 ms
```
**Should be:** `Total Duration: 5.364 seconds (5364 ms)` or just `Total Duration: 5364 ms`

## Root Cause
The code appears to be printing fractions directly from Racket's rational number type without converting to a human-readable format. Racket represents decimals as exact fractions internally (e.g., `1.657` becomes `1657/1000`).

## Suggested Fix

Convert rational numbers to decimals before display:
```racket
(define (format-duration-ms ms)
  (if (< ms 1000)
      (format "~a ms" ms)
      (format "~a seconds (~a ms)" (exact->inexact (/ ms 1000)) ms)))

(define (format-uptime-ms ms)
  (cond
    [(< ms 1000) (format "~a ms" ms)]
    [(< ms 60000) (format "~a seconds" (exact->inexact (/ ms 1000)))]
    [(< ms 3600000)
     (let ([mins (quotient ms 60000)]
           [secs (quotient (remainder ms 60000) 1000)])
       (format "~a min ~a sec" mins secs))]
    [else
     (let ([hours (quotient ms 3600000)]
           [mins (quotient (remainder ms 3600000) 60000)])
       (format "~a hr ~a min" hours mins))]))
```

## Expected Output

### Health Command
```
Overall Status: healthy
Uptime: 1.7 seconds
```
or
```
Overall Status: healthy
Uptime: 1657 ms
```

### Crawl-Site Command
```
Site Crawl Results:
Total Duration: 5.4 seconds
Average Time per Page: 2.7 seconds
```
or
```
Site Crawl Results:
Total Duration: 5364 ms
Average Time per Page: 2682 ms
```

## Test Cases
1. Duration < 1 second → show in ms
2. Duration < 1 minute → show in seconds with 1-2 decimal places
3. Duration < 1 hour → show as "X min Y sec"
4. Duration ≥ 1 hour → show as "X hr Y min"

## Related Files
- `src/cli.rkt` - Output formatting for commands
- `src/utils.rkt` - Utility functions (if duration formatting exists)
- `src/production-crawler.rkt` - Crawler metrics

## Priority
Medium - Doesn't affect functionality but impacts perceived quality and user trust.

## Additional Notes
- Check all commands for consistent duration formatting
- Consider using a centralized formatting utility function
- Ensure consistency across all output (JSON should use numeric milliseconds, human output should use formatted strings)

## Fix Applied

### Fix 1: Health Command Uptime
**File:** `src/cli.rkt` line 1145

**Change:** Convert rational number to decimal before printing:
```racket
;; Before:
(printf "Uptime: ~a seconds~n" (health-status-uptime health))

;; After:
(printf "Uptime: ~a seconds~n" (exact->inexact (health-status-uptime health)))
```

**Result:** `Uptime: 1.387 seconds` instead of `Uptime: 1387/1000 seconds`

### Fix 2: Site Crawl Duration
**File:** `src/site-crawler.rkt` lines 407-411

**Change:** Convert rational numbers to decimals:
```racket
;; Before:
(printf "Total Duration: ~a ms (~a seconds)~n"
       (hash-ref stats 'duration-ms)
       (/ (hash-ref stats 'duration-ms) 1000))
(printf "Average Time per Page: ~a ms~n"
       (exact-round (hash-ref stats 'average-page-time-ms)))

;; After:
(printf "Total Duration: ~a ms (~a seconds)~n"
       (hash-ref stats 'duration-ms)
       (exact->inexact (/ (hash-ref stats 'duration-ms) 1000)))
(printf "Average Time per Page: ~a ms~n"
       (exact->inexact (hash-ref stats 'average-page-time-ms)))
```

**Result:**
- `Total Duration: 4524 ms (4.524 seconds)` instead of `4524 ms (1131/250 seconds)`
- `Average Time per Page: 2262.0 ms` instead of potentially showing fractions
