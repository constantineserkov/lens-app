#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

case "$#" in
  0) lens_archs=("$(uname -m)") ;;
  1) [[ "$1" == --universal ]] || { print -u2 "Usage: $0 [--universal]"; exit 2; }
     lens_archs=(arm64 x86_64) ;;
  *) print -u2 "Usage: $0 [--universal]"; exit 2 ;;
esac

stage_dir=$(mktemp -d -t Lens-build)
trap 'rm -rf "$stage_dir"' EXIT
app="$stage_dir/Lens.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

for lens_arch in "${lens_archs[@]}"; do
  swiftc -O -swift-version 5 -target "$lens_arch-apple-macosx14.0" \
    -file-prefix-map "$PWD=." \
    -framework AppKit -framework SwiftUI -framework Carbon \
    Sources/Core.swift Sources/Batch.swift Sources/History.swift \
    Sources/PanelPlacement.swift Sources/App.swift Sources/main.swift \
    -o "$stage_dir/Lens-$lens_arch"
done
if (( ${#lens_archs[@]} == 2 )); then
  xcrun lipo -create "$stage_dir/Lens-arm64" "$stage_dir/Lens-x86_64" \
    -output "$app/Contents/MacOS/Lens"
else
  cp "$stage_dir/Lens-${lens_archs[1]}" "$app/Contents/MacOS/Lens"
fi
chmod +x "$app/Contents/MacOS/Lens"
cp Assets/Info.plist "$app/Contents/Info.plist"
cp Assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp LICENSE "$app/Contents/Resources/LICENSE"
xattr -cr "$app"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
# Replace only the previous build output; do not merge stale bundle resources.
rm -rf "$PWD/Lens.app"
ditto "$app" "$PWD/Lens.app"
print "Built: $PWD/Lens.app"
