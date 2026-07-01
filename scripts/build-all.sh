#!/usr/bin/env bash
# Build both native dependencies and package them as XCFrameworks.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/build-x265.sh"
bash "$SCRIPT_DIR/build-ffmpeg.sh"
echo ">>> All native dependencies built. XCFrameworks are in ./Frameworks"
