#!/bin/bash
# pack.sh — Bundle a workflow + its referenced files into a .orc-workflow archive.
#
# Wrapper around `orc pack` with sensible defaults for iterative authoring.
# Output goes to dist/<workflow>.orc-workflow at the repo root.
#
# Usage:
#   bash Scripts/pack.sh <workflow> [--version v] [--author "Name"] [--include path ...]
#
# Examples:
#   bash Scripts/pack.sh self-improve
#   bash Scripts/pack.sh self-improve --version 1.0.1
#   bash Scripts/pack.sh self-improve --include self-improve/ideas-backlog.md

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"

# Prefer the freshly-built binary; fall back to PATH so this works in fresh clones.
ORC_BINARY="$REPO_ROOT/PreBuild/orc"
if [ ! -x "$ORC_BINARY" ]; then
    if command -v orc >/dev/null 2>&1; then
        ORC_BINARY="$(command -v orc)"
    else
        echo "Error: PreBuild/orc not found and 'orc' not on PATH." >&2
        echo "Run 'bash Scripts/build.sh' first." >&2
        exit 1
    fi
fi

# Defaults — overridable via flags.
VERSION="0.0.0"
AUTHOR=""
INCLUDES=()

if [ $# -lt 1 ]; then
    echo "Usage: $0 <workflow> [--version v] [--author \"Name\"] [--include path ...]" >&2
    exit 1
fi

WORKFLOW="$1"
shift

while [ $# -gt 0 ]; do
    case "$1" in
        --version)
            VERSION="$2"
            shift 2
            ;;
        --author)
            AUTHOR="$2"
            shift 2
            ;;
        --include)
            INCLUDES+=("$2")
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

mkdir -p "$DIST_DIR"
OUTPUT="$DIST_DIR/${WORKFLOW}.orc-workflow"

CMD=("$ORC_BINARY" pack "$WORKFLOW" --package-version "$VERSION" --output "$OUTPUT")
if [ -n "$AUTHOR" ]; then
    CMD+=(--author "$AUTHOR")
fi
if [ "${#INCLUDES[@]}" -gt 0 ]; then
    CMD+=(--include "${INCLUDES[@]}")
fi

cd "$REPO_ROOT"
"${CMD[@]}"
