#!/bin/zsh
set -euo pipefail

source_dir="${0:A:h}"
bundle="${1:-$source_dir/../build/便携屏控制.app}"
if [[ -e "$bundle" ]]; then
    print -u2 "Destination already exists: $bundle"
    exit 1
fi
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources/DisplayProfiles"
clang -fobjc-arc -O2 -target arm64-apple-macosx13.0 \
    -framework Foundation -framework IOKit -framework SystemConfiguration \
    "$source_dir/portable-edid.m" -o "$bundle/Contents/MacOS/portable-edid"
swiftc -O -target arm64-apple-macosx13.0 \
    -framework Foundation -framework CoreGraphics \
    "$source_dir/display-mode.swift" -o "$bundle/Contents/MacOS/display-mode"
swiftc -O -target arm64-apple-macosx13.0 \
    -framework Foundation "$source_dir/StartupManager.swift" \
    -o "$bundle/Contents/MacOS/startup-manager"
swiftc -parse-as-library -O -target arm64-apple-macosx13.0 \
    -framework SwiftUI -framework AppKit -framework CoreGraphics \
    "$source_dir/PortableDisplayControl.swift" -o "$bundle/Contents/MacOS/PortableDisplayControl"
cp "$source_dir/Info.plist" "$bundle/Contents/Info.plist"
cp "$source_dir/profiles/"*.bin "$bundle/Contents/Resources/DisplayProfiles/"
for tool in portable-edid display-mode startup-manager; do
    codesign --force --sign - "$bundle/Contents/MacOS/$tool"
done
codesign --force --sign - "$bundle"
codesign --verify --deep --strict "$bundle"
plutil -lint "$bundle/Contents/Info.plist"
print "Built: $bundle"
