#!/bin/bash
set -euo pipefail

APP_NAME="TailMount"
VERSION=$(defaults read "$(pwd)/TailMount/Resources/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0.0")
DMG_NAME="${APP_NAME}-${VERSION}"
BUILD_DIR="build/dmg"
DMG_PATH="build/${DMG_NAME}.dmg"

echo "==> Building Release..."
xcodegen generate
xcodebuild -project ${APP_NAME}.xcodeproj -scheme ${APP_NAME} -configuration Release build

# Find the .app
APP_PATH=$(xcodebuild -project ${APP_NAME}.xcodeproj -scheme ${APP_NAME} -configuration Release -showBuildSettings 2>/dev/null | grep "BUILT_PRODUCTS_DIR" | head -1 | awk '{print $3}')/${APP_NAME}.app

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: ${APP_NAME}.app not found at $APP_PATH"
    exit 1
fi

echo "==> Found app at $APP_PATH"

# Clean staging area
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Copy app
cp -R "$APP_PATH" "$BUILD_DIR/${APP_NAME}.app"

# Create symlink to /Applications
ln -s /Applications "$BUILD_DIR/Applications"

# Remove old DMG if it exists
rm -f "$DMG_PATH"

# Create DMG
echo "==> Creating DMG..."
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$BUILD_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

# Clean up staging
rm -rf "$BUILD_DIR"

echo ""
echo "==> DMG created: $DMG_PATH"
echo "    Size: $(du -h "$DMG_PATH" | cut -f1)"
