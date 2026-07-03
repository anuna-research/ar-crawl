#!/bin/bash
set -euo pipefail

# release-macos-arm64.sh
# Build the macOS ARM64 release artifact locally and upload it to Cloudflare R2.
#
# CI cross-compiles this artifact from Linux on a best-effort basis and often
# fails; this script is the manual fallback (and can be the primary path on an
# Apple Silicon Mac).
#
# Requires: racket/raco (with project deps installed), wrangler (authenticated
# via CLOUDFLARE_API_TOKEN or `wrangler login`).
#
# Usage:
#   scripts/release-macos-arm64.sh              # version from git tag on HEAD
#   VERSION=1.0.31 scripts/release-macos-arm64.sh
#
# Layout on R2 (bucket anuna-files, served at https://files.anuna.io):
#   ar-crawl/v<VERSION>/ar-crawl-macos-arm64.tar.gz
#   ar-crawl/latest/ar-crawl-macos-arm64.tar.gz
#   ar-crawl/latest/version.json   (only advanced when all platform tarballs exist)

BUCKET="anuna-files"
PROJECT="ar-crawl"
BASE_URL="https://files.anuna.io/$PROJECT"
ARCHIVE_NAME="ar-crawl-macos-arm64.tar.gz"
DIST_DIR_NAME="ar-crawl-arm-dist"   # install.sh expects this directory name

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

info() { echo "[INFO] $1"; }
error() { echo "[ERROR] $1" >&2; exit 1; }

[[ "$(uname -s)-$(uname -m)" == "Darwin-arm64" ]] || error "This script must run on an Apple Silicon Mac"
command -v raco >/dev/null || error "raco not found - install Racket"
command -v wrangler >/dev/null || error "wrangler not found - npm install -g wrangler"

# Resolve version: env override, else exact tag on HEAD
if [[ -z "${VERSION:-}" ]]; then
  TAG="$(git describe --tags --exact-match 2>/dev/null)" \
    || error "HEAD is not tagged. Tag a release (git tag vX.Y.Z) or pass VERSION=X.Y.Z"
  VERSION="${TAG#v}"
fi
info "Releasing version $VERSION"

# Bake the version into the binary
make version-info

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

info "Compiling..."
find . -type d -name compiled -not -path "./node_modules/*" | xargs rm -rf
raco make src/cli.rkt
raco exe -o "$BUILD_DIR/ar-crawl-arm" src/cli.rkt
raco distribute "$BUILD_DIR/$DIST_DIR_NAME" "$BUILD_DIR/ar-crawl-arm"

info "Bundling playwright-service..."
mkdir -p "$BUILD_DIR/$DIST_DIR_NAME/lib/playwright-service"
cp playwright-service/package.json playwright-service/server.js \
  "$BUILD_DIR/$DIST_DIR_NAME/lib/playwright-service/"

# Sanity check: the binary must report the version we are releasing
REPORTED="$("$BUILD_DIR/$DIST_DIR_NAME/bin/ar-crawl-arm" --version | head -1)"
info "Binary reports: $REPORTED"
[[ "$REPORTED" == *"$VERSION"* ]] || error "Binary version mismatch: expected $VERSION"

info "Creating $ARCHIVE_NAME..."
tar -C "$BUILD_DIR" -czf "$BUILD_DIR/$ARCHIVE_NAME" "$DIST_DIR_NAME"

info "Uploading to R2..."
for dest in "v$VERSION" "latest"; do
  wrangler r2 object put "$BUCKET/$PROJECT/$dest/$ARCHIVE_NAME" \
    --file="$BUILD_DIR/$ARCHIVE_NAME" --content-type="application/gzip" --remote
done

# Advance latest/version.json only if every platform tarball exists for this version
missing=""
for f in ar-crawl-linux-x86_64.tar.gz ar-crawl-macos-x86_64.tar.gz "$ARCHIVE_NAME"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/v$VERSION/$f")"
  [[ "$code" == "200" ]] || missing="$missing $f"
done

if [[ -z "$missing" ]]; then
  cat > "$BUILD_DIR/version.json" << EOF
{
  "version": "$VERSION",
  "download_url": "$BASE_URL/v$VERSION"
}
EOF
  wrangler r2 object put "$BUCKET/$PROJECT/latest/version.json" \
    --file="$BUILD_DIR/version.json" --content-type="application/json" --remote
  info "latest/version.json now points at $VERSION"
else
  echo "[WARN] Not advancing latest/version.json - missing for v$VERSION:$missing"
  echo "[WARN] Upload those (CI builds them) then re-run, or copy version.json manually."
fi

info "Verifying..."
code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/v$VERSION/$ARCHIVE_NAME")"
[[ "$code" == "200" ]] || error "Uploaded artifact not reachable (HTTP $code)"
info "Done: $BASE_URL/v$VERSION/$ARCHIVE_NAME"
