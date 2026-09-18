---
title: How to deploy with Docker
mode: how-to
---

# How to deploy with Docker

This guide covers running ar-crawl in containers, for a reader with Docker and Docker Compose installed.

## Build and Run

```bash
# Build Docker image
make docker-build

# Run with Docker Compose
make docker-run

# View logs
make docker-logs

# Stop containers
make docker-stop
```

## Docker Compose Services

The `docker-compose.yml` includes:

- **ar-crawl** - Main crawler service
- **redis** - Caching and rate limiting (opt in)
- **postgres** - Result storage (opt in)
- **prometheus** - Metrics collection (opt in)
- **grafana** - Monitoring dashboards (opt in)

## Production Deployment

1. **Setup production configuration:**
   ```bash
   make prod-setup
   ```

2. **Configure environment variables:**
   ```bash
   cp .env.example .env
   # Edit .env with your production values
   ```

3. **Deploy with Docker:**
   ```bash
   docker-compose -f docker-compose.yml -f docker-compose.prod.yml up -d
   ```
