#!/bin/zsh
# Builds Audio Router and wraps the binary into build/AudioRouter.app.
# Set CODESIGN_IDENTITY to a real certificate to keep the audio-capture
# permission across rebuilds; the default ad-hoc signature changes every build.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/AudioRouter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/AudioRouter "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"

echo "Built $APP — run it with: open $APP"
