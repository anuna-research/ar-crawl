# Bug 006: Value-taking flags before the command swallow the command

## Status
✅ Fixed

## Category
CLI / Argument Parsing

## Description
The documented form `ar-crawl -s playwright crawl <url>` fails with
`the "-s" option needs 1 argument, but 0 provided`. `find-command-index`
took the first token not starting with `-` as the command, so the *value*
of a flag (`playwright`, or `config.json` after `-c`) was treated as the
command and the flag lost its argument. The same failure affected `-c`,
`-o` and `-f` placed before the command. The unit tests encoded the wrong
behaviour ("config.json becomes the command").

## First-Time User Impact
**High** — the README, `--help` Quick Start and the services reference all
show `-s playwright crawl`, which was the first command a user reached for
to render a JavaScript page.

## Reproduction
```
$ ar-crawl -s playwright crawl https://example.com
ar-crawl: the "-s" option needs 1 argument, but 0 provided
$ ar-crawl crawl https://example.com -s playwright     # worked
```

## Root Cause
`find-command-index` (src/cli.rkt) had no notion of flags that consume the
following argument.

## Fix
`VALUE-FLAGS` lists the global flags that take a value (`-s/--service`,
`-c/--config`, `-o/--output`, `-f/--format`); the scan skips the token after
each. Regression tests in the `cli.rkt` test submodule cover `-s`, repeated
`-s`, `-c`, and a dangling flag. Smoke-verified: `-s playwright crawl` renders
JavaScript content via the Playwright service.
