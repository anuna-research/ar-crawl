# ar-crawl TODO

## Friction Points (from User Persona Testing)

### Data Scientist Workflow (Dr. Sarah Chen persona)
*Discovered: 2026-01-02*

- [x] **`sample` command doesn't support SQLite format**
  - When running `./ar-crawl sample /tmp/racket-docs.db`, get error about unsupported format
  - Expected: Should be able to sample HTML from crawled SQLite database
  - Workaround: Use raw `sqlite3` CLI queries
  - *Completed 2026-01-02: Added .db file detection and load-crawled-pages function*

- [x] **`extract` command doesn't support SQLite format**
  - Cannot run XPath extraction directly on `.db` files
  - Expected: `./ar-crawl extract file.db --xpath-map '{...}'` should work
  - Workaround: Use SQL queries with `sqlite3` CLI for analysis
  - *Completed 2026-01-02: Added .db file detection to load data from SQLite*

- [x] **No built-in text analysis for crawled data**
  - Had to write custom SQL patterns like:
    ```sql
    (length(content) - length(replace(content, 'term', ''))) / len
    ```
  - Consider: Add `analyze` or `stats` subcommand for common metrics
  - *Completed 2026-01-02: Added `stats` command with comprehensive crawl statistics*

## Future Enhancements

- [x] Add `--format sqlite` support to `sample` command
- [x] Add `--format sqlite` support to `extract` command
- [x] Consider unified `analyze` command for SQLite datasets
  - *Implemented as `stats` command with page counts, content statistics, performance metrics, and domain analysis*
