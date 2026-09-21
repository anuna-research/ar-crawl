# ar-crawl

An agent-first web crawler and browser driver: an LLM agent invokes it, receives clean JSON, CSV or SQLite, and applies its own intelligence. **The AI is in your agent, not in the tool.**

Built in Racket. It crawls with a built-in direct HTTP service or a local Playwright browser. When configured, it falls back across FireCrawl, ScrapingBee, Browserless and ScraperAPI. It also drives live browser sessions over JSON, replays Chrome DevTools recordings, and films agent-driven demos.

## Quick Start

```bash
curl -fsSL https://files.anuna.io/ar-crawl/latest/install.sh | bash
ar-crawl crawl https://example.com -o first.json
```

The installer puts the `ar-crawl` binary in `~/.local/bin` (override with `INSTALL_DIR`) and the Playwright service beside it; Node.js 18+ is needed for browser rendering. `first.json` holds the page, and no API key is involved. For the guided version, read [Your first crawl](docs/tutorial/index.md).

To run from source instead, with Racket 8.0+:

```bash
git clone ssh://git@git.anuna.io/anuna-research/ar-crawl.git
cd ar-crawl && make setup && make install
racket src/cli.rkt crawl https://example.com -o first.json
```

## Usage

Crawl a site to a queryable database, filtered to the pages you want:

```bash
ar-crawl crawl-site https://example.com --url-pattern ".*blog.*" --max-pages 50 -o blog.db --format sqlite
```

Render a JavaScript-heavy page with the local browser, after probing it for the right delays:

```bash
ar-crawl probe https://spa.example.com
ar-crawl -s playwright crawl https://spa.example.com --pw-delay 8500
```

Drive a browser from an agent, then film the same flow as a product demo:

```bash
ar-crawl session --record demo/
{"type": "goto", "url": "https://app.example.com", "title": "Open the dashboard"}
{"type": "click", "selector": "button:has-text('New')", "title": "Create a project"}
commit
```

Each of these has a guide: [crawl a site](docs/how-to/how-to-crawl-a-site.md), [extract structured data](docs/how-to/how-to-extract-structured-data.md), [probe a page](docs/how-to/how-to-probe-a-page-before-crawling.md), [drive a session](docs/how-to/how-to-drive-a-browser-session-as-an-agent.md), [record a demo](docs/how-to/how-to-record-a-demo.md). The full list is in the [documentation index](docs/index.md).

## Architecture

```
┌────────────┐  1. invokes CLI      ┌────────────┐  HTTP    ┌────────────────────┐
│ LLM agent  │ ───────────────────▶ │  ar-crawl  │ ───────▶ │ playwright-service │
│            │ ◀─────────────────── │  (Racket)  │          │ (Node, local)      │
└────────────┘  2. JSON/CSV/SQLite  └─────┬──────┘          └────────────────────┘
                                          │ fallback chain
                                          ▼
                              direct HTTP · FireCrawl · ScrapingBee · Browserless · ScraperAPI
```

The Racket CLI owns crawling, queueing, filtering and output. The Node service wraps Playwright for rendering, sessions, replay and recording; the CLI spawns it on demand. Crawl data is returned as structured output and never interpreted by ar-crawl itself. Why it is built this way is in [Agent-first architecture](docs/explanation/about-agent-first-architecture.md); deeper design notes are under [docs/](docs/index.md#design-notes).

## API Reference

ar-crawl is a CLI. `ar-crawl help <command>` prints the contract for one command; the complete set is in:

- [CLI commands and options](docs/reference/cli.md) — every command, flag and exit code
- [Configuration file and environment](docs/reference/configuration.md)
- [Crawling services](docs/reference/services.md)
- [Site crawl output](docs/reference/site-crawl-output.md) and [SQLite schema](docs/reference/sqlite-schema.md)
- [Session commands and actions](docs/reference/session.md), [Replay step types](docs/reference/replay.md), [Demo bundle format](docs/reference/demo-bundle.md)

## Development

```bash
make build        # compile src/cli.rkt
make test         # module tests (raco test)
raco test src/cli.rkt
make dev-run      # run from source
```

The Playwright service lives in `playwright-service/` (`npm install` runs on first use; `PLAYWRIGHT_SERVICE_DIR` points the CLI at a checkout). Set service API keys in `.env`; see the [configuration reference](docs/reference/configuration.md). Racket tooling for agents is in [AGENT.md](AGENT.md).

To add a crawling service, implement an adapter in `src/crawl-service-adaptor.rkt` and register it in the service registry. Then add its configuration schema, tests, and a reference entry.

Contributions arrive as pull requests on [git.anuna.io/anuna-research/ar-crawl](https://git.anuna.io/anuna-research/ar-crawl): branch, change, test, submit.

## Documentation

- [Tutorial](docs/tutorial/index.md) — learn by doing your first crawl
- [How-to guides](docs/index.md#get-something-done) — reach a goal
- [Reference](docs/index.md#look-something-up) — look a fact up
- [Explanation](docs/index.md#understand) — understand why

## License

Apache License 2.0 — see [LICENSE](LICENSE).
