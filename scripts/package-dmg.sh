#!/bin/zsh
# Signed universal distribution, separate from the locally installed build.
# Optional: YASNO_NOTARY_PROFILE names an existing notarytool Keychain profile.
set -euo pipefail
cd "${0:A:h:h}"

YASNO_ROOT="$PWD"
YASNO_WORK="$YASNO_ROOT/.build/distribution"
mkdir -p "$YASNO_WORK" "$YASNO_ROOT/dist"
YASNO_STAGE="$(mktemp -d "$YASNO_WORK/stage.XXXXXX")"
YASNO_MOUNT="$(mktemp -d "$YASNO_WORK/mount.XXXXXX")"
YASNO_RW_IMAGE="$YASNO_STAGE/installer-rw.dmg"
YASNO_MOUNTED=0
cleanup() {
    local yasno_result=$?
    if [[ -n "${YASNO_NOTARY_PROFILE:-}" ]] && (( yasno_result != 0 )); then
        print -r -- "Нотарификация не завершена: локальная задача остановилась (код $yasno_result).
Подписанный DMG сохранён. Сведения запроса: .build/distribution/pending-submission.json
Для продолжения существующего запроса: ./scripts/resume-notarization.sh
Журнал фоновой задачи: .build/distribution/notarization-background.log" > "$YASNO_ROOT/dist/Нотарификация.txt"
    fi
    if (( YASNO_MOUNTED )); then
        if ! hdiutil detach "$YASNO_MOUNT" >/dev/null; then return; fi
    fi
    rm -rf "$YASNO_STAGE"
    rmdir "$YASNO_MOUNT"
}
trap cleanup EXIT

