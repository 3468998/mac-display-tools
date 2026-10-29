#!/bin/zsh
set -euo pipefail

source_dir="${0:A:h}"
bundle="${1:-$source_dir/VirtualDisplayControl.app}"
if [[ -e "$bundle" ]]; then
    print -u2 "Destination already exists: $bundle"
    exit 1
fi
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/virtualdesk-build.XXXXXX")"
clang -fobjc-arc -Wall -Wextra -target arm64-apple-macosx15.0 \
    -c "$source_dir/VirtualDeskEngine.m" -o "$build_dir/engine.o"
clang -fobjc-arc -Wall -Wextra -target arm64-apple-macosx15.0 \
    -c "$source_dir/VirtualDeskBridge.m" -o "$build_dir/bridge.o"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
swiftc -parse-as-library -O -target arm64-apple-macosx15.0 \
    -import-objc-header "$source_dir/VirtualDeskBridge.h" \
    -framework SwiftUI -framework AppKit -framework CoreGraphics \
    "$source_dir/VirtualDeskControl.swift" "$build_dir/engine.o" "$build_dir/bridge.o" \
    -o "$bundle/Contents/MacOS/VirtualDeskControl"
swift "$source_dir/VirtualDeskIcon.swift" "$build_dir/VirtualDesk.iconset"
iconutil -c icns "$build_dir/VirtualDesk.iconset" -o "$bundle/Contents/Resources/VirtualDesk.icns"
cp "$source_dir/VirtualDeskInfo.plist" "$bundle/Contents/Info.plist"
codesign --force --sign - "$bundle"
codesign --verify --deep --strict "$bundle"
plutil -lint "$bundle/Contents/Info.plist"
print "Built: $bundle"
