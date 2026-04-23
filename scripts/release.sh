#!/bin/bash
set -euo pipefail

APP_NAME="Noted"
IDENTIFIER="app.noted.macos"
PROFILE_NAME="Noted"

ROOT_DIR="$(pwd)"
SWIFT_DIR="$ROOT_DIR/HushScribe"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
DMG_NAME="dist/${APP_NAME}.dmg"
ENTITLEMENTS="$SWIFT_DIR/Sources/HushScribe/Noted.entitlements"
BINARY_PATH=".build/release/$APP_NAME"
ICON_PATH="$SWIFT_DIR/Sources/HushScribe/Assets/AppIcon.icns"

DEVELOPER_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | awk '{print $2}' || true)

cd "$SWIFT_DIR"
swift build -c release

if [[ ! -f "$BINARY_PATH" ]]; then
  echo "Build failed: binary not found at $BINARY_PATH"
  exit 1
fi

cd "$ROOT_DIR"
rm -f "$DMG_NAME"
rm -rf "$APP_BUNDLE"

mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources"
cp "$SWIFT_DIR/$BINARY_PATH" "$CONTENTS/MacOS/$APP_NAME"
chmod +x "$CONTENTS/MacOS/$APP_NAME"

if [[ -f "$ICON_PATH" ]]; then
  cp "$ICON_PATH" "$CONTENTS/Resources/AppIcon.icns"
fi

LOGO_PATH="$SWIFT_DIR/Sources/HushScribe/Assets/logo.svg"
if [[ -f "$LOGO_PATH" ]]; then
  cp "$LOGO_PATH" "$CONTENTS/Resources/logo.svg"
fi

cp "$SWIFT_DIR/Sources/HushScribe/Info.plist" "$CONTENTS/Info.plist"

if [[ -n "$DEVELOPER_ID" ]]; then
  find "$APP_BUNDLE" -type f \( -name "*.dylib" -o -name "*.framework" -o -name "*.so" \) -print0 | xargs -0 -I {} \
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "{}"

  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$DEVELOPER_ID" \
    "$APP_BUNDLE"
else
  echo "No Developer ID certificate found; leaving app bundle unsigned."
fi

hdiutil create -volname "$APP_NAME" -srcfolder "$APP_BUNDLE" -ov -format UDZO "$DMG_NAME"

if [[ -n "$DEVELOPER_ID" ]]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG_NAME"
fi

if [[ "${1:-}" == "test" ]]; then
  echo "Test argument detected. Not notarizing or releasing."
  exit 0
fi

if [[ -z "$DEVELOPER_ID" ]]; then
  echo "Cannot notarize without a Developer ID certificate."
  exit 1
fi

xcrun notarytool submit "$DMG_NAME" --keychain-profile "$PROFILE_NAME" --wait
xcrun stapler staple "$DMG_NAME"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$CONTENTS/Info.plist")
echo "$APP_NAME $VERSION packaged at $DMG_NAME"
