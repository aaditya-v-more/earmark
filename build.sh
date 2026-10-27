#!/bin/sh
# Builds a universal Earmark.app into build/. Signs ad hoc unless SIGN_IDENTITY is set.
# DEV=1 builds "Earmark Dev" into build-dev/ instead: its own bundle id, process name,
# settings and caches, so it can be tested next to an installed Earmark.
set -eu
cd "$(dirname "$0")"
VERSION="${VERSION:-0.1.0}"
if [ "${DEV:-}" = 1 ]; then
  NAME="Earmark Dev"; EXEC=EarmarkDev; ID=com.aadityavmore.earmark.dev; OUT=build-dev
else
  NAME=Earmark; EXEC=Earmark; ID=com.aadityavmore.earmark; OUT=build
fi
APP="$OUT/$NAME.app"
rm -rf "$OUT" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos14.0" -module-name Earmark Sources/*.swift -o "$OUT/$EXEC-$arch"
done
lipo -create "$OUT/$EXEC-arm64" "$OUT/$EXEC-x86_64" -output "$APP/Contents/MacOS/$EXEC"
rm "$OUT/$EXEC-arm64" "$OUT/$EXEC-x86_64"

sed -e "s/VERSION/$VERSION/g" \
    -e "s|<string>Earmark</string>|<string>$NAME</string>|g" \
    -e "s|<key>CFBundleExecutable</key><string>$NAME</string>|<key>CFBundleExecutable</key><string>$EXEC</string>|" \
    -e "s|com.aadityavmore.earmark<|$ID<|" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/reader.js Resources/reader.css "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
