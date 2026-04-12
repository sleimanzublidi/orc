#!/bin/bash
set -euo pipefail

# Builds Orc inside a Linux Docker container.
# Default: release build with zip archive in PreBuild/.
#
# Usage:
#   ./Scripts/build-linux.sh              # release build → PreBuild/
#   ./Scripts/build-linux.sh debug        # debug build → PreBuild/
#   ./Scripts/build-linux.sh test         # debug build + run tests
#   ./Scripts/build-linux.sh shell        # drop into a shell

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG_DIR="$REPO_ROOT/Orc"
PREBUILD_DIR="$REPO_ROOT/PreBuild"
ACTION="${1:-release}"

IMAGE="orc-linux-builder"

# Build the Docker image (cached after first run)
echo "Building Docker image..."
docker build -q -t "$IMAGE" "$PKG_DIR"

# Read version from OrcInfo.swift
ORC_INFO="$PKG_DIR/Core/Models/Source/OrcInfo.swift"
VERSION=$(grep -oE '"[0-9]+\.[0-9]+\.[0-9]+[^"]*"' "$ORC_INFO" | head -1 | tr -d '"')
if [ -z "$VERSION" ]; then
    echo "Error: Could not read version from $ORC_INFO" >&2
    exit 1
fi

mkdir -p "$PREBUILD_DIR"

# Write git hash to a temp file so the container can read it (git isn't in the image)
GIT_HASH=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
echo "$GIT_HASH" > "$PKG_DIR/.githash"
cleanup_githash() { rm -f "$PKG_DIR/.githash"; }
trap cleanup_githash EXIT

# Common docker run args: mount both Orc/ (source) and PreBuild/ (output)
RUN="docker run --rm -v $PKG_DIR:/src -v $PREBUILD_DIR:/prebuild -w /src"

case "$ACTION" in
    release)
        echo "Building orc v${VERSION} (release, Linux)..."
        $RUN "$IMAGE" sh -c '
            set -e
            GIT_HASH=$(cat /src/.githash 2>/dev/null || echo "unknown")
            BUILD_TS=$(date -u "+%Y-%m-%d %H:%M:%S UTC")
            ORC_INFO="Core/Models/Source/OrcInfo.swift"

            # Inject git hash and build timestamp
            sed -i "s|public static let githash = \".*\"|public static let githash = \"$GIT_HASH\"|" "$ORC_INFO"
            sed -i "s|public static let buildTimestamp = \".*\"|public static let buildTimestamp = \"$BUILD_TS\"|" "$ORC_INFO"

            swift build -c release

            # Restore OrcInfo so working tree stays clean
            sed -i "s|public static let githash = \".*\"|public static let githash = \"\"|" "$ORC_INFO"
            sed -i "s|public static let buildTimestamp = \".*\"|public static let buildTimestamp = \"\"|" "$ORC_INFO"

            BINARY=".build/release/orc"
            if [ ! -f "$BINARY" ]; then
                echo "Error: Binary not found at $BINARY" >&2
                exit 1
            fi

            ARCH=$(uname -m)
            VERSION="'"$VERSION"'"
            ARCHIVE_NAME="orc-cli-${VERSION}-linux-${ARCH}"
            STAGING=$(mktemp -d)
            mkdir -p "$STAGING/$ARCHIVE_NAME/bin"
            cp "$BINARY" "$STAGING/$ARCHIVE_NAME/bin/orc"
            sha256sum "$STAGING/$ARCHIVE_NAME/bin/orc" | awk "{print \$1}" > "$STAGING/$ARCHIVE_NAME/$ARCHIVE_NAME.checksum.txt"

            cd "$STAGING"
            zip -r "/prebuild/${ARCHIVE_NAME}.zip" "$ARCHIVE_NAME"
            cp "$STAGING/$ARCHIVE_NAME/bin/orc" "/prebuild/orc-linux"

            echo ""
            echo "Release archive: PreBuild/${ARCHIVE_NAME}.zip"
            echo "  Version:  $VERSION"
            echo "  Platform: Linux ($ARCH)"
        '
        ;;
    debug)
        echo "Building orc v${VERSION} (debug, Linux)..."
        $RUN "$IMAGE" sh -c '
            swift build -c debug
            BINARY=".build/debug/orc"
            if [ ! -f "$BINARY" ]; then
                echo "Error: Binary not found at $BINARY" >&2
                exit 1
            fi
            cp "$BINARY" "/prebuild/orc-linux"
            echo ""
            echo "Debug build: PreBuild/orc-linux"
        '
        ;;
    test)
        echo "Building and testing (Linux)..."
        $RUN "$IMAGE" sh -c "swift build && swift test"
        ;;
    shell)
        echo "Opening shell in Linux container..."
        docker run --rm -it -v "$PKG_DIR":/src -v "$PREBUILD_DIR":/prebuild -w /src "$IMAGE" bash
        ;;
    *)
        echo "Usage: $0 [release|debug|test|shell]" >&2
        exit 1
        ;;
esac
