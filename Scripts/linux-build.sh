#!/bin/bash
set -euo pipefail

# Builds and optionally tests Orc inside a Linux Docker container.
# Usage:
#   ./Scripts/linux-build.sh              # build + test
#   ./Scripts/linux-build.sh build        # build only
#   ./Scripts/linux-build.sh test         # build + test
#   ./Scripts/linux-build.sh shell        # drop into a shell

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG_DIR="$REPO_ROOT/Orc"
ACTION="${1:-test}"

IMAGE="orc-linux-builder"
SWIFT_TAG="6.1-noble"

# Build the Docker image (cached after first run)
echo "Building Docker image ($SWIFT_TAG)..."
docker build -t "$IMAGE" "$PKG_DIR"

case "$ACTION" in
    build)
        echo "Building (Linux)..."
        docker run --rm -v "$PKG_DIR":/src -w /src "$IMAGE" swift build
        ;;
    test)
        echo "Building and testing (Linux)..."
        docker run --rm -v "$PKG_DIR":/src -w /src "$IMAGE" sh -c "swift build && swift test"
        ;;
    shell)
        echo "Opening shell in Linux container..."
        docker run --rm -it -v "$PKG_DIR":/src -w /src "$IMAGE" bash
        ;;
    *)
        echo "Usage: $0 [build|test|shell]" >&2
        exit 1
        ;;
esac
