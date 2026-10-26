# AR-Crawl Production Dockerfile
FROM racket/racket:8.10-full

# Set working directory
WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    ca-certificates \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Install Racket packages
RUN raco pkg install --auto \
    html-parsing \
    uuid \
    http123 \
    data-lib

# Copy source code
COPY src/ ./src/
COPY config/ ./config/

# Create directories
RUN mkdir -p output temp logs

# Set environment variables
ENV RACKET_PATH=/app/src
ENV LOG_LEVEL=info
ENV OUTPUT_DIR=/app/output

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD racket src/cli.rkt health || exit 1

# Create entrypoint script
RUN echo '#!/bin/bash\n\
set -e\n\
\n\
# Check if config exists\n\
if [ ! -f "config/production.json" ] && [ ! -f "config/default.json" ]; then\n\
    echo "Creating default configuration..."\n\
    racket src/cli.rkt config init --file config/default.json\n\
fi\n\
\n\
# Execute command\n\
exec "$@"' > /app/entrypoint.sh

RUN chmod +x /app/entrypoint.sh

# Expose port for potential web interface
EXPOSE 8080

# Set entrypoint
ENTRYPOINT ["/app/entrypoint.sh"]

# Default command
CMD ["racket", "src/cli.rkt", "services"]
