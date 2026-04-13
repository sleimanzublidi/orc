#!/bin/bash
set -euo pipefail

CONFIG="${1:-debug}"
if [[ "$CONFIG" != "debug" && "$CONFIG" != "release" ]]; then
    echo "Usage: $0 [debug|release]" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCES_DIR="$REPO_ROOT/Orc"
PREBUILD_DIR="$REPO_ROOT/PreBuild"

# Read version from OrcInfo.swift
ORC_INFO="$SOURCES_DIR/Core/Models/Source/OrcInfo.swift"
VERSION=$(grep -oE '"[0-9]+\.[0-9]+\.[0-9]+[^"]*"' "$ORC_INFO" | head -1 | tr -d '"')
if [ -z "$VERSION" ]; then
    echo "Error: Could not read version from $ORC_INFO" >&2
    exit 1
fi

# Inject git hash and build timestamp
GIT_HASH=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
sed -i '' "s|public static let githash = \".*\"|public static let githash = \"$GIT_HASH\"|" "$ORC_INFO"
sed -i '' "s|public static let buildTimestamp = \".*\"|public static let buildTimestamp = \"$BUILD_TIMESTAMP\"|" "$ORC_INFO"

# Restore OrcInfo on exit so working tree stays clean
cleanup_orc_info() {
    sed -i '' "s|public static let githash = \".*\"|public static let githash = \"\"|" "$ORC_INFO"
    sed -i '' "s|public static let buildTimestamp = \".*\"|public static let buildTimestamp = \"\"|" "$ORC_INFO"
}
trap cleanup_orc_info EXIT

mkdir -p "$PREBUILD_DIR"
cd "$SOURCES_DIR"

if [[ "$CONFIG" == "debug" ]]; then
    echo "Building orc v${VERSION} (debug, host arch)..."
    swift build -c debug

    BINARY="$SOURCES_DIR/.build/debug/orc"
    if [ ! -f "$BINARY" ]; then
        echo "Error: Binary not found at $BINARY" >&2
        exit 1
    fi

    cp "$BINARY" "$PREBUILD_DIR/orc"
    codesign -f -s - "$PREBUILD_DIR/orc"

    echo ""
    echo "Debug build: $PREBUILD_DIR/orc"
else
    echo "Building orc v${VERSION} (release, universal)..."

    # Build arm64
    echo "  Building arm64..."
    swift build -c release --arch arm64

    # Build x86_64
    echo "  Building x86_64..."
    swift build -c release --arch x86_64

    ARM64_BINARY="$SOURCES_DIR/.build/arm64-apple-macosx/release/orc"
    X86_BINARY="$SOURCES_DIR/.build/x86_64-apple-macosx/release/orc"

    for bin in "$ARM64_BINARY" "$X86_BINARY"; do
        if [ ! -f "$bin" ]; then
            echo "Error: Binary not found at $bin" >&2
            exit 1
        fi
    done

    # Create universal binary
    STAGING=$(mktemp -d)
    trap 'rm -rf "$STAGING"; cleanup_orc_info' EXIT

    ARCHIVE_NAME="orc-cli-${VERSION}"
    UNIVERSAL_BINARY="$STAGING/$ARCHIVE_NAME/bin/orc"
    mkdir -p "$STAGING/$ARCHIVE_NAME/bin"

    echo "  Creating universal binary..."
    lipo -create "$ARM64_BINARY" "$X86_BINARY" -output "$UNIVERSAL_BINARY"

    # Checksum
    shasum -a 256 "$UNIVERSAL_BINARY" | awk '{print $1}' > "$STAGING/$ARCHIVE_NAME/$ARCHIVE_NAME.checksum.txt"

    # Create zip
    ARCHIVE_PATH="$PREBUILD_DIR/release-orc-cli-universal-${VERSION}.zip"
    cd "$STAGING"
    zip -r "$ARCHIVE_PATH" "$ARCHIVE_NAME"

    echo ""
    echo "Release archive: $ARCHIVE_PATH"
    echo "  Version:  $VERSION"
    echo "  Arch:     universal (arm64 + x86_64)"
fi
