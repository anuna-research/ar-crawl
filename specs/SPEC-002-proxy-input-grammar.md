---
id: SPEC-002
title: Grammar-derived proxy input recognition
status: implemented
tier: 2
mode: reference
---

# Grammar-derived proxy input recognition

## Orientation

Intent: Replace duplicated handwritten proxy regexes with one reviewable [[proxy-routing#Input grammar|input grammar]] that generates both boundary parsers.

```text
JSON BNF production table -> parser-tools/cfg-parser -> Racket endpoint AST
                         -> nearley                -> browser endpoint AST
```

Decisions: [[SPEC-002-proxy-input-grammar#ADR-102]] uses existing parser generators with a shared production table.
Load-bearing: [[SPEC-002-proxy-input-grammar#REQ-106]] grammar-derived recognition.
Controls:
- [[SPEC-002-proxy-input-grammar#CON-103]] requires full-input recognition before interpreting fields or making requests.
- [[SPEC-002-proxy-input-grammar#CON-103]] rejects URL paths, queries, fragments, and trailing data; only a final slash is permitted.
- [[SPEC-002-proxy-input-grammar#NFR-006]] bounds input length before parsing: endpoint 4096; wire endpoint 269; bypass host 254; bypass list 8192 characters; the suffix after a credential terminator is at most 269 characters.
- [[SPEC-002-proxy-input-grammar#CON-103]] permits explicit ports from 1 through 65535 and DNS labels up to 63 characters and DNS names up to 253 characters.
- [[SPEC-001-proxy-support#REQ-104]] prohibits implicit unproxied fallback.
- [[SPEC-001-proxy-support#REQ-105]] prohibits credentials in diagnostics.
Open: Maintainer reviews the parser change before merge.
Detail: [[SPEC-002-proxy-input-grammar#CON-103]], [[SPEC-002-proxy-input-grammar#Verification]].

## Amendment Channels

The user's request for a proper input grammar authorises this replacement through the existing pull request.
The repository maintainer can amend these obligations through review.
Hard stops: malformed input prevents network I/O; no channel implicitly waives routing or credential controls.

## Scope and failure

### BUG-103

The prior boundary uses separately handwritten hostname, IPv6, and endpoint regexes in Racket and JavaScript.
Those independent recognisers obscure the grammar and permit parser differences.
Root cause: implementation-error/langsec. Owner: implementer.
Source: user's request for a proper input grammar on 2026-10-26.
Violates: [[SPEC-002-proxy-input-grammar#REQ-106]]. Regression: [[SPEC-002-proxy-input-grammar#TEST-107]].

This successor replaces the recognition clauses of [[SPEC-001-proxy-support#CON-101]] and [[SPEC-001-proxy-support#CON-102]].
The routing, precedence, credential, rotation, bypass, and failure obligations of [[SPEC-001-proxy-support#Requirements]] remain governing requirements.

### REQ-106

The system SHALL derive both proxy boundary parsers from the same declared BNF production table.
Parsing returns a syntax tree; interpretation consumes that tree rather than reparsing raw endpoint strings.
Failure addressed: [[SPEC-002-proxy-input-grammar#BUG-103]].
Trace: [[SPEC-002-proxy-input-grammar#CON-103]], [[SPEC-002-proxy-input-grammar#TEST-107]], [[SPEC-002-proxy-input-grammar#TEST-108]], [[SPEC-002-proxy-input-grammar#OBS-102]].

### CON-103

Interface: endpoint and bypass recognition at the CLI/configuration and browser request boundaries.
Grammar source: `playwright-service/proxy-grammar.json`, a JSON BNF production table.
Each rule maps a nonterminal to alternative sequences of nonterminal names and literal terminals.
Named character classes expand to single-character terminal productions. The adapters introduce no additional language rules.
Racket uses `parser-tools/cfg-parser`; JavaScript uses `nearley`. Both return named syntax-tree nodes.

Entry points:
- `endpoint`: HTTP/SOCKS5 scheme, optional username/password, DNS or bracketed IPv6 host, explicit decimal port, optional final slash.
- `wire-endpoint`: the same language without embedded credentials.
- `bypass-host`: optional leading dot followed by a DNS name or IPv4 address.
- `bypass-list`: empty or a comma-separated list of bypass hosts.

IPv6 productions follow RFC 3986 section 3.2.2, including IPv4-embedded addresses.
URI credential characters and percent escapes follow RFC 3986 section 2; percent decoding happens after recognition.
Ports outside 1..65535, labels longer than 63 characters, names longer than 253 characters, decoded control characters, and colons in usernames fail semantic checks.
Credential completeness, supported service capabilities, and fail-closed routing retain their existing contracts.
Syntax errors become generic field errors without original input or parser diagnostics.
No request or credential interpretation occurs until the complete input matches an entry point.

Implements: [[SPEC-002-proxy-input-grammar#REQ-106]].
Verified by: [[SPEC-002-proxy-input-grammar#TEST-107]], [[SPEC-002-proxy-input-grammar#TEST-108]].

### NFR-006

Input length SHALL be bounded before invoking a parser.
The shared grammar source declares limits in characters: endpoint 4096; wire endpoint 269; bypass host 254; bypass list 8192.
Credential-free configured endpoints use the wire endpoint bound as well.
A credential-bearing endpoint has an additional 269-character bound on the suffix after its literal credential terminator.
These negative lexical filters enforce source-declared limits; acceptance still requires the complete grammar parser.
The wire endpoint bound accommodates the maximum DNS name, scheme, decimal port, and optional slash.
The CLI endpoint allowance also accommodates percent-encoded credentials; the bypass allowance accommodates multiple domains.
Over-limit inputs fail before parser allocation. The formerly slow malformed hostname has a regression bounded by a one-second subprocess timeout.
Trace: [[SPEC-002-proxy-input-grammar#TEST-108]], [[SPEC-002-proxy-input-grammar#OBS-102]].

### ADR-102

Existing parser generators consume the shared production table rather than separately maintained handwritten parser rules.
Racket's installed parser-tools library supplies the recogniser. Nearley supplies the JavaScript recogniser.
The adapters map production data to each library's public grammar API; they do not implement a parsing algorithm.
This adds one JavaScript parser dependency and declares the existing Racket parser dependency.
The CFG backend has a measured ceiling: near-limit credential-bearing inputs can take seconds to parse in the CLI.
The remotely exposed browser uses nearley and its shorter wire endpoint limit.
The raw reviewer measurements are retained in `specs/evidence/proxy-grammar-rereview-initial.txt`.
A faster grammar backend becomes necessary if large credential-bearing proxy pools become routine; owner: repository maintainer.
The shared file resides beside the browser service so standalone browser distributions include it without Racket at runtime.

A generated recogniser plus semantic bounds replaces regex chains and URL reparsing.
Numeric port bounds and DNS label lengths remain semantic constraints because they are clearer outside the grammar.

## Verification

### TEST-107

Validates: [[SPEC-002-proxy-input-grammar#REQ-106]]. Runnable core.
Run the same accepted and rejected endpoint/bypass corpus through both generated parsers.
Compare acceptance and interpreted endpoint fields. Include malformed percent escapes, trailing input, credentials, and invalid IPv6 compression.
Check both boundaries against the existing local transport suite.

### TEST-108

Validates: [[SPEC-002-proxy-input-grammar#REQ-106]], [[SPEC-002-proxy-input-grammar#NFR-006]]. Runnable core.
Exercise full and compressed IPv6, IPv4-embedded IPv6, label bounds, ports, and correctly decoded credentials.
Generate valid host/port examples and malformed suffixes. Mutate the shared grammar and verify both boundary tests reject the mutation.

### OBS-102

Existing generic configuration and browser errors report parse failure without source input or credentials.
No new metrics or logging transport is introduced.

## Enable path and review

This replacement takes effect with the updated executable and browser service; existing flags and configuration shapes remain unchanged.
Rollback uses the preceding branch commit. No independent runtime switch is needed for this parser correction.
Tier 2 cross-model fresh-context review applies. Temporal logic and synthetic-user studies add no evidence for this input grammar and are skipped.

Reviewer path: [[SPEC-002-proxy-input-grammar#ADR-102]] then [[SPEC-002-proxy-input-grammar#CON-103]].
Implementer path: [[SPEC-002-proxy-input-grammar#CON-103]] then [[SPEC-002-proxy-input-grammar#Verification]].
Stakeholder path: [[SPEC-002-proxy-input-grammar#Scope and failure]] then [[SPEC-002-proxy-input-grammar#REQ-106]].
