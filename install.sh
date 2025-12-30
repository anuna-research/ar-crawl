#!/bin/bash
set -e

# AR-Crawl Installer
# Installs ar-crawl binary and optionally sets up playwright-service
#
# Usage:
#   curl -fsSL https://codeberg.org/anuna/ar-crawl/raw/branch/main/install.sh | bash
#
# Environment variables:
#   VERSION       - Version to install (default: latest)
#   INSTALL_DIR   - Binary install directory (default: ~/.local/bin)
#   LIB_DIR       - Library install directory (default: ~/.local/lib/ar-crawl)
#   SKIP_PLAYWRIGHT - Set to 1 to skip Playwright setup

TOOL_NAME="ar-crawl"
VERSION="${VERSION:-latest}"
BASE_URL="https://codeberg.org/anuna/ar-crawl/releases"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
LIB_DIR="${LIB_DIR:-$HOME/.local/lib/ar-crawl}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Detect OS and architecture
detect_platform() {
  OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
  ARCH="$(uname -m)"

  case "$OS" in
    linux*)  OS="linux" ;;
    darwin*) OS="macos" ;;
    msys*|mingw*|cygwin*) error "Windows is not supported. Use WSL or Docker instead." ;;
    *)       error "Unsupported OS: $OS" ;;
  esac

  case "$ARCH" in
    x86_64|amd64)  ARCH="x86_64" ;;
    arm64|aarch64)
      if [[ "$OS" == "macos" ]]; then
        ARCH="arm64"
      else
        error "ARM64 Linux is not currently supported. Use Docker instead."
      fi
      ;;
    *)       error "Unsupported architecture: $ARCH" ;;
  esac

  PLATFORM="${OS}-${ARCH}"
  info "Detected platform: $PLATFORM"
}

# Get the latest version if not specified
get_version() {
  if [[ "$VERSION" == "latest" ]]; then
    step "Fetching latest version..."

    # Try to get version from version.json
    VERSION=$(curl -fsSL "$BASE_URL/latest/download/version.json" 2>/dev/null | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4 || true)

    if [[ -z "$VERSION" ]]; then
      # Fallback: get from the latest release page redirect
      LATEST_URL=$(curl -fsSI "$BASE_URL/latest" 2>/dev/null | grep -i "^location:" | tail -1 | tr -d '\r\n' | sed 's/location: //i')
      if [[ -n "$LATEST_URL" ]]; then
        VERSION=$(echo "$LATEST_URL" | sed 's/.*\/v\([^/]*\)$/\1/')
      fi
    fi

    if [[ -z "$VERSION" ]]; then
      error "Could not determine latest version. Please specify VERSION=x.y.z"
    fi

    info "Latest version: v$VERSION"
  fi
}

# Download and install the binary
install_binary() {
  step "Installing $TOOL_NAME v$VERSION for $PLATFORM..."

  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT

  # Construct download URL based on platform
  if [[ "$OS" == "macos" && "$ARCH" == "arm64" ]]; then
    ARCHIVE_NAME="ar-crawl-macos-arm64.tar.gz"
    DIST_DIR="ar-crawl-arm-dist"
    BIN_NAME="ar-crawl"
  elif [[ "$OS" == "macos" && "$ARCH" == "x86_64" ]]; then
    ARCHIVE_NAME="ar-crawl-macos-x86_64.tar.gz"
    DIST_DIR="ar-crawl-intel-dist"
    BIN_NAME="ar-crawl"
  else
    ARCHIVE_NAME="ar-crawl-linux-${ARCH}.tar.gz"
    DIST_DIR="ar-crawl-dist"
    BIN_NAME="ar-crawl"
  fi

  DOWNLOAD_URL="$BASE_URL/download/v$VERSION/$ARCHIVE_NAME"
  ARCHIVE_FILE="$TMP_DIR/$ARCHIVE_NAME"

  info "Downloading from: $DOWNLOAD_URL"

  if command -v curl >/dev/null 2>&1; then
    if ! curl -fsSL "$DOWNLOAD_URL" -o "$ARCHIVE_FILE"; then
      error "Download failed. Check if version v$VERSION exists and has $PLATFORM binaries."
    fi
  elif command -v wget >/dev/null 2>&1; then
    if ! wget -q "$DOWNLOAD_URL" -O "$ARCHIVE_FILE"; then
      error "Download failed. Check if version v$VERSION exists and has $PLATFORM binaries."
    fi
  else
    error "curl or wget is required for installation"
  fi

  # Verify download
  if [[ ! -f "$ARCHIVE_FILE" ]] || [[ ! -s "$ARCHIVE_FILE" ]]; then
    error "Downloaded file is empty or missing"
  fi

  # Extract archive
  info "Extracting archive..."
  tar -xzf "$ARCHIVE_FILE" -C "$TMP_DIR"

  # Create install directory
  mkdir -p "$INSTALL_DIR"

  # Find and install the binary
  if [[ -f "$TMP_DIR/$DIST_DIR/bin/$BIN_NAME" ]]; then
    cp "$TMP_DIR/$DIST_DIR/bin/$BIN_NAME" "$INSTALL_DIR/$TOOL_NAME"
  elif [[ -f "$TMP_DIR/$DIST_DIR/bin/ar-crawl-arm" ]]; then
    cp "$TMP_DIR/$DIST_DIR/bin/ar-crawl-arm" "$INSTALL_DIR/$TOOL_NAME"
  else
    # Try to find any executable
    FOUND_BIN=$(find "$TMP_DIR/$DIST_DIR/bin" -type f -executable 2>/dev/null | head -1)
    if [[ -n "$FOUND_BIN" ]]; then
      cp "$FOUND_BIN" "$INSTALL_DIR/$TOOL_NAME"
    else
      error "Could not find executable in archive"
    fi
  fi

  chmod +x "$INSTALL_DIR/$TOOL_NAME"
  info "Binary installed to: $INSTALL_DIR/$TOOL_NAME"

  # Install playwright-service files if present
  if [[ -d "$TMP_DIR/$DIST_DIR/lib/playwright-service" ]]; then
    mkdir -p "$LIB_DIR/playwright-service"
    cp -r "$TMP_DIR/$DIST_DIR/lib/playwright-service/"* "$LIB_DIR/playwright-service/"
    info "Playwright service files installed to: $LIB_DIR/playwright-service"
  fi

  # Check if install directory is in PATH
  if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo ""
    warn "$INSTALL_DIR is not in your PATH"
    echo ""
    echo "Add it to your shell profile:"
    echo ""
    if [[ -f "$HOME/.zshrc" ]]; then
      echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
      echo "  source ~/.zshrc"
    else
      echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc"
      echo "  source ~/.bashrc"
    fi
    echo ""
  fi
}

