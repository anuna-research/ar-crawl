# Bug: Inconsistent JSON Data Type on Failure

## Status
- [ ] Confirmed
- [x] Fixed

## Description
When running `ar-crawl` with `--format json`, a failed crawl returns `[false]` in the `data` field. This breaks schema consistency, as `data` is expected to be a list of page objects or an empty list.

## Reproduction
```bash
dist/ar-crawl crawl https://this-domain-definitely-does-not-exist-12345.com --format json
```

## Output Observed
```json
{
  "data": [ false ],
  "errors": [ ... ]
}
```

## Expected Output
```json
{
  "data": [],
  "errors": [ ... ]
}
```

## Impact
LLM Agents and scripts parsing this output may crash or fail due to type mismatch (Boolean vs Object).
