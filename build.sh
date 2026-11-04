#!/bin/bash
# Build 绳上手帐.app with the Xcode command line tools (no Xcode project needed).
#   ./build.sh              build for this Mac
#   UNIVERSAL=1 ./build.sh  build for Apple Silicon + Intel
set -euo pipefail
cd "$(dirname "$0")"

NAME="绳上手帐"
EXE="StringJournal"
VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"
APP="build/${NAME}.app"
MIN_OS="13.0"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"

compile() {
  swiftc -O -target "$1-apple-macos${MIN_OS}" \
    -framework AppKit -framework SwiftUI -framework CoreText -framework QuartzCore \
    -o "$2" Sources/*.swift
}

if [ "${UNIVERSAL:-0}" = "1" ]; then
  compile arm64 build/${EXE}-arm64
  compile x86_64 build/${EXE}-x86_64
  lipo -create build/${EXE}-arm64 build/${EXE}-x86_64 -output "$APP/Contents/MacOS/${EXE}"
  rm build/${EXE}-arm64 build/${EXE}-x86_64
else
  compile "$(uname -m)" "$APP/Contents/MacOS/${EXE}"
fi

cp Resources/Fonts/* "$APP/Contents/Resources/Fonts/"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${NAME}</string>
  <key>CFBundleDisplayName</key><string>${NAME}</string>
  <key>CFBundleIdentifier</key><string>app.stringjournal.notes</string>
  <key>CFBundleExecutable</key><string>${EXE}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>${MIN_OS}</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
</dict>
</plist>
PLIST

# ad-hoc signature so macOS will launch a locally built app
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built: $APP"
