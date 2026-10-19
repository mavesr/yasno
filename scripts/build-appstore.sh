#!/bin/zsh
# Mac App Store build: universal, App Sandbox, signed for distribution and packaged as .pkg.
# Inside the sandbox AX requests to other applications fail, so this build corrects every
# field with keystrokes only (see AccessibleEditor.blind). The DMG keeps the full behaviour.
#
# Required: YASNO_APPSTORE_PROFILE — a Mac App Store provisioning profile for the bundle ID.
# Optional: YASNO_APPSTORE_BUILD (build number override), YASNO_APPSTORE_BUNDLE_ID (com.mavesr.yasno), YASNO_APP_IDENTITY (the single
# "Apple Distribution" identity), YASNO_INSTALLER_IDENTITY (the single installer identity).
# Upload: YASNO_ASC_KEY_ID and YASNO_ASC_ISSUER with AuthKey_<id>.p8 in ~/.appstoreconnect/private_keys.
set -euo pipefail
cd "${0:A:h:h}"

YASNO_BUNDLE_ID="${YASNO_APPSTORE_BUNDLE_ID:-com.mavesr.yasno}"
YASNO_PROFILE="${YASNO_APPSTORE_PROFILE:?Set YASNO_APPSTORE_PROFILE to a Mac App Store provisioning profile.}"
single_identity() {
    local identities=("${(@f)$(security find-identity -v "$@" | awk -F'"' -v p="$YASNO_IDENTITY_PATTERN" '$2 ~ p {print $2}')}")
    if (( ${#identities} != 1 )) || [[ -z "$identities[1]" ]]; then
        print -u2 "Expected exactly one identity matching: $YASNO_IDENTITY_PATTERN"
        exit 1
    fi
    print -r -- "$identities[1]"
}
if [[ -z "${YASNO_APP_IDENTITY:-}" ]]; then
    YASNO_IDENTITY_PATTERN='^Apple Distribution:' YASNO_APP_IDENTITY="$(single_identity -p codesigning)"
fi
if [[ -z "${YASNO_INSTALLER_IDENTITY:-}" ]]; then
    YASNO_IDENTITY_PATTERN='^(3rd Party Mac Developer Installer|Mac Installer Distribution):' \
        YASNO_INSTALLER_IDENTITY="$(single_identity)"
fi

YASNO_WORK="$PWD/.build/appstore"
rm -rf "$YASNO_WORK/stage"
mkdir -p "$YASNO_WORK/stage" dist
YASNO_APP="$YASNO_WORK/stage/Ясно.app"
YASNO_APP_PATH="$YASNO_APP" YASNO_SIGNING_IDENTITY=- YASNO_SKIP_DIAGNOSE=1 \
    ./scripts/build.sh --scratch-path .build/distribution-arm64 --triple arm64-apple-macosx14.0
swift build -c release --scratch-path .build/distribution-x86_64 --triple x86_64-apple-macosx14.0 --product Yasno
YASNO_INTEL_DIR="$(swift build -c release --scratch-path .build/distribution-x86_64 \
    --triple x86_64-apple-macosx14.0 --show-bin-path)"
lipo -create "$YASNO_APP/Contents/MacOS/Yasno" "$YASNO_INTEL_DIR/Yasno" -output "$YASNO_WORK/Yasno-universal"
mv "$YASNO_WORK/Yasno-universal" "$YASNO_APP/Contents/MacOS/Yasno"
chmod 755 "$YASNO_APP/Contents/MacOS/Yasno"
rm -rf "$YASNO_APP/Contents/Resources/AppIcon.iconset"

YASNO_PLIST="$YASNO_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $YASNO_BUNDLE_ID" "$YASNO_PLIST"
/usr/libexec/PlistBuddy -c 'Add :LSApplicationCategoryType string public.app-category.productivity' "$YASNO_PLIST"
/usr/libexec/PlistBuddy -c 'Add :ITSAppUsesNonExemptEncryption bool false' "$YASNO_PLIST"
# App Store Connect needs a new build number for every upload of the same version.
if [[ -n "${YASNO_APPSTORE_BUILD:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $YASNO_APPSTORE_BUILD" "$YASNO_PLIST"
fi

security cms -D -i "$YASNO_PROFILE" > "$YASNO_WORK/profile.plist"
YASNO_TEAM="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$YASNO_WORK/profile.plist")"
YASNO_PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$YASNO_WORK/profile.plist")"
if [[ "$YASNO_PROFILE_APP_ID" != "$YASNO_TEAM.$YASNO_BUNDLE_ID" ]]; then
    print -u2 "The profile is for $YASNO_PROFILE_APP_ID, not $YASNO_TEAM.$YASNO_BUNDLE_ID."
    exit 1
fi
cp "$YASNO_PROFILE" "$YASNO_APP/Contents/embedded.provisionprofile"
cat > "$YASNO_WORK/entitlements.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.application-identifier</key><string>$YASNO_TEAM.$YASNO_BUNDLE_ID</string>
<key>com.apple.developer.team-identifier</key><string>$YASNO_TEAM</string>
</dict></plist>
PLIST
xattr -cr "$YASNO_APP"
codesign --force --sign "$YASNO_APP_IDENTITY" --options runtime --timestamp \
    --entitlements "$YASNO_WORK/entitlements.plist" --identifier "$YASNO_BUNDLE_ID" "$YASNO_APP"
codesign --verify --deep --strict --verbose=2 "$YASNO_APP"
lipo "$YASNO_APP/Contents/MacOS/Yasno" -verify_arch arm64
lipo "$YASNO_APP/Contents/MacOS/Yasno" -verify_arch x86_64

YASNO_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$YASNO_PLIST")"
YASNO_PKG="$PWD/dist/Yasno-$YASNO_VERSION-appstore.pkg"
productbuild --component "$YASNO_APP" /Applications --sign "$YASNO_INSTALLER_IDENTITY" "$YASNO_PKG"
pkgutil --check-signature "$YASNO_PKG"
print -r -- "$YASNO_PKG"

if [[ -n "${YASNO_ASC_KEY_ID:-}" ]]; then
    xcrun altool --validate-app -f "$YASNO_PKG" -t macos \
        --apiKey "$YASNO_ASC_KEY_ID" --apiIssuer "${YASNO_ASC_ISSUER:?Set YASNO_ASC_ISSUER.}"
    xcrun altool --upload-app -f "$YASNO_PKG" -t macos \
        --apiKey "$YASNO_ASC_KEY_ID" --apiIssuer "$YASNO_ASC_ISSUER"
fi
