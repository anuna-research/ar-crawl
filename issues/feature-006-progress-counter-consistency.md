# Feature 006: Consistent Progress Counter Display

## Status
🟢 Enhancement

## Category
CLI / User Experience

## Description
The progress counter during site crawls shows inconsistent totals that change mid-operation:
```
[0/3] Crawling: https://httpbin.org/
[1/3] Crawling: https://httpbin.org/forms/post
[2/2] Site crawl completed
```

The counter changes from `/3` to `/2`, which is confusing. The denominator should represent either:
1. **Max pages limit** (stays constant at 3) - what the user requested
2. **Total discovered URLs** (can increase as new links are found)

## First-Time User Impact
**Low** - Slightly confusing but doesn't block work. Users might wonder if the tool is working correctly when numbers don't add up.

## Current Behavior
The progress counter appears to show `[pages_crawled/something_dynamic]` where the denominator changes during execution, making it hard to track progress.

## Proposed Solutions

### Option 1: Show Progress Against Max Pages (Recommended)
Most intuitive for users - shows progress toward their goal:
```
[1/3] Crawling: https://httpbin.org/
[2/3] Crawling: https://httpbin.org/forms/post
[3/3] Crawling: https://httpbin.org/about
[3/3] Site crawl completed
```

If max pages is reached before all URLs are discovered:
```
[1/50] Crawling: https://example.com/
[2/50] Crawling: https://example.com/page2
...
[50/50] Crawling: https://example.com/page50
[50/50] Site crawl completed (limit reached, 23 URLs remain in queue)
```

### Option 2: Show Discovered vs Crawled
Shows the dynamic discovery process:
```
[1/1] Crawling: https://httpbin.org/
[2/5] Crawling: https://httpbin.org/forms/post (discovered 4 new URLs)
[3/5] Crawling: https://httpbin.org/about
[3/5] Site crawl completed
```

### Option 3: Simple Counter Without Total
No denominator confusion:
```
[1] Crawling: https://httpbin.org/
[2] Crawling: https://httpbin.org/forms/post
[3] Site crawl completed
```
Plus show summary:
```
Crawled: 3 pages
Discovered: 5 URLs
Remaining: 2 URLs (stopped due to max-pages limit)
```

## Recommended Approach
**Option 1** is most user-friendly for the common case. It answers the question "how close am I to done?" which is what users want to know.

Add a summary at the end showing:
```
[50/50] Site crawl completed

Summary:
  Pages crawled: 50 / 50 (max-pages limit reached)
  URLs discovered: 127
  URLs in queue: 77 (not crawled due to limit)
  Failed URLs: 0
```

## Implementation Notes
- Track `current-count` and `max-pages` separately
- The denominator should always be `max-pages` for simplicity
- Add verbose flag info to show queue size and discovery progress
- Consider progress bar for longer crawls (e.g., `[=====>    ] 15/50`)

## Related Files
- `src/site-crawler.rkt` - Site crawling implementation
- `src/cli.rkt` - Progress display logic

## Priority
Low - Nice to have, improves UX but not critical

## Additional Considerations
- Add a `--quiet` flag to suppress progress (for scripting)
- Consider using a progress bar library for visual appeal
- In verbose mode, show additional details:
  ```
  [15/50] Crawling: https://example.com/page15
          Queue: 45 URLs | Discovered: 67 | Failed: 2
  ```
