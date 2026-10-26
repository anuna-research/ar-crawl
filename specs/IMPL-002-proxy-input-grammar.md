---
id: IMPL-002
title: Shared proxy grammar implementation
status: implemented
---

# Shared proxy grammar implementation

Governing specification: [[SPEC-002-proxy-input-grammar]].

The BNF production table supplies both mature parser engines. The adapters only translate literal terminals, named productions, and character classes.
Racket embeds generated parser tables during compilation. The browser service loads the same BNF beside its existing JavaScript modules.

| Work | Owner | Governing clause | Acceptance |
|---|---|---|---|
| grammar replacement | implementer | [[SPEC-002-proxy-input-grammar#REQ-106]] | [[SPEC-002-proxy-input-grammar#TEST-107]], [[SPEC-002-proxy-input-grammar#TEST-108]], inherited transport suite |
| review | fresh-context reviewer | [[SPEC-002-proxy-input-grammar#CON-103]] | No remaining concrete recognition or parser-difference blockers |

The initial shared corpus fails against the preceding endpoint recogniser on IPv4-embedded IPv6.
Red evidence: `specs/evidence/proxy-grammar-red.txt`.

The shared grammar and corpus remain reviewable source. No generated source blobs are checked in.
Parser errors are masked at both boundaries; tests inspect both acceptance and the parsed credential fields.

## Review trajectory

Fresh-context cross-model reviewer: `gpt-6-astra`, specification plus deliverable only.
The initial review found oversized browser input monopolised synchronous parsing.
The shared source now bounds input before parser allocation; left-recursive sequence rules and iterative JavaScript AST walks avoid repeated traversal.
Follow-up review found credential-prefixed malformed hosts bypassed the short wire bound.
The grammar-derived negative lexical filter now also bounds the authority suffix; complete parser recognition still decides acceptance.
Raw findings and final acceptance are retained in `specs/evidence/proxy-grammar-review.txt`, `proxy-grammar-rereview-initial.txt`, and `proxy-grammar-accepted-review.txt`.

The first comprehension reader failed to determine trailing-path behaviour from the Orientation.
The final Orientation explicitly states that paths, queries, fragments, and trailing data are rejected.
Reader `grammar_final_orientation_gate` received only that Orientation and correctly predicted path rejection, port rejection, and early oversized-input rejection.

The shared-grammar mutation initially survived because the harness ran cached Racket bytecode without rebuilding its external grammar dependency.
This failure attributes to [[SPEC-002-proxy-input-grammar#TEST-107]]. The harness now compiles before each check and after restoring source.
The build registers the grammar as an external compiler dependency. Runtime parser tables remain embedded in the executable.

The documented near-limit CLI credential parsing ceiling remains explicit in [[SPEC-002-proxy-input-grammar#ADR-102]].

## Reproduction

```sh
raco make src/cli.rkt
raco test src tests
npm ci --prefix playwright-service --ignore-scripts
node --test playwright-service/tests/*.test.js
python3 -m unittest discover -s tests -p 'test_proxy_integration.py' -v
python3 scripts/test-proxy-mutations.py
```

Run the mutation harness without concurrent source edits or test processes. It restores and recompiles each changed source.
Rebuild after changing `playwright-service/proxy-grammar.json`; both source runtimes then consume the same production table.

The maintainer acts next: review the parser change on the existing pull request before merging.
