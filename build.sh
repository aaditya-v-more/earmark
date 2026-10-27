#!/bin/sh
# Builds a universal Earmark.app into build/. Signs ad hoc unless SIGN_IDENTITY is set.
set -eu
cd "$(dirname "$0")"
VERSION="${VERSION:-0.1.0}"
APP=build/Earmark.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos14.0" -module-name Earmark Sources/*.swift -o "build/Earmark-$arch"
done
lipo -create build/Earmark-arm64 build/Earmark-x86_64 -output "$APP/Contents/MacOS/Earmark"
rm build/Earmark-arm64 build/Earmark-x86_64

sed "s/VERSION/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/reader.js Resources/reader.css "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
