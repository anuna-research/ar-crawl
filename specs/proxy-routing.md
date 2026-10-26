---
mode: reference
title: Proxy routing vocabulary
---

# Proxy routing vocabulary

## Proxy

An intermediary connects the crawler to a target. A direct connection reaches the target without that intermediary.
The HTTP adaptor is a crawler component; its name does not imply an unproxied connection.

## Proxy Pool

An ordered collection of recognised endpoints. A selector retains its own index for one crawler instance.

## HTTP CONNECT

The HTTP proxy establishes a tunnel to the HTTPS origin. TLS certificate verification remains enabled at the crawler.

## SOCKS5

A proxy protocol supporting target connections and optional username/password authentication.
The HTTP adaptor delegates DNS resolution to the proxy. Browser support excludes username/password authentication.

## curl

The existing platform HTTP client supplies HTTP proxy, CONNECT, SOCKS5, timeout, and redirect handling.
Reference: https://curl.se/docs/manpage.html.

## Playwright

The local browser service accepts recognised proxy settings when creating an isolated browser context.
Reference: https://playwright.dev/docs/api/class-browser#browser-new-context-option-proxy.

## URL recognition

Racket `net/url` and the browser's WHATWG URL implementation parse endpoint structure.
Anchored regular grammars restrict hosts, credentials, schemes, ports, bypass domains, and permitted URL components.

## Configuration

CLI fields, JSON configuration, and named environment variables resolve in that priority order.
Explicit credential fields override embedded fields. Recognition completes before network requests.
