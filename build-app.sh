#!/bin/bash
# Builds a real, double-clickable "Petit Pomme.app" bundle from this SwiftPM
# package. We don't have Xcode installed, so there's no "Archive"/"Build App"
# step to lean on — this reproduces what that step would do by hand: release
# build, assemble the bundle layout, drop in Info.plist, and ad-hoc codesign
# so Gatekeeper/launchservices treat it as a normal local app.
#
# The Swift target/executable itself is still named "FoundationModelServer"
# (renaming it would mean renaming source files and the package target) —
# only the user-facing .app bundle and its Info.plist display name are
# "Petit Pomme".
set -euo pipefail

cd "$(dirname "$0")"

EXECUTABLE_NAME="FoundationModelServer"
APP_DISPLAY_NAME="Petit Pomme"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_DISPLAY_NAME}.app"

echo "Building release binary..."
swift build -c release

echo "Assembling ${APP_BUNDLE}..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$EXECUTABLE_NAME" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcons/*.png "$APP_BUNDLE/Contents/Resources/"

echo "Ad-hoc code signing..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Done: $(pwd)/$APP_BUNDLE"
echo "Run it with: open \"$APP_BUNDLE\""
