# AR-Crawl

AR-Crawl gives agents a command-line interface for crawling websites, extracting structured data, and driving browser tasks.
Your agent chooses the task and interprets the results; ar-crawl runs the web operations without an embedded language model.

## Quick Start

Install the released CLI:

```bash
curl -fsSL https://files.anuna.io/ar-crawl/latest/install.sh | bash
export PATH="$HOME/.local/bin:$PATH"
ar-crawl version
ar-crawl crawl https://example.com --service direct --output page.json
```

The direct service needs no API key or browser.
The command saves the crawl result to `page.json`.

Browser tasks need Node.js, Playwright and its Chromium installation.
For secure sessions, use Node.js 22.13+ and Playwright 1.48+.
The installer offers browser setup; source setup appears below.
New features on `main` are not necessarily included in the latest published release.

## Usage

### Crawl and extract

```bash
# Crawl a bounded set of pages into a queryable database.
ar-crawl crawl-site https://example.com --max-pages 10 --output site.db --format sqlite

# Extract headings from a saved page.
ar-crawl extract page.json --xpath-map '{"headings":"//h1"}'

# Render a JavaScript-dependent page with a local browser.
ar-crawl crawl https://example.com --service playwright --output rendered.json
```

Other service adapters include FireCrawl, ScrapingBee, Browserless and ScraperAPI.
Their API keys configure crawling services; they are separate from private website credentials.

### Choose a browser session

| Task | Command | Behaviour |
| --- | --- | --- |
| General browser automation | `ar-crawl session` | Shared browser service; actions can be recorded and exported. |
| Website login or sensitive input | `ar-crawl session --secure-profile /absolute/private/profile.json` | Isolated browser; trusted grants; no recording or secret exports. |

Ordinary sessions can expose filled values through recordings and page state.
Use [secure sessions](docs/secure-sessions.md) for private values.
Secure mode exposes a restricted command set and does not import an existing browser profile.

An ordinary session accepts JSON actions and text commands on standard input:

```text
{"type":"goto","url":"https://example.com"}
state --actions
commit browsing.json
exit
```

Use `ar-crawl replay browsing.json` to replay an ordinary recording.
For page-load diagnostics, use `ar-crawl probe https://example.com`.
Android workflows appear in [Android APK verification](docs/llm-android-verification.md).

### Private values: env file or Keychain?

Both storage paths are supported, through different interfaces:

| Source | Where the value lives | What ar-crawl does |
| --- | --- | --- |
| `env-file` | A private plaintext file | Reads the configured key directly, without copying it into the process environment. |
| `broker` | Storage managed by a trusted application, such as macOS Keychain | Requests a value from an authenticated local provider. |

AR-Crawl has no built-in Keychain storage adapter.
Applications can connect their own Keychain or secret-store integration through the broker interface.

A trusted person or application creates the secure profile.
The agent receives connection and field IDs; it does not need the provider token, private file contents or resolved values.
Keep profiles and private env files outside repositories, with mode `0600` in a `0700` directory.
File permissions do not isolate other processes running as the same OS user.

See [provider integration](docs/secure-sessions.md#credential-provider-integration) for the broker protocol and complete configuration examples.

### Match sensitive values to form fields

[Semantic field matching](docs/secure-sessions.md#semantic-field-matching) connects a granted value ID, such as `personal-card-number`, to a meaning such as `payment.card.number`.
AR-Crawl discovers the matching input from autocomplete attributes or labels; saved selectors remain optional overrides.
Ambiguous matches require a trusted profile update before retrieval.
Discovery does not grant access to additional values or websites.

Within a configured secure session, the agent requests discovery and filling by ID:

```text
{"type":"discoverFields"}
{"type":"fillSecret","fieldId":"personal-card-number"}
```

See [sensitive-field configuration](docs/secure-sessions.md#named-sensitive-fields) for the complete login, navigation and filling workflow.
All login selectors are optional overrides. Automatic login requires a unique submit control and a new visible sign-out control.

**Sensitive filling is currently fill-only.**
After filling, ar-crawl withholds page content and blocks clicks, navigation and keypresses.
Further granted fills remain available; there is no payment-submission command.
The approved website receives the value and can submit it automatically through its own scripts.
Cross-origin payment-provider frames, select controls and expiry-format conversion are unsupported.
An optional [reCAPTCHA permission](docs/secure-sessions.md#google-recaptcha-dependencies) allows verification traffic; it does not solve interactive challenges.

## Architecture

```text
Agent or application
        |
    Racket CLI
        |
        +-- Crawl adapters --> Direct HTTP / local Playwright / hosted services
        |                  --> Structured output and extraction
        |
        +-- Ordinary session --> Shared Playwright service --> Recording / replay
        |
        +-- Secure session --> Isolated browser driver
                           --> Private env file or authenticated local broker
```

The CLI dispatches commands in `src/cli.rkt`.
Crawling and formatting modules produce JSON, CSV, Markdown and SQLite output.
The ordinary browser service runs in `playwright-service/server.js`.
The secure driver runs separately in `playwright-service/secure-session.js`.

Secure sessions keep top-level navigation on the connection's origin.
External verification requests require the optional reCAPTCHA permission.
Explicit resource origins permit selected static resources; they do not grant cross-origin form submission.
Recordings, raw HTML, screenshots, evaluation and cookie exports are unavailable in secure mode.
Known login values are redacted from state; sensitive filling suppresses subsequent page content entirely.
These controls do not protect against a compromised approved website or an attacker running as the same OS user.

## API Reference

The CLI's help describes command arguments:

```bash
ar-crawl help
ar-crawl help crawl-site
ar-crawl help extract
ar-crawl help session
```

Within a session, `help` lists that mode's supported actions.
The [secure-session reference](docs/secure-sessions.md) documents profiles, provider requests, JSON actions, matching rules and restrictions.

## Development

Source builds need Racket, Node.js and npm; secure tests also need OpenSSL and Chromium.
Clone the canonical repository and install dependencies:

```bash
git clone https://git.anuna.io/anuna-research/ar-crawl.git
cd ar-crawl
make install
raco pkg install --auto --skip-installed sxml csv-writing
make playwright-setup
raco make src/cli.rkt
racket src/cli.rkt help
```

To run the source driver, explicitly select its directory:

```bash
PLAYWRIGHT_SERVICE_DIR="$PWD/playwright-service" \
  racket src/cli.rkt session --secure-profile /absolute/private/profile.json
```

Run the project checks and secure-session tests:

```bash
make test
npm --prefix playwright-service run test:secure
```

The secure suite uses local fixtures and synthetic values; it requires no real credentials or card details.
Build release archives with `make dist-full` to include the secure driver files.
Submit changes and issues to the canonical repository at `https://git.anuna.io/anuna-research/ar-crawl`.
