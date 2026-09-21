---
title: How to monitor the crawler
mode: how-to
---

# How to monitor the crawler

This guide covers checking health and watching metrics while a crawl runs.

## Health Checks

Check overall system health:
```bash
ar-crawl health --verbose
```

Monitor services in real-time:
```bash
ar-crawl monitor --interval 10
```

## Metrics

The crawler collects metrics on:
- Request success/failure rates
- Response times
- Service availability
- Error types and frequencies

## Logging

Logs are written to:
- Console (controlled by log level)
- File logs (in `logs/` directory when configured)
- Docker logs (when running in containers)

Log levels: `debug`, `info`, `warning`, `error`