if [[ -z "${YASNO_SIGNING_IDENTITY:-}" ]]; then
    YASNO_IDENTITIES=("${(@f)$(security find-identity -v -p codesigning | awk '/"Developer ID Application:/ {print $2}')}")
    if (( ${#YASNO_IDENTITIES} != 1 )) || [[ -z "$YASNO_IDENTITIES[1]" ]]; then
        print -u2 'Set YASNO_SIGNING_IDENTITY to a Developer ID Application identity.'
        exit 1
    fi
    YASNO_SIGNING_IDENTITY="$YASNO_IDENTITIES[1]"
fi

YASNO_APP="$YASNO_STAGE/payload/Ясно.app"
if [[ -n "${YASNO_PREBUILT_APP:-}" ]]; then
    # Preserve the exact signature of an already submitted app when resuming.
    ditto "$YASNO_PREBUILT_APP" "$YASNO_APP"
else
    YASNO_APP_PATH="$YASNO_APP" YASNO_SIGNING_IDENTITY=- YASNO_SKIP_DIAGNOSE=1 \
        ./scripts/build.sh --scratch-path .build/distribution-arm64 --triple arm64-apple-macosx14.0
    swift build -c release --scratch-path .build/distribution-x86_64 \
        --triple x86_64-apple-macosx14.0 --product Yasno
    YASNO_INTEL_DIR="$(swift build -c release --scratch-path .build/distribution-x86_64 \
        --triple x86_64-apple-macosx14.0 --show-bin-path)"
    lipo -create "$YASNO_APP/Contents/MacOS/Yasno" "$YASNO_INTEL_DIR/Yasno" \
        -output "$YASNO_STAGE/Yasno-universal"
    mv "$YASNO_STAGE/Yasno-universal" "$YASNO_APP/Contents/MacOS/Yasno"
    chmod 755 "$YASNO_APP/Contents/MacOS/Yasno"
    # The generated iconset is only a build intermediate, not a runtime resource.
    rm -rf "$YASNO_APP/Contents/Resources/AppIcon.iconset"
    xattr -cr "$YASNO_APP"
    codesign --force --sign "$YASNO_SIGNING_IDENTITY" --options runtime --timestamp \
        --identifier local.yasno.switcher "$YASNO_APP"
fi
codesign --verify --deep --strict --verbose=2 "$YASNO_APP"
if [[ "$(codesign -dv --verbose=4 "$YASNO_APP" 2>&1)" != *'Authority=Developer ID Application:'* ]]; then
    print -u2 'Distribution requires a Developer ID Application identity.'
    exit 1
fi
lipo "$YASNO_APP/Contents/MacOS/Yasno" -verify_arch arm64
lipo "$YASNO_APP/Contents/MacOS/Yasno" -verify_arch x86_64
"$YASNO_APP/Contents/MacOS/Yasno" --diagnose
YASNO_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$YASNO_APP/Contents/Info.plist")"
YASNO_RELEASE_DIR="$(mktemp -d "$YASNO_WORK/release-$YASNO_VERSION.XXXXXX")"
ditto "$YASNO_APP" "$YASNO_RELEASE_DIR/Ясно.app"
print -r -- "$YASNO_RELEASE_DIR/Ясно.app" > "$YASNO_WORK/latest-app-path.txt"
YASNO_STATUS=signed

if [[ -n "${YASNO_NOTARY_PROFILE:-}" ]]; then
    # Staple the app before packaging so the installed copy has its own ticket.
    if [[ -n "${YASNO_APP_SUBMISSION_ID:-}" ]]; then
        if [[ -z "${YASNO_PREBUILT_APP:-}" ]]; then
            print -u2 'Resuming a submission requires YASNO_PREBUILT_APP.'
            exit 1
        fi
    else
        ditto -c -k --keepParent "$YASNO_APP" "$YASNO_STAGE/Yasno-$YASNO_VERSION-app.zip"
        xcrun notarytool submit "$YASNO_STAGE/Yasno-$YASNO_VERSION-app.zip" \
            --keychain-profile "$YASNO_NOTARY_PROFILE" --output-format json > "$YASNO_RELEASE_DIR/submission.json"
        YASNO_APP_SUBMISSION_ID="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$YASNO_RELEASE_DIR/submission.json")"
        /usr/bin/python3 - "$YASNO_APP_SUBMISSION_ID" "$YASNO_RELEASE_DIR/Ясно.app" \
            "$YASNO_NOTARY_PROFILE" "$YASNO_WORK/pending-submission.json" <<'PY'
import json, pathlib, sys
target = pathlib.Path(sys.argv[4])
temporary = target.with_suffix('.tmp')
temporary.write_text(json.dumps({'id': sys.argv[1], 'app': sys.argv[2], 'profile': sys.argv[3]}, ensure_ascii=False), encoding='utf-8')
temporary.replace(target)
PY
        print -r -- "Apple submission: $YASNO_APP_SUBMISSION_ID"
    fi
    print -r -- "Проверка Apple для Ясно $YASNO_VERSION выполняется.
Запрос: $YASNO_APP_SUBMISSION_ID
Подписанный DMG: Yasno-$YASNO_VERSION-universal-signed.dmg
После проверки появится Yasno-$YASNO_VERSION-universal-notarized.dmg.
Локальная задача ожидает ответ Apple; после перезагрузки её можно продолжить:
./scripts/resume-notarization.sh" > "$YASNO_ROOT/dist/Нотарификация.txt"
    xcrun notarytool wait "$YASNO_APP_SUBMISSION_ID" \
        --keychain-profile "$YASNO_NOTARY_PROFILE" --timeout "${YASNO_NOTARY_TIMEOUT:-30m}" \
        --output-format json > "$YASNO_WORK/notary-app.json"
    /usr/bin/python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r); sys.exit(r.get("status") != "Accepted")' "$YASNO_WORK/notary-app.json"
    xcrun stapler staple "$YASNO_APP"
    xcrun stapler validate "$YASNO_APP"
    spctl --assess --type execute --verbose=2 "$YASNO_APP"
    YASNO_STATUS=notarized
    # The stapled app alone is the update archive the running copies download from GitHub.
    ditto -c -k --keepParent "$YASNO_APP" "$YASNO_STAGE/Yasno-$YASNO_VERSION-universal.zip"
    print -r -- "Приложение Ясно $YASNO_VERSION проверено Apple.
Завершается упаковка и отдельная проверка DMG." > "$YASNO_ROOT/dist/Нотарификация.txt"
fi

ln -s /Applications "$YASNO_STAGE/payload/Программы"
cp docs/Первый\ запуск.txt "$YASNO_STAGE/payload/Первый запуск.txt"
mkdir -p "$YASNO_STAGE/payload/.background"
swift scripts/make-dmg-background.swift "$YASNO_STAGE/payload/.background/background.png"
if [[ ! -x "$YASNO_ROOT/.build/dmg-tools/bin/python" ]]; then
    /usr/bin/python3 -m venv "$YASNO_ROOT/.build/dmg-tools"
fi
"$YASNO_ROOT/.build/dmg-tools/bin/python" -m pip install --disable-pip-version-check \
    -r scripts/dmg-requirements.txt
hdiutil create -volname 'Ясно' -srcfolder "$YASNO_STAGE/payload" \
    -fs HFS+ -format UDRW "$YASNO_RW_IMAGE"
hdiutil attach "$YASNO_RW_IMAGE" -readwrite -nobrowse -noautoopen \
    -mountpoint "$YASNO_MOUNT"
YASNO_MOUNTED=1
"$YASNO_ROOT/.build/dmg-tools/bin/python" scripts/dmg-layout.py "$YASNO_MOUNT"
hdiutil detach "$YASNO_MOUNT"
YASNO_MOUNTED=0
YASNO_DMG="$YASNO_STAGE/Yasno-$YASNO_VERSION-universal-$YASNO_STATUS.dmg"
hdiutil convert "$YASNO_RW_IMAGE" -format UDZO -imagekey zlib-level=9 \
    -o "$YASNO_DMG" -ov
codesign --force --sign "$YASNO_SIGNING_IDENTITY" --timestamp "$YASNO_DMG"
codesign --verify --strict --verbose=2 "$YASNO_DMG"
hdiutil verify "$YASNO_DMG"
if [[ -n "${YASNO_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$YASNO_DMG" --keychain-profile "$YASNO_NOTARY_PROFILE" \
        --wait --timeout "${YASNO_NOTARY_TIMEOUT:-30m}" --output-format json > "$YASNO_WORK/notary-dmg.json"
    /usr/bin/python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r); sys.exit(r.get("status") != "Accepted")' "$YASNO_WORK/notary-dmg.json"
    xcrun stapler staple "$YASNO_DMG"
    xcrun stapler validate "$YASNO_DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$YASNO_DMG"
fi
mv -f "$YASNO_DMG" "$YASNO_ROOT/dist/${YASNO_DMG:t}"
if [[ -f "$YASNO_STAGE/Yasno-$YASNO_VERSION-universal.zip" ]]; then
    mv -f "$YASNO_STAGE/Yasno-$YASNO_VERSION-universal.zip" "$YASNO_ROOT/dist/"
fi
YASNO_DMG="$YASNO_ROOT/dist/${YASNO_DMG:t}"
(cd "$YASNO_ROOT/dist" && shasum -a 256 "${YASNO_DMG:t}" > "${YASNO_DMG:t}.sha256")
if [[ -n "${YASNO_NOTARY_PROFILE:-}" ]]; then
    print -r -- "Проверка Apple завершена успешно.
Готов для передачи: ${YASNO_DMG:t}
Приложение и DMG подписаны Developer ID, подтверждения Apple прикреплены.
Проверки подписи, Gatekeeper и целостности DMG пройдены." > "$YASNO_ROOT/dist/Нотарификация.txt"
fi
print -r -- "DMG: $YASNO_DMG"
print -r -- "Notarization: $YASNO_STATUS"
