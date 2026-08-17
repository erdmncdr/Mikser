#!/bin/bash
#  Mikser — per-app audio control for macOS
#  Copyright (C) 2026 Mikser Contributors
#  SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Mikser"
BUNDLE_ID="io.github.erdmncdr.mikser"
APP="$APP_NAME.app"

# Signing identity: MIKSER_SIGN_ID if set, otherwise an ad-hoc signature.
# An ad-hoc signature changes on every build, so macOS may ask for the audio
# capture permission again. For a permanent grant, create a self-signed code
# signing certificate in Keychain Access and run:
#   MIKSER_SIGN_ID="Mikser Dev" ./build.sh
SIGN_ID="${MIKSER_SIGN_ID:--}"

if [ ! -f "Resources/$APP_NAME.icns" ]; then
  echo "==> Generating application icon"
  swift Tools/GenerateIcon.swift "Resources/$APP_NAME.iconset" > /dev/null
  iconutil -c icns "Resources/$APP_NAME.iconset" -o "Resources/$APP_NAME.icns"
fi

echo "==> Building (release)"
swift build -c release

echo "==> Assembling the application bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "Resources/$APP_NAME.icns" "$APP/Contents/Resources/$APP_NAME.icns"

echo "==> Signing ($SIGN_ID)"
codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"

echo "==> Ready: $(pwd)/$APP"
echo "    Run it with: open $APP"
