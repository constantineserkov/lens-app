#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

app=Lens.app
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
xcrun lipo "$app/Contents/MacOS/Lens" -verify_arch arm64 x86_64
codesign --verify --deep --strict "$app"
cmp LICENSE "$app/Contents/Resources/LICENSE"

mkdir -p dist
archive="Lens-$version-macos-universal.zip"
ditto -c -k --norsrc --keepParent "$app" "dist/$archive"
(
  cd dist
  shasum -a 256 "$archive" > SHA256SUMS.txt
)
print "Packaged: dist/$archive"
