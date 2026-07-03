#!/bin/bash
set -e

# AR-Crawl Installer
# Installs ar-crawl binary and optionally sets up playwright-service

TOOL_NAME="ar-crawl"
VERSION="${VERSION:-latest}"
BASE_URL="https://files.anuna.io/ar-crawl"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
LIB_DIR="${LIB_DIR:-$HOME/.local/lib/ar-crawl}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Detect OS and architecture
detect_platform() {
  local detected_os detected_arch

  detected_os="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  detected_arch="$(uname -m 2>/dev/null)"

  if [[ -z "$detected_os" ]]; then
    error "Could not detect operating system (uname -s failed)"
  fi

  if [[ -z "$detected_arch" ]]; then
    error "Could not detect architecture (uname -m failed)"
  fi

  case "$detected_os" in
    linux*)  OS="linux" ;;
    darwin*) OS="macos" ;;
    *)       error "Unsupported OS: $detected_os" ;;
  esac

  case "$detected_arch" in
    x86_64|amd64)  ARCH="x86_64" ;;
    arm64|aarch64)
      if [[ "$OS" == "macos" ]]; then
        ARCH="arm64"
      else
        error "ARM64 Linux is not currently supported"
      fi
      ;;
    *)       error "Unsupported architecture: $detected_arch" ;;
  esac

  PLATFORM="${OS}-${ARCH}"

  # Verify variables are set before continuing
  if [[ -z "$OS" ]] || [[ -z "$ARCH" ]] || [[ -z "$PLATFORM" ]]; then
    error "Platform detection failed: OS=$OS, ARCH=$ARCH, PLATFORM=$PLATFORM"
  fi

  info "Detected platform: $PLATFORM"
}

# Get the latest version if not specified
get_version() {
  if [[ "$VERSION" == "latest" ]]; then
    info "Fetching latest version..."
    VERSION=$(curl -fsSL "$BASE_URL/latest/version.json" 2>/dev/null | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
    if [[ -z "$VERSION" ]]; then
      error "Could not determine latest version"
    fi
    info "Latest version: $VERSION"
  fi
}

# Download and install
install_binary() {
  info "Installing $TOOL_NAME v$VERSION for $PLATFORM..."

  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT

  # Construct download URL
  if [[ "$OS" == "macos" && "$ARCH" == "arm64" ]]; then
    ARCHIVE_NAME="ar-crawl-macos-arm64.tar.gz"
    DIST_DIR="ar-crawl-arm-dist"
  elif [[ "$OS" == "macos" && "$ARCH" == "x86_64" ]]; then
    ARCHIVE_NAME="ar-crawl-macos-x86_64.tar.gz"
    DIST_DIR="ar-crawl-intel-dist"
  else
    ARCHIVE_NAME="ar-crawl-linux-${ARCH}.tar.gz"
    DIST_DIR="ar-crawl-dist"
  fi

  DOWNLOAD_URL="$BASE_URL/v$VERSION/$ARCHIVE_NAME"
  ARCHIVE_FILE="$TMP_DIR/$ARCHIVE_NAME"

  info "Downloading from $DOWNLOAD_URL..."
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$DOWNLOAD_URL" -o "$ARCHIVE_FILE" || error "Download failed"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$DOWNLOAD_URL" -O "$ARCHIVE_FILE" || error "Download failed"
  else
    error "curl or wget is required"
  fi

  # Extract
  info "Extracting archive..."
  tar -xzf "$ARCHIVE_FILE" -C "$TMP_DIR"

  # Install binary
  mkdir -p "$INSTALL_DIR"
  cp "$TMP_DIR/$DIST_DIR/bin/ar-crawl"* "$INSTALL_DIR/$TOOL_NAME"
  chmod +x "$INSTALL_DIR/$TOOL_NAME"
  info "Binary installed to $INSTALL_DIR/$TOOL_NAME"

  # Install playwright-service if present
  if [[ -d "$TMP_DIR/$DIST_DIR/lib/playwright-service" ]]; then
    mkdir -p "$LIB_DIR/playwright-service"
    cp -r "$TMP_DIR/$DIST_DIR/lib/playwright-service/"* "$LIB_DIR/playwright-service/"
    info "Playwright service files installed to $LIB_DIR/playwright-service"
  fi

  # Check if directory is in PATH
  if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    warn "$INSTALL_DIR is not in your PATH"
    echo ""
    echo "Add it to your shell profile:"
    echo "  echo 'export PATH=\"\$PATH:$INSTALL_DIR\"' >> ~/.bashrc"
    echo "  # or for zsh:"
    echo "  echo 'export PATH=\"\$PATH:$INSTALL_DIR\"' >> ~/.zshrc"
  fi
}

# Setup playwright-service
setup_playwright() {
  if ! command -v node >/dev/null 2>&1; then
    warn "Node.js not found. Playwright service requires Node.js 18+."
    warn "Install Node.js and run: cd $LIB_DIR/playwright-service && npm install"
    return
  fi

  NODE_VERSION=$(node -v | sed 's/v//' | cut -d. -f1)
  if [[ "$NODE_VERSION" -lt 18 ]]; then
    warn "Node.js version $NODE_VERSION found, but 18+ is required for Playwright."
    return
  fi

  if [[ -d "$LIB_DIR/playwright-service" ]]; then
    info "Setting up Playwright service..."
    cd "$LIB_DIR/playwright-service"

    # Install npm dependencies
    info "Installing npm dependencies..."
    npm install --silent

    # Install Chromium browser
    info "Installing Chromium browser for Playwright..."
    npx playwright install chromium

    info "Playwright service setup complete!"
    echo ""
    echo "To start the Playwright service:"
    echo "  cd $LIB_DIR/playwright-service && npm start"
    echo ""
    echo "Or use the Docker setup for production."
  fi
}

# Print usage help
print_usage() {
  echo ""
  echo "Usage:"
  echo "  curl -fsSL https://files.anuna.io/ar-crawl/latest/install.sh | bash"
  echo ""
  echo "Environment variables:"
  echo "  VERSION      - Version to install (default: latest)"
  echo "  INSTALL_DIR  - Binary install directory (default: ~/.local/bin)"
  echo "  LIB_DIR      - Library install directory (default: ~/.local/lib/ar-crawl)"
  echo "  SKIP_PLAYWRIGHT - Set to 1 to skip Playwright setup"
  echo ""
  echo "Examples:"
  echo "  # Install latest version"
  echo "  curl -fsSL https://files.anuna.io/ar-crawl/latest/install.sh | bash"
  echo ""
  echo "  # Install specific version"
  echo "  VERSION=1.0.0 curl -fsSL ... | bash"
  echo ""
  echo "  # Install without Playwright"
  echo "  SKIP_PLAYWRIGHT=1 curl -fsSL ... | bash"
}

# Main
main() {
  echo "================================================"
  echo "  AR-Crawl Installer"
  echo "================================================"
  echo ""

  detect_platform
  get_version
  install_binary

  if [[ "${SKIP_PLAYWRIGHT:-0}" != "1" ]]; then
    setup_playwright
  fi

  echo ""
  info "Installation complete!"
  echo ""
  echo "Quick start:"
  echo "  ar-crawl --help"
  echo "  ar-crawl crawl https://example.com"
  echo ""
  echo "For full documentation: https://codeberg.org/anuna/ar-crawl"
  echo "Downloads: https://files.anuna.io/ar-crawl"
}

main "$@"
