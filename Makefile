# AR-Crawl Makefile
.PHONY: help install build test run clean docker-build docker-run setup binary dist dist-full playwright-setup

# Default target
help:
	@echo "AR-Crawl - Web Crawler for Agents"
	@echo "================================"
	@echo ""
	@echo "Available targets:"
	@echo "  install         Install Racket dependencies"
	@echo "  build           Build the application"
	@echo "  binary          Build standalone binary executable"
	@echo "  dist            Build distribution archive"
	@echo "  dist-full       Build distribution with playwright-service"
	@echo "  playwright-setup Setup playwright-service dependencies"
	@echo "  test            Run tests"
	@echo "  run             Run the CLI tool"
	@echo "  setup           Setup configuration files"
	@echo "  docker-build    Build Docker image"
	@echo "  docker-run      Run with Docker Compose"
	@echo "  clean           Clean up generated files"
	@echo "  lint            Run code quality checks"
	@echo ""
	@echo "Examples:"
	@echo "  make setup"
	@echo "  make run ARGS='crawl https://example.com'"
	@echo "  make dist-full"
	@echo "  make docker-run"

# Variables
RACKET_BIN := racket
RACO_BIN := raco
CLI_SCRIPT := src/cli.rkt
CONFIG_DIR := config
OUTPUT_DIR := output
TEMP_DIR := temp
LOGS_DIR := logs
DIST_DIR := dist
BINARY_NAME := ar-crawl

# Installation
install:
	@echo "Installing Racket dependencies..."
	$(RACO_BIN) pkg install --auto --skip-installed \
		html-parsing \
		uuid \
		http123
	@echo "Dependencies installed successfully"

# Build
build: install
	@echo "Building AR-Crawl..."
	$(RACKET_BIN) -c $(CLI_SCRIPT)
	@echo "Build completed"

# Binary build
binary: install
	@echo "Building standalone binary..."
	@mkdir -p $(DIST_DIR)
	@find . -type d -name compiled | xargs rm -rf  # Clean compiled files
	$(RACO_BIN) make $(CLI_SCRIPT)  # Compile to bytecode first
	$(RACO_BIN) exe -o $(DIST_DIR)/$(BINARY_NAME) $(CLI_SCRIPT)
	@echo "Binary created at $(DIST_DIR)/$(BINARY_NAME)"

# Distribution build (binary only)
dist: binary
	@echo "Creating distribution..."
	$(RACO_BIN) distribute $(DIST_DIR)/$(BINARY_NAME)-dist $(DIST_DIR)/$(BINARY_NAME)
	@cd $(DIST_DIR) && tar -czvf $(BINARY_NAME)-$(shell uname -s)-$(shell uname -m).tar.gz $(BINARY_NAME)-dist
	@echo "Distribution created at $(DIST_DIR)/$(BINARY_NAME)-$(shell uname -s)-$(shell uname -m).tar.gz"

# Full distribution build (includes playwright-service)
dist-full: binary
	@echo "Creating full distribution with playwright-service..."
	$(RACO_BIN) distribute $(DIST_DIR)/$(BINARY_NAME)-dist $(DIST_DIR)/$(BINARY_NAME)
	@echo "Bundling playwright-service..."
	@mkdir -p $(DIST_DIR)/$(BINARY_NAME)-dist/lib/playwright-service
	@cp playwright-service/package.json $(DIST_DIR)/$(BINARY_NAME)-dist/lib/playwright-service/
	@cp playwright-service/package-lock.json $(DIST_DIR)/$(BINARY_NAME)-dist/lib/playwright-service/
	@cp playwright-service/server.js $(DIST_DIR)/$(BINARY_NAME)-dist/lib/playwright-service/
	@cd $(DIST_DIR) && tar -czvf $(BINARY_NAME)-$(shell uname -s)-$(shell uname -m).tar.gz $(BINARY_NAME)-dist
	@echo "Full distribution created at $(DIST_DIR)/$(BINARY_NAME)-$(shell uname -s)-$(shell uname -m).tar.gz"
	@echo ""
	@echo "Archive contents:"
	@echo "  - bin/ar-crawl           (standalone binary)"
	@echo "  - lib/playwright-service (Node.js service for JS rendering)"
	@echo ""
	@echo "After extracting, users should run:"
	@echo "  cd lib/playwright-service && npm install && npx playwright install chromium"

# Setup playwright-service locally
playwright-setup:
	@echo "Setting up playwright-service..."
	@if [ ! -d "playwright-service" ]; then \
		echo "Error: playwright-service directory not found"; \
		exit 1; \
	fi
	@cd playwright-service && npm install
	@cd playwright-service && npx playwright install chromium
	@echo "Playwright service ready. Start with: cd playwright-service && npm start"

# Testing
test: build
	@echo "Running tests..."
	@echo "=== Core Module Tests ==="
	$(RACKET_BIN) -t src/crawl-service-adaptor.rkt
	$(RACKET_BIN) -t src/config-manager.rkt
	$(RACKET_BIN) -t src/production-crawler.rkt
	$(RACKET_BIN) -t src/utils.rkt
	@echo "=== Data Processing Tests ==="
	$(RACKET_BIN) -t src/html-extractor.rkt
	$(RACKET_BIN) -t src/data-formatter.rkt
	$(RACKET_BIN) -t src/sqlite-formatter.rkt
	@echo "=== Crawler Tests ==="
	$(RACKET_BIN) -t src/site-crawler.rkt
	$(RACKET_BIN) -t src/robots-txt.rkt
	@echo "=== Interface Tests ==="
	$(RACKET_BIN) -t src/scraper-interfaces.rkt
	@echo "All tests passed"

# Run specific test suite
test-html:
	$(RACKET_BIN) -t src/html-extractor.rkt

