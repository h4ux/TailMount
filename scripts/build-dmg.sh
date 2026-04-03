#!/bin/bash
set -euo pipefail

APP_NAME="TailMount"
VERSION=$(defaults read "$(pwd)/TailMount/Resources/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0.0")
DMG_NAME="${APP_NAME}-${VERSION}"
BUILD_DIR="build/dmg"
DMG_PATH="build/${DMG_NAME}.dmg"
BG_IMG="scripts/dmg-background.png"

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
mkdir -p "$BUILD_DIR/.background"

# Copy app and background
cp -R "$APP_PATH" "$BUILD_DIR/${APP_NAME}.app"
ln -s /Applications "$BUILD_DIR/Applications"
cp "$BG_IMG" "$BUILD_DIR/.background/background.png"

# Remove old DMG if it exists
rm -f "$DMG_PATH"

# Create temporary read-write DMG
echo "==> Creating DMG..."
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$BUILD_DIR" \
    -ov \
    -format UDRW \
    "build/${DMG_NAME}-rw.dmg"

# Mount it to set Finder view options
MOUNT_DIR=$(hdiutil attach "build/${DMG_NAME}-rw.dmg" -nobrowse | tail -1 | awk '{print $3}')
echo "==> Mounted at $MOUNT_DIR"

# Set Finder window appearance using AppleScript
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "${APP_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 760, 500}
        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 80
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "${APP_NAME}.app" of container window to {150, 190}
        set position of item "Applications" of container window to {510, 190}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Ensure background is visible
sync
sleep 2

# Unmount
hdiutil detach "$MOUNT_DIR" -quiet

# Convert to compressed read-only DMG
hdiutil convert "build/${DMG_NAME}-rw.dmg" -format UDZO -o "$DMG_PATH"
rm -f "build/${DMG_NAME}-rw.dmg"

# Clean up staging
rm -rf "$BUILD_DIR"

echo ""
echo "==> DMG created: $DMG_PATH"
echo "    Size: $(du -h "$DMG_PATH" | cut -f1)"
