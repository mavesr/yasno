#!/bin/zsh
# Builds the test stand: the YasnoLab application bundle and the command-line helpers.
# Output: .build/lab/YasnoLab.app, .build/lab/{switch-test,ax-info,arrange-window,windows-on-screen,close-windows}.
# The lab is signed ad hoc; it needs no permissions of its own, the drivers post the events.
set -euo pipefail
cd "${0:A:h:h:h}"
out=.build/lab
mkdir -p "$out/YasnoLab.app/Contents/MacOS"
swiftc -swift-version 5 -O -o "$out/YasnoLab.app/Contents/MacOS/YasnoLab" scripts/lab/YasnoLab.swift
cp scripts/lab/Info.plist "$out/YasnoLab.app/Contents/Info.plist"
codesign --force --sign - "$out/YasnoLab.app" 2>/dev/null
for tool in ax-info arrange-window windows-on-screen close-windows; do
    swiftc -swift-version 5 -O -o "$out/$tool" "scripts/lab/$tool.swift"
done
swiftc -swift-version 5 -O -o "$out/switch-test" scripts/switch-test.swift
print "built: $out"
