#!/bin/zsh
# Builds Hush.app and installs it to /Applications.  Usage: ./build.sh [--no-install]
set -euo pipefail
cd "${0:A:h}"
swift build -c release
APP=build/Hush.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Hush "$APP/Contents/MacOS/Hush"
cp Info.plist "$APP/Contents/Info.plist"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# A real certificate keeps macOS permissions across rebuilds; ad hoc ("-") resets them every time.
IDENTITY=$(security find-identity -v -p codesigning | awk -F\" '/Apple Development|Developer ID/{print $2; exit}')
codesign --force --sign "${IDENTITY:--}" --identifier com.rahulkumar.hush "$APP"
echo "built $APP"
if [[ "${1:-}" != "--no-install" ]]; then
  pkill -x Hush 2>/dev/null || true
  rm -rf /Applications/Hush.app
  cp -R "$APP" /Applications/Hush.app
  echo "installed /Applications/Hush.app"
fi
