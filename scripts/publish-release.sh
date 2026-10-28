#!/bin/zsh
# Publishes the notarized build made by package-dmg.sh as a GitHub release.
# Running copies of Ясно check the latest release daily at 21:00 and install its
# Yasno-<version>-universal.zip in place. Requires the GitHub CLI (gh auth login).
# Optional: YASNO_RELEASE_REPO (default mavesr/yasno), YASNO_RELEASE_NOTES (text).
set -euo pipefail
cd "${0:A:h:h}"

YASNO_REPO="${YASNO_RELEASE_REPO:-mavesr/yasno}"
YASNO_VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/Ясно.app/Contents/Info.plist)}"
YASNO_ZIP="dist/Yasno-$YASNO_VERSION-universal.zip"
YASNO_DMG="dist/Yasno-$YASNO_VERSION-universal-notarized.dmg"
for file in "$YASNO_ZIP" "$YASNO_DMG"; do
    if [[ ! -f "$file" ]]; then
        print -u2 "Missing $file. Run: YASNO_NOTARY_PROFILE=yasno-distribution ./scripts/package-dmg.sh"
        exit 1
    fi
done

# Check the archive exactly as the updater will: Developer ID, notarized, right version.
YASNO_CHECK="$(mktemp -d)"
trap 'rm -rf "$YASNO_CHECK"' EXIT
ditto -x -k "$YASNO_ZIP" "$YASNO_CHECK"
YASNO_APP="$YASNO_CHECK/Ясно.app"
codesign --verify --deep --strict "$YASNO_APP"
codesign -dv --verbose=4 "$YASNO_APP" 2>&1 | grep -q 'Authority=Developer ID Application:'
codesign --verify --requirement '=notarized' "$YASNO_APP"
xcrun stapler validate "$YASNO_APP"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$YASNO_APP/Contents/Info.plist")" == "$YASNO_VERSION" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :YasnoUpdateRepository' "$YASNO_APP/Contents/Info.plist")" == "$YASNO_REPO" ]]

gh release create "v$YASNO_VERSION" "$YASNO_ZIP" "$YASNO_DMG" \
    --repo "$YASNO_REPO" --title "Ясно $YASNO_VERSION" \
    --notes "${YASNO_RELEASE_NOTES:-Ясно $YASNO_VERSION}"
print -r -- "Published v$YASNO_VERSION to $YASNO_REPO"
