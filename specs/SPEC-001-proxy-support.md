---
id: SPEC-001
title: Outbound proxy support
mode: reference
tier: 2
status: implemented
---

# Outbound proxy support

Issue #1 requires selectable outbound proxies for `crawl` and `crawl-site`.
Without route selection, crawls use the host address even when operators need another address or region.

## Requirements

### REQ-101

Resolve proxy fields using CLI > config > environment > disabled precedence.
A higher-priority server or pool replaces the lower-priority endpoint source. Credential fields merge independently.
Config `enabled: false` disables environment proxies; a CLI endpoint enables proxy routing again.
Environment names are `PROXY_URL`, `PROXY_SERVER`, `PROXY_USER`, and `PROXY_PASS`; URL wins over SERVER.
Verified by [[SPEC-001-proxy-support#TEST-101]].

### REQ-102

Select a pool endpoint atomically for each fetch attempt, including retries and robots requests.
`per-request` and `round-robin` cycle in order; `sticky` retains the first endpoint for that crawler.
Each crawler owns its selection state, even when its configuration is reused.
Verified by [[SPEC-001-proxy-support#TEST-102]].

### REQ-103

Route HTTP-adaptor, Playwright, and robots requests through the selected proxy.
A bypass domain matches the exact host and dot-boundary subdomains, case insensitively.
An optional leading dot has the same meaning. Service `use_proxy: false` is an explicit opt-out.
Verified by [[SPEC-001-proxy-support#TEST-103]].

### REQ-104

Proxy failure SHALL NOT cause implicit direct fallback.
Reject unsupported proxied services unless explicitly opted out. Reject authenticated SOCKS5 for Chromium before browser startup.
Verified by [[SPEC-001-proxy-support#TEST-105]].

### REQ-105

Proxy credentials SHALL NOT appear in diagnostics, result metadata, or curl child-process arguments.
Verified by [[SPEC-001-proxy-support#TEST-106]].

## Implementation contract

### CON-101

Use Racket `net/url` to parse URL structure and `net/uri-codec` to decode embedded credentials.
Use the platform `URL` parser at the JavaScript boundary.
Check supported schemes, nonempty hosts, ports 1..65535, credential completeness, and absence of paths, queries, fragments, and control characters.
Default omitted ports to 80 for HTTP and 1080 for SOCKS5.
These are proxy configuration checks; DNS/IP syntax and address resolution belong to existing libraries and transports.
No custom DNS/IPv6 grammar, parser generator, cross-language grammar format, or parser-specific size limits are required.

Racket's exported `url-regexp` preserves encoded userinfo boundaries before decoding, so encoded colons cannot silently change the username.
Reject bypass wildcards, whitespace, and transport rule delimiters within a domain entry.
Reject residual userinfo in a parsed host. Malformed configurations produce generic field errors without input values.

### ADR-101

Compose the existing URL libraries, curl transport, and Playwright proxy option.
Curl already supplies HTTP CONNECT, SOCKS5, proxy-side DNS, authentication, redirects, and timeout handling.
There is no custom HTTP or SOCKS implementation. Existing no-proxy fetching remains unchanged.
Proxy failure is observable through existing job metrics and generic transport errors.

## Verification

### TEST-101

`tests/test-proxy.rkt`: CLI/config/environment precedence, default ports, IPv6, embedded credential decoding, and invalid configuration fields.

### TEST-102

`tests/test-proxy.rkt`: wraparound, sticky selection, concurrent selection, and independent crawler instances.

### TEST-103

`tests/test_proxy_integration.py`: HTTP and SOCKS5 authentication, HTTPS CONNECT, bypass, redirects, robots, browser subresources, and pool rotation.
`playwright-service/tests/proxy-config.test.js`: native URL parsing, browser proxy configuration, and bypass expansion.

### TEST-104

Browser tests verify proxy forwarding, native URL parsing, unsupported authentication, and domain bypass expansion.

### TEST-105

Unit and wire tests reject unsupported services and browser authentication; a reachable origin remains untouched after a dead proxy fails.
Failed site pages are recorded without taking the first member of an empty result list.

### TEST-106

Wire tests capture diagnostics and curl invocation arguments to exclude fixture credentials.

## Delivery

Enable through flags, config, or the named environment variables; disable on the next invocation by removing those settings or setting `enabled: false`.
The repository maintainer reviews the pull request before merge.
