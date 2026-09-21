---
title: ar-crawl documentation
mode: explanation
---

# ar-crawl documentation

ar-crawl is a web crawler and browser driver built as a **tool for LLM agents**. The agent invokes it, receives structured data, and applies its own intelligence. These pages are split by what you need from them: to learn, to get something done, to look a fact up, or to understand a decision.

## Learn

- [Tutorial: your first crawl](tutorial/index.md) — install, crawl one page, crawl a site, query the result.

## Get something done

Crawling and data:

- [How to crawl a site](how-to/how-to-crawl-a-site.md)
- [How to extract structured data](how-to/how-to-extract-structured-data.md)
- [How to analyse crawl results in SQLite](how-to/how-to-analyse-crawl-results-in-sqlite.md)
- [How to probe a page before crawling](how-to/how-to-probe-a-page-before-crawling.md)

Browser automation:

- [How to drive a browser session as an agent](how-to/how-to-drive-a-browser-session-as-an-agent.md)
- [How to replay a recording](how-to/how-to-replay-a-recording.md)
- [How to record a demo](how-to/how-to-record-a-demo.md)

Operating:

- [How to configure services](how-to/how-to-configure-services.md)
- [How to deploy with Docker](how-to/how-to-deploy-with-docker.md)
- [How to monitor the crawler](how-to/how-to-monitor-the-crawler.md)
- [How to recover from common failures](how-to/how-to-recover-from-common-failures.md)

## Look something up

- [CLI commands and options](reference/cli.md)
- [Configuration file and environment](reference/configuration.md)
- [Crawling services](reference/services.md)
- [Site crawl output](reference/site-crawl-output.md) and [SQLite schema](reference/sqlite-schema.md)
- [Probe metrics and scoring](reference/probe.md)
- [Session commands and actions](reference/session.md) and [Replay step types](reference/replay.md)
- [Demo bundle format](reference/demo-bundle.md)

## Understand

- [Agent-first architecture](explanation/about-agent-first-architecture.md) — why the AI stays in your agent.
- [SQLite output](explanation/about-sqlite-output.md) — why a database sits next to JSON.

## Design notes

Longer explorations that are not yet part of the product: [Chrome extension + remote agent](chrome-extension-remote-agent.md), [LLM Android verification](llm-android-verification.md), [Goblins architecture](diagrams/goblins-architecture.md), and the [Android emulator support](specs/android-emulator-support.md) and [parallel sessions](../specs/parallel-sessions.md) specifications.
