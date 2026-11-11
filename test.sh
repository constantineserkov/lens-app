#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
test_dir=$(mktemp -d -t Lens-test)
trap 'rm -rf "$test_dir"' EXIT
swiftc -swift-version 5 -framework AppKit \
  Sources/Core.swift Sources/Batch.swift Sources/History.swift \
  Sources/PanelPlacement.swift Tests/main.swift -o "$test_dir/LensTests"
"$test_dir/LensTests"