# Setup playwright-service dependencies
setup_playwright() {
  step "Checking Playwright service requirements..."

  # Check for Node.js
  if ! command -v node >/dev/null 2>&1; then
    warn "Node.js not found"
    echo ""
    echo "Playwright service requires Node.js 18+. To install:"
    echo ""
    echo "  # Using nvm (recommended):"
    echo "  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.0/install.sh | bash"
    echo "  nvm install 20"
    echo ""
    echo "  # Or on macOS with Homebrew:"
    echo "  brew install node"
    echo ""
    echo "After installing Node.js, run:"
    echo "  cd $LIB_DIR/playwright-service && npm install && npx playwright install chromium"
    return
  fi

  # Check Node.js version
  NODE_VERSION=$(node -v | sed 's/v//' | cut -d. -f1)
  if [[ "$NODE_VERSION" -lt 18 ]]; then
    warn "Node.js version $(node -v) found, but 18+ is required"
    echo ""
    echo "Upgrade Node.js and then run:"
    echo "  cd $LIB_DIR/playwright-service && npm install && npx playwright install chromium"
    return
  fi

  info "Node.js $(node -v) found"

  # Check if playwright-service was installed
  if [[ ! -d "$LIB_DIR/playwright-service" ]]; then
    warn "Playwright service files not found at $LIB_DIR/playwright-service"
    return
  fi

  # Install npm dependencies
  step "Installing Playwright npm dependencies..."
  cd "$LIB_DIR/playwright-service"

  if npm install --silent 2>/dev/null; then
    info "npm dependencies installed"
  else
    warn "npm install failed. Try manually: cd $LIB_DIR/playwright-service && npm install"
    return
  fi

  # Install Chromium browser
  step "Installing Chromium browser for Playwright..."
  if npx playwright install chromium 2>/dev/null; then
    info "Chromium browser installed"
  else
    warn "Chromium install failed. Try manually: cd $LIB_DIR/playwright-service && npx playwright install chromium"
    return
  fi

  info "Playwright service setup complete!"
}

# Print post-install instructions
print_instructions() {
  echo ""
  echo "=========================================="
  echo "  Installation Complete!"
  echo "=========================================="
  echo ""
  echo "Quick Start:"
  echo ""
  echo "  # Crawl a webpage (uses direct HTTP)"
  echo "  ar-crawl crawl https://example.com"
  echo ""
  echo "  # Show all commands"
  echo "  ar-crawl --help"
  echo ""

  if [[ -d "$LIB_DIR/playwright-service" ]]; then
    echo "For JavaScript-rendered pages, start the Playwright service:"
    echo ""
    echo "  cd $LIB_DIR/playwright-service && npm start"
    echo ""
    echo "Then crawl with Playwright:"
    echo ""
    echo "  ar-crawl crawl https://example.com --service playwright"
    echo ""
  fi

  echo "Documentation: https://codeberg.org/anuna/ar-crawl"
  echo ""
}

# Main entry point
main() {
  echo ""
  echo "=========================================="
  echo "  AR-Crawl Installer"
  echo "=========================================="
  echo ""

  detect_platform
  get_version
  install_binary

  if [[ "${SKIP_PLAYWRIGHT:-0}" != "1" ]]; then
    echo ""
    setup_playwright
  fi

  print_instructions
}

# Run main function
main "$@"
