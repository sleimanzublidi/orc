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

# Read version from OrcVersion.swift
VERSION=$(grep -oE '"[0-9]+\.[0-9]+\.[0-9]+[^"]*"' "$SOURCES_DIR/Core/Models/Source/OrcVersion.swift" | tr -d '"')
if [ -z "$VERSION" ]; then
    echo "Error: Could not read version from Core/Models/Source/OrcVersion.swift" >&2
    exit 1
fi

mkdir -p "$PREBUILD_DIR"
cd "$SOURCES_DIR"

if [[ "$CONFIG" == "debug" ]]; then
    echo "Building orc v${VERSION} (debug, host arch)..."
    xcrun swift build -c debug

    BINARY="$SOURCES_DIR/.build/debug/orc"
    if [ ! -f "$BINARY" ]; then
        echo "Error: Binary not found at $BINARY" >&2
        exit 1
    fi

    cp "$BINARY" "$PREBUILD_DIR/orc"

    echo ""
    echo "Debug build: $PREBUILD_DIR/orc"
else
    echo "Building orc v${VERSION} (release, universal)..."

    # Build arm64
    echo "  Building arm64..."
    xcrun swift build -c release --arch arm64

    # Build x86_64
    echo "  Building x86_64..."
    xcrun swift build -c release --arch x86_64

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
    trap 'rm -rf "$STAGING"' EXIT

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
