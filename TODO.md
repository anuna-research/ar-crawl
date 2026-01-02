# ar-crawl TODO

## Current Issues

### Recently Fixed (2026-01-02)

- [x] **Probe command JSON output has undefined variables**
  - Fixed by moving all metric computations (perf, total-bytes, by-type,
    network-requests, network-by-type, js-time, xhr-count, fetch-count,
    script-requests, network-idle-delay, dynamic-score) to the top of
    `cmd-probe` function before any output formatting
  - Location: `src/cli.rkt:631-651`

- [x] **Probe command redundant code section**
  - Removed duplicate variable definitions from verbose and content analysis
    sections; all variables are now computed once at function start
  - Location: `src/cli.rkt` `cmd-probe` function

## Future Enhancements

- [ ] Add comprehensive unit tests for `probe` command
- [ ] Add integration tests for SQLite workflow (crawl → sample → extract → stats)
- [ ] Consider adding `--format jsonl` support for streaming JSON lines output
