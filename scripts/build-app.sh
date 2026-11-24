#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift build -c release --package-path "$ROOT"
APP="$ROOT/build/Threadwork.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/Threadwork" "$APP/Contents/MacOS/Threadwork"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "$HOME/Applications"
    ditto "$APP" "$HOME/Applications/Threadwork.app"
    echo "Installed: $HOME/Applications/Threadwork.app"
else
    echo "Built: $APP"
fi
