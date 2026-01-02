# ar-crawl TODO

## Current Issues

### Code Bugs
*Discovered: 2026-01-02*

- [ ] **Probe command JSON output has undefined variables**
  - In `src/cli.rkt:649-676`, the JSON output section references variables
    before they're defined: `perf`, `by-type`, `total-bytes`, `network-requests`,
    `dynamic-score`, `js-time`, `xhr-count`, `fetch-count`, etc.
  - This will cause errors when `-f json` is specified
  - Location: `cmd-probe` function, JSON output block
  - Fix: Move variable definitions before the JSON output block or restructure

- [ ] **Probe command redundant code section**
  - Lines 649-676 contain JSON output logic with duplicate variable assignments
    that conflict with the text output section (lines 696-753)
  - The code appears to be from a refactoring that was not completed
  - Location: `cmd-probe` function

## Future Enhancements

- [ ] Add comprehensive unit tests for `probe` command
- [ ] Add integration tests for SQLite workflow (crawl → sample → extract → stats)
- [ ] Consider adding `--format jsonl` support for streaming JSON lines output
