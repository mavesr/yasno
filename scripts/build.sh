#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ -z "${YASNO_SIGNING_IDENTITY:-}" ]]; then
    YASNO_IDENTITIES=("${(@f)$(security find-identity -v -p codesigning | awk '/"Apple Development:/ {print $2}')}")
    if (( ${#YASNO_IDENTITIES} != 1 )) || [[ -z "$YASNO_IDENTITIES[1]" ]]; then
        print -u2 'Set YASNO_SIGNING_IDENTITY to an Apple Development identity, or to - for ad-hoc signing (macOS will ask for permissions again).'
        exit 1
    fi
    YASNO_SIGNING_IDENTITY="$YASNO_IDENTITIES[1]"
fi
swift build -c release "$@"
YASNO_BINARY_DIR="$(swift build -c release "$@" --show-bin-path)"
YASNO_APP="${YASNO_APP_PATH:-$PWD/dist/Ясно.app}"
mkdir -p "$YASNO_APP/Contents/MacOS" "$YASNO_APP/Contents/Resources"
cp "$YASNO_BINARY_DIR/Yasno" "$YASNO_APP/Contents/MacOS/Yasno"
ditto "$YASNO_BINARY_DIR/Yasno_SwitchCore.bundle" "$YASNO_APP/Contents/Resources/Yasno_SwitchCore.bundle"
cat > "$YASNO_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.yasno.switcher</string>
<key>CFBundleExecutable</key><string>Yasno</string>
<key>CFBundleName</key><string>Ясно</string>
<key>CFBundleDisplayName</key><string>Ясно</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.6</string>
<key>CFBundleVersion</key><string>17</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAccessibilityUsageDescription</key><string>Ясно исправляет слово в активном поле и переключает раскладку. Введённый текст не сохраняется и не передаётся.</string>
</dict></plist>
PLIST
swift scripts/make-icon.swift "$YASNO_APP/Contents/Resources"
iconutil -c icns "$YASNO_APP/Contents/Resources/AppIcon.iconset" -o "$YASNO_APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "$YASNO_SIGNING_IDENTITY" --timestamp=none --identifier local.yasno.switcher "$YASNO_APP"
codesign --verify --deep --strict "$YASNO_APP"
if [[ "${YASNO_SKIP_DIAGNOSE:-0}" != 1 ]]; then
    "$YASNO_APP/Contents/MacOS/Yasno" --diagnose
fi
print -r -- "$YASNO_APP"
