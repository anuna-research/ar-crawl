---
title: How to recover from common failures
mode: how-to
---

# How to recover from common failures

This guide covers the errors a first crawl runs into, and the way out of each.

## Common Issues

**"No API key found"**
- Ensure API keys are set in `.env` file
- Check configuration file has correct variable names
- Verify environment variable substitution is working

**"Service unavailable"**
- Check service health: `ar-crawl health`
- Verify API keys are valid
- Check service-specific status pages

**"Rate limit exceeded"**
- Increase `rate_limit_ms` in configuration
- Use premium proxy services
- Spread requests across multiple services

## Debug Mode

Enable verbose logging:
```bash
ar-crawl crawl https://example.com --verbose
```

Check configuration:
```bash
ar-crawl config show --file config/default.json
```

## Getting Help

- Check command help: `ar-crawl <command> --help`
- View configuration: `ar-crawl config show`
- Test services: `ar-crawl test --verbose`
- Monitor in real-time: `ar-crawl monitor`

Exit codes are in the [CLI reference](../reference/cli.md).
