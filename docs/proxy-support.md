---
mode: how-to
title: How to select an outbound proxy
---

# How to select an outbound proxy

Use HTTP or SOCKS5 proxies with `crawl` and `crawl-site`. The HTTP adaptor requires `curl` on PATH; the Docker image includes it.

```bash
ar-crawl crawl https://example.com --proxy socks5://proxy.example.com:1080
ar-crawl crawl https://example.com --proxy http://proxy.example.com:8080 \
  --proxy-user alice --proxy-pass password --proxy-bypass '.local,.internal'
ar-crawl crawl-site https://example.com --proxy-list proxies.txt --proxy-rotation round-robin
ar-crawl crawl https://example.com -s playwright --proxy http://proxy.example.com:8080
```

Protect credential files with filesystem permissions. Command-line secrets remain visible in your shell history and the original CLI process arguments.
Proxy credentials are absent from crawler logs, result metadata, and curl child arguments.

A proxy list contains one URL per line. Blank lines and lines beginning with `#` are ignored.
Credentials in URLs use URI encoding. A username containing a colon is rejected; passwords can contain encoded colons.

```text
# proxies.txt
http://alice:password@proxy-a.example.com:8080
socks5://proxy-b.example.com:1080
```

`per-request` (the default) and `round-robin` cycle through entries for each fetch attempt, including retries and robots requests.
`sticky` uses the first entry for the crawler's lifetime. Redirects and browser subresources keep their page's selected proxy.

Use a JSON config to retain settings:

```json
{
  "proxy": {
    "enabled": true,
    "server": "http://${PROXY_HOST}:${PROXY_PORT}",
    "username": "${PROXY_USER}",
    "password": "${PROXY_PASS}",
    "bypass": [".local", ".internal"],
    "rotation": "per-request"
  }
}
```

Add this section to an existing crawler config. Use `pool` instead of `server` for an array of URLs.
Set `services.direct.use_proxy` or `services.playwright.use_proxy` to `false` for an explicit service opt-out.
When proxy routing is enabled, other services require that opt-out.

CLI values override config fields, which override environment fields. A server or pool replaces the lower-priority endpoint source.
Credential fields merge independently, and explicit credential fields override embedded credentials.
Environment variables are `PROXY_URL` (preferred over `PROXY_SERVER`), `PROXY_USER`, and `PROXY_PASS`.
Set config `proxy.enabled` to `false` to disable environment proxies; a CLI endpoint enables routing again.

A bypass domain matches its apex and subdomains at dot boundaries, case insensitively. A leading dot has the same meaning.
For example, `example.org` matches `example.org` and `sub.example.org`, but excludes `notexample.org`.
Only listed bypass domains or explicit service opt-outs use a direct connection. Proxy failure never silently switches to direct fetching.

The HTTP adaptor supports HTTP proxies for HTTP and HTTPS (CONNECT), plus SOCKS5 with optional username/password authentication.
SOCKS5 target DNS resolution occurs at the proxy. Playwright supports HTTP proxy authentication and unauthenticated SOCKS5.
Chromium rejects authenticated SOCKS5; use the HTTP adaptor for that combination.

Remove the flags and environment variables, or set `enabled: false`, to disable the feature on the next invocation.
The behaviour and acceptance contracts are in [[SPEC-001-proxy-support]].


Proxy URLs use the standard URL parsers. Omitted ports default to 80 for HTTP and 1080 for SOCKS5.