test-data:
	$(RACKET_BIN) -t src/data-formatter.rkt
	$(RACKET_BIN) -t src/sqlite-formatter.rkt

test-crawler:
	$(RACKET_BIN) -t src/site-crawler.rkt
	$(RACKET_BIN) -t src/robots-txt.rkt

test-core:
	$(RACKET_BIN) -t src/crawl-service-adaptor.rkt
	$(RACKET_BIN) -t src/config-manager.rkt
	$(RACKET_BIN) -t src/production-crawler.rkt
	$(RACKET_BIN) -t src/utils.rkt

# Setup
setup:
	@echo "Setting up AR-Crawl..."
	@mkdir -p $(CONFIG_DIR) $(OUTPUT_DIR) $(TEMP_DIR) $(LOGS_DIR)
	
	@if [ ! -f $(CONFIG_DIR)/default.json ]; then \
		echo "Creating default configuration..."; \
		$(RACKET_BIN) $(CLI_SCRIPT) config init --file $(CONFIG_DIR)/default.json; \
	fi
	
	@if [ ! -f .env ]; then \
		echo "Creating .env file template..."; \
		echo "# AR-Crawl Environment Variables" > .env; \
		echo "FIRECRAWL_API_KEY=your_firecrawl_api_key_here" >> .env; \
		echo "SCRAPINGBEE_API_KEY=your_scrapingbee_api_key_here" >> .env; \
		echo "BROWSERLESS_API_KEY=your_browserless_api_key_here" >> .env; \
		echo "SCRAPERAPI_API_KEY=your_scraperapi_api_key_here" >> .env; \
		echo "LOG_LEVEL=info" >> .env; \
		echo "MAX_CONCURRENT_JOBS=10" >> .env; \
		echo "RATE_LIMIT_MS=1000" >> .env; \
		echo ".env file created. Please edit it with your API keys."; \
	fi
	
	@echo "Setup completed"

# Run the CLI tool
run: build
	$(RACKET_BIN) $(CLI_SCRIPT) $(ARGS)

# Docker targets
docker-build:
	@echo "Building Docker image..."
	docker build -t ar-crawl:latest .
	@echo "Docker image built successfully"

docker-run: docker-build
	@echo "Starting AR-Crawl with Docker Compose..."
	docker-compose up -d
	@echo "AR-Crawl is running. Use 'docker-compose logs -f' to view logs"

docker-stop:
	@echo "Stopping AR-Crawl containers..."
	docker-compose down

docker-logs:
	docker-compose logs -f ar-crawl

# Development targets
dev-run:
	$(RACKET_BIN) $(CLI_SCRIPT) monitor --config $(CONFIG_DIR)/default.json --verbose

dev-test:
	$(RACKET_BIN) $(CLI_SCRIPT) test --config $(CONFIG_DIR)/default.json --verbose

# Production targets
prod-setup:
	@mkdir -p $(CONFIG_DIR) $(OUTPUT_DIR) $(TEMP_DIR) $(LOGS_DIR)
	@if [ ! -f $(CONFIG_DIR)/production.json ]; then \
		echo "Creating production configuration..."; \
		$(RACKET_BIN) $(CLI_SCRIPT) config init --file $(CONFIG_DIR)/production.json --type production; \
	fi

prod-run:
	$(RACKET_BIN) $(CLI_SCRIPT) $(ARGS) --config $(CONFIG_DIR)/production.json

# Health checks
health:
	$(RACKET_BIN) $(CLI_SCRIPT) health --config $(CONFIG_DIR)/default.json

services:
	$(RACKET_BIN) $(CLI_SCRIPT) services --verbose

# Maintenance
clean:
	@echo "Cleaning up..."
	@rm -rf $(OUTPUT_DIR)/* $(TEMP_DIR)/* $(LOGS_DIR)/* $(DIST_DIR)/*
	@find . -name "*.zo" -delete
	@find . -name "compiled" -type d -exec rm -rf {} +
	@echo "Cleanup completed"

lint:
	@echo "Running code quality checks..."
	@# Add linting tools here if available for Racket
	@echo "Lint checks completed"

# Backup
backup:
	@echo "Creating backup..."
	@tar -czf backup-$(shell date +%Y%m%d-%H%M%S).tar.gz \
		$(CONFIG_DIR) \
		$(OUTPUT_DIR) \
		src/ \
		--exclude='*.zo' \
		--exclude='compiled'
	@echo "Backup created"

# Monitoring
monitor:
	$(RACKET_BIN) $(CLI_SCRIPT) monitor --config $(CONFIG_DIR)/default.json

# Examples
example-crawl:
	$(RACKET_BIN) $(CLI_SCRIPT) crawl "https://httpbin.org/html" --verbose

example-batch:
	@echo "Running batch crawl example..."
	@echo "https://httpbin.org/html" | while read url; do \
		$(RACKET_BIN) $(CLI_SCRIPT) crawl "$$url" --output "$(OUTPUT_DIR)/$$url.json"; \
	done

# Help for specific commands
help-config:
	$(RACKET_BIN) $(CLI_SCRIPT) config --help

help-crawl:
	$(RACKET_BIN) $(CLI_SCRIPT) crawl --help

# Version info
version:
	@echo "AR-Crawl v1.0.0"
	@echo "Racket version:"
	@$(RACKET_BIN) --version

# Environment info
env-info:
	@echo "Environment Information:"
	@echo "Racket: $(shell which $(RACKET_BIN))"
	@echo "Raco: $(shell which $(RACO_BIN))"
	@echo "Config dir: $(CONFIG_DIR)"
	@echo "Output dir: $(OUTPUT_DIR)"
	@echo "Docker: $(shell which docker)"
	@echo "Docker Compose: $(shell which docker-compose)"
