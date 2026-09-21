---
title: How to configure services
mode: how-to
---

# How to configure services

This guide covers pointing ar-crawl at the crawling services you have keys for, for a reader who has installed it.

## Create, inspect and validate a configuration

- **`config init`** - Create configuration file
  ```bash
  ar-crawl config init --file config/production.json --type production
  ```

- **`config show`** - Display current configuration
  ```bash
  ar-crawl config show --file config/default.json
  ```

- **`config validate`** - Validate configuration
  ```bash
  ar-crawl config validate --file config/production.json
  ```

## Set API keys

Edit the `.env` file `make setup` created:

   ```bash
   FIRECRAWL_API_KEY=your_firecrawl_api_key_here
   SCRAPINGBEE_API_KEY=your_scrapingbee_api_key_here
   BROWSERLESS_API_KEY=your_browserless_api_key_here
   SCRAPERAPI_API_KEY=your_scraperapi_api_key_here
   ```

The direct and Playwright services need no key. Keys, file structure and every variable are in the [configuration reference](../reference/configuration.md); what each service offers is in [Crawling services](../reference/services.md).
