---
id: SPEC-001
title: Outbound proxy selection
status: superseded
tier: 2
mode: reference
---

# Outbound proxy selection

Recognition contracts are superseded by [[SPEC-002-proxy-input-grammar]]. Routing requirements remain applicable.

## Orientation

Intent: Give crawl operators control over outbound [[proxy-routing#Proxy|proxy]] addresses without silently switching to an unrequested direct connection.

Structure (arrows show calls):

```text
CLI/config -> CON-101 recogniser -> proxy pool
crawler -> pool -> HTTP adaptor/curl or Playwright -> target
site robots request -> pool -> HTTP adaptor/curl -> target
```

Decisions: [[SPEC-001-proxy-support#ADR-101]] composes [[proxy-routing#curl|curl]] and native [[proxy-routing#Playwright|Playwright]] proxy support.
Load-bearing: [[SPEC-001-proxy-support#REQ-101]] CLI/config/environment precedence; [[SPEC-001-proxy-support#REQ-102]] rotation; [[SPEC-001-proxy-support#REQ-103]] routing.

Controls:
- [[SPEC-001-proxy-support#CON-101]] accepts HTTP/SOCKS5 endpoints with explicit ports from 1 through 65535; rejects malformed configuration before requests.
- [[SPEC-001-proxy-support#REQ-104]] proxy failures never trigger an implicit direct fallback; unsupported services require explicit `use_proxy: false`.
- [[SPEC-001-proxy-support#REQ-105]] diagnostics never contain proxy credentials.
- [[SPEC-001-proxy-support#CON-102]] authenticated SOCKS5 is supported by the HTTP adaptor through curl; Playwright rejects it before browser creation.

Open: Maintainer reviews the pull request before merge. Public proxy performance testing is deferred to operators; deterministic local fixtures govern acceptance.
Detail: [[SPEC-001-proxy-support#CON-101]], [[SPEC-001-proxy-support#CON-102]], [[SPEC-001-proxy-support#Verification]].

## Failure mode and intent

### BUG-101

Crawls have no outbound route selection. A blocked or geographically unsuitable host address prevents otherwise valid research requests.
An automatic direct fallback also defeats the operator's explicit address selection.
Source: Forgejo issue #1, retrieved with `fj issue view 1` on 2026-10-26.
The operator is the existing [[users/devops-engineer/user|DevOps user]]. Their path is configure, run, inspect success or a credential-free error.

## Amendment Channels

The repository maintainer can amend this specification through issue clarification or pull-request review.
Hard stops: malformed configuration, unsupported proxied services, and unsupported browser authentication stop before fetching.
No amendment implicitly waives credential redaction or authorises silent direct fallback.

## Requirements

### REQ-101

Failure addressed: [[SPEC-001-proxy-support#BUG-101]].

The system SHALL resolve proxy fields using CLI > config > environment > disabled precedence.
Environment names are `PROXY_URL`, `PROXY_SERVER`, `PROXY_USER`, and `PROXY_PASS`; URL wins over SERVER.
A higher-priority server or pool replaces the lower-priority endpoint source; other fields merge independently.
Explicit config `enabled: false` disables environment proxies; a CLI endpoint enables them again.
Missing proxy configuration preserves existing behaviour.
Trace: [[SPEC-001-proxy-support#TEST-101]], [[SPEC-001-proxy-support#CON-101]], [[SPEC-001-proxy-support#OBS-101]].

### REQ-102

Failure addressed: [[SPEC-001-proxy-support#BUG-101]].

The system SHALL select [[proxy-routing#Proxy Pool|proxy pool]] endpoints atomically per outbound fetch attempt.
`per-request` and `round-robin` cycle in file order, including retries; `sticky` retains the first entry for the crawler lifetime.
The default is `per-request`, matching the issue's proposed default.
A single endpoint behaves as a pool with one member. Redirects and browser subresources retain that attempt's endpoint.
Trace: [[SPEC-001-proxy-support#TEST-102]], [[SPEC-001-proxy-support#CON-101]], [[SPEC-001-proxy-support#OBS-101]].

### REQ-103

Failure addressed: [[SPEC-001-proxy-support#BUG-101]].

The system SHALL route direct HTTP/HTTPS, Playwright page requests, and site robots fetches through the selected proxy.
Explicit bypass entries permit direct connections for exact hosts and dot-boundary subdomains.
A leading dot permits the domain itself and its subdomains; matching is case insensitive.
Bypass applies across redirects and browser subresources through native transport rules.
HTTP proxy authentication and embedded credentials are supported; direct SOCKS5 also supports username/password authentication.
Service `use_proxy: false` is an explicit opt-out. No pool or selection state is shared across crawler instances.
Trace: [[SPEC-001-proxy-support#TEST-103]], [[SPEC-001-proxy-support#TEST-104]], [[SPEC-001-proxy-support#CON-102]], [[SPEC-001-proxy-support#OBS-101]].

### REQ-104

Failure addressed: [[SPEC-001-proxy-support#BUG-101]].

The system SHALL NOT retry a proxied request through an implicit direct connection after proxy failure.
Non-direct/non-Playwright services are rejected with proxy enabled unless explicitly opted out.
Malformed settings stop configuration before any target request, including browser startup and robots requests.
Trace: [[SPEC-001-proxy-support#TEST-105]], [[SPEC-001-proxy-support#CON-101]], [[SPEC-001-proxy-support#OBS-101]].

### REQ-105

Failure addressed: [[SPEC-001-proxy-support#BUG-101]].

The system SHALL NOT expose proxy credentials in logs, errors, result metadata, or child-process arguments.
Credentials reach curl through its standard-input configuration and Playwright through the local JSON request.
Operators protect config and pool files with filesystem permissions; CLI/env credential entry remains an explicit issue requirement.
Trace: [[SPEC-001-proxy-support#TEST-106]], [[SPEC-001-proxy-support#CON-102]], [[SPEC-001-proxy-support#OBS-101]].

### BUG-102

Severity: S2; priority: P2; status: verified; owner: implementer.
Failure: a failed site page produces an empty result list; taking its first member raises an exception.
Root cause: implementation-error; the success extraction assumes a non-empty list before inspecting job success.
The repair checks list membership before taking its first member. The existing failed-request regression exercises this path.
Violates: [[SPEC-001-proxy-support#REQ-104]]. Verified by: [[SPEC-001-proxy-support#TEST-105]].

## Contracts

### CON-101

Interface: shared Racket proxy recogniser, resolver, pool selector, and CLI flags on `crawl` and `crawl-site`.
Parser: [[proxy-routing#URL recognition|URL recognition]] uses `net/url` for endpoint URLs; anchored regular-language recognition for the constrained endpoint and bypass syntax; JSON via `json`.
Recognition finishes for every pool entry before constructing a pool or doing network I/O.

```text
proxy-object = JSON object with optional fields:
  enabled: boolean; server: endpoint; username/password: string;
  bypass: array of bypass-host; rotation: "per-request" | "round-robin" | "sticky";
  pool: array of endpoint
endpoint = ("http://" | "socks5://") [userinfo "@"] host ":" port ["/"]
userinfo = URI-encoded user [":" URI-encoded password]
host = DNS labels | IPv4 | "[" hexadecimal-IPv6 "]"
DNS-label = ALNUM [0*61(ALNUM | "-") ALNUM]
DNS labels = DNS-label *("." DNS-label)
hexadecimal-IPv6 = RFC 4291 hexadecimal groups with optional single "::" compression
username = URI user characters excluding literal or percent-encoded colon
port = decimal integer in [1,65535]
bypass-host = ["."] DNS labels | IPv4
pool-file = UTF-8 lines of endpoint, blank lines, or lines beginning "#"
```

Unknown proxy keys, wrong field types, empty enabled pools, conflicting CLI server/list, URL paths/query/fragments, and incomplete credentials are errors.
CLI flags are `--proxy`, `--proxy-user`, `--proxy-pass`, `--proxy-bypass`, `--proxy-list`, and `--proxy-rotation`.
Every effective endpoint carries either both credential fields or neither. Single-field overrides retain the other embedded field.
An empty bypass list is valid. Empty string credentials are valid only as a complete pair.
CLI credentials override embedded credentials; explicit fields override embedded fields in other sources too.
Implements: [[SPEC-001-proxy-support#REQ-101]], [[SPEC-001-proxy-support#REQ-102]], [[SPEC-001-proxy-support#REQ-104]].
Verified by: [[SPEC-001-proxy-support#TEST-101]], [[SPEC-001-proxy-support#TEST-102]], [[SPEC-001-proxy-support#TEST-105]].

### CON-102

Interface: direct adaptor receives a recognised proxy hash; Playwright `/fetch` accepts `proxy: {server, username?, password?, bypass?}`.
The browser boundary recognises the same endpoint subset with WHATWG URL and field type checks before browser creation.
Wire endpoints contain no userinfo; credentials use separate fields. Browser bypass is a comma-separated string of recognised bypass hosts.
Curl receives `--disable` first, explicit `--proxy`, explicit `--noproxy`, HTTP/HTTPS-only protocols, and bounded timeout/redirect options.
A failed process returns failure without forwarding its stderr. Browser proxy failures use a generic credential-free error.
Chromium does not support authenticated SOCKS5; this combination is refused before fetching rather than misrepresented as supported.
Implements: [[SPEC-001-proxy-support#REQ-103]], [[SPEC-001-proxy-support#REQ-104]], [[SPEC-001-proxy-support#REQ-105]].
Verified by: [[SPEC-001-proxy-support#TEST-103]], [[SPEC-001-proxy-support#TEST-104]], [[SPEC-001-proxy-support#TEST-105]], [[SPEC-001-proxy-support#TEST-106]].

### ADR-101

Use curl for proxied direct fetches and Playwright's native context proxy for browser fetches.
This settles at the native-platform/existing-component rungs: curl already ships in the Docker image and supports [[proxy-routing#HTTP CONNECT|HTTP CONNECT]] and SOCKS5 authentication.
The current Racket HTTP transport lacks SOCKS5 support. Adding another HTTP library and SOCKS package duplicates a capability curl already provides.
The proxy module owns configuration and atomic selection because both transports and robots fetching need the same semantics.
Existing no-proxy fetching remains unchanged. No custom HTTP, SOCKS, or URL parser is introduced.
Evidence: curl manual https://curl.se/docs/manpage.html and browser API https://playwright.dev/docs/api/class-browser#browser-new-context-option-proxy.
Raw curl evidence was retrieved with ar-crawl into `/tmp/ar-crawl-proxy-curl-evidence.json`.

## Enable path

New invocations enable proxy routing with a CLI endpoint, enabled config, or the named environment variables.
Remove the flags/environment or set config `enabled: false` to roll back on the next invocation; no redeploy is needed.
This feature changes only explicitly configured invocations. The operator receives configuration errors before requests start.

## Purity boundary

Resolution and recognition are pure except pool-file reading at the CLI shell. The selector owns only per-crawler locked rotation state.
Transports consume recognised hashes and own network/process effects. Secrets are omitted from pool printing and crawler startup logging.

## Verification

Each test below is runnable core; no external proxy or new test infrastructure is required.
Example tests, malformed-input tables, local protocol fixtures, and deliberate mutation govern acceptance.
Temporal logic and synthetic-user studies are skipped: this change specifies no response/liveness bound beyond the existing transport timeout.

### TEST-101

Validates: [[SPEC-001-proxy-support#REQ-101]]. Test CLI/config/env precedence, disabled config, source replacement, and independent credentials.
Reject wrong types, unsupported schemes, missing ports, paths, malformed escape sequences, and conflicting endpoints.

### TEST-102

Validates: [[SPEC-001-proxy-support#REQ-102]]. Check wraparound, sticky behaviour, concurrent selections, and independent crawler pools.
Reject invalid rotation, empty pools, and a malformed entry after a valid entry before any fetch.

### TEST-103

Validates: [[SPEC-001-proxy-support#REQ-103]]. Local HTTP and SOCKS fixtures observe authentication and target routing; bypass reaches a local origin directly.
Negative cases cover wrong credentials, dead proxy, and suffix-confusion bypass hosts. HTTPS CONNECT uses a local TLS origin where available.

### TEST-104

Validates: [[SPEC-001-proxy-support#REQ-103]]. Browser boundary tests verify context proxy forwarding and omitted proxy when disabled.
A local browser integration fixture verifies actual HTTP proxy routing and bypass, including subresources.

### TEST-105

Validates: [[SPEC-001-proxy-support#REQ-104]]. Prohibited-action tests keep a reachable origin untouched after dead proxy failure.
Scope tests reject unsupported services without calling them, while explicit opt-out remains permitted.
Verify robots uses the selected proxy instead of a separate direct fetch.

### TEST-106

Validates: [[SPEC-001-proxy-support#REQ-105]]. Capture stdout/stderr and inspect child invocation to exclude embedded and explicit credentials.
Reject browser SOCKS credentials, malformed payloads, unknown fields, and injected control characters without echoing input.

### OBS-101

Existing job success/failure metrics and generic transport errors report routing outcomes.
Configuration errors identify the field or capability without values. Proxy URLs and credentials are absent from logs and result metadata.

## Delivery evidence

Implementation ledger and reviewer handoff: [[IMPL-001-proxy-support]].

## Reading paths

Reviewer: [[SPEC-001-proxy-support#ADR-101]] then [[SPEC-001-proxy-support#Amendment Channels]].
Implementer: [[SPEC-001-proxy-support#CON-101]] then [[SPEC-001-proxy-support#Verification]] then the linked requirements.
Stakeholder: [[SPEC-001-proxy-support#Failure mode and intent]] then [[SPEC-001-proxy-support#Requirements]].
