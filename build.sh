#!/usr/bin/env bash
# Builds build/SoftLock.app (universal, ad-hoc signed).
# Usage: ./build.sh            build only
#        ./build.sh install    build and copy to /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP=build/SoftLock.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"

for arch in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -parse-as-library \
    -target "$arch-apple-macos13.0" \
    Sources/*.swift -o "build/SoftLock-$arch"
done
lipo -create build/SoftLock-arm64 build/SoftLock-x86_64 -output "$APP/Contents/MacOS/SoftLock"
rm build/SoftLock-arm64 build/SoftLock-x86_64

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
  pkill -x SoftLock || true
  rm -rf /Applications/SoftLock.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/SoftLock.app"
  open /Applications/SoftLock.app
fi
