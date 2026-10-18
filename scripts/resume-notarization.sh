#!/bin/zsh
# Finish the existing submission, without uploading another copy of the app.
set -euo pipefail
cd "${0:A:h:h}"
YASNO_PENDING_FILE="$PWD/.build/distribution/pending-submission.json"
YASNO_STATUS_FILE="$PWD/dist/Нотарификация.txt"
if [[ ! -f "$YASNO_PENDING_FILE" ]]; then
    print -u2 'No saved app submission. Use scripts/package-dmg.sh for a new build.'
    exit 1
fi
YASNO_PENDING_FIELDS=("${(@f)$(/usr/bin/python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["id"]); print(r["app"]); print(r["profile"])' "$YASNO_PENDING_FILE")}")
export YASNO_APP_SUBMISSION_ID="$YASNO_PENDING_FIELDS[1]"
export YASNO_PREBUILT_APP="$YASNO_PENDING_FIELDS[2]"
export YASNO_NOTARY_PROFILE="${YASNO_NOTARY_PROFILE:-$YASNO_PENDING_FIELDS[3]}"
export YASNO_NOTARY_TIMEOUT="${YASNO_NOTARY_TIMEOUT:-168h}"
YASNO_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$YASNO_PREBUILT_APP/Contents/Info.plist")"
print -r -- "Проверка Apple выполняется. Запрос: $YASNO_APP_SUBMISSION_ID
Подписанный DMG: Yasno-$YASNO_VERSION-universal-signed.dmg
После успешной проверки появится Yasno-$YASNO_VERSION-universal-notarized.dmg.
Эта задача работает, пока Mac включён. Во время сна проверка Apple продолжается,
а завершение сборки на Mac сможет продолжиться после пробуждения.
При перезагрузке возобновите задачу: ./scripts/resume-notarization.sh
Журнал: .build/distribution/notarization-background.log" > "$YASNO_STATUS_FILE"
if ./scripts/package-dmg.sh; then
    print -r -- "Проверка Apple завершена успешно.
Готов для передачи: Yasno-$YASNO_VERSION-universal-notarized.dmg
Приложение и DMG подписаны Developer ID, проверены Apple; подтверждения прикреплены.
Проверки подписи, Gatekeeper и целостности DMG пройдены." > "$YASNO_STATUS_FILE"
else
    YASNO_EXIT=$?
    print -r -- "Завершение сборки остановилось (код $YASNO_EXIT).
Подписанный DMG сохранён, но успешная нотарификация пока не подтверждена.
Журнал: .build/distribution/notarization-background.log
Для повторного ожидания существующего запроса: ./scripts/resume-notarization.sh" > "$YASNO_STATUS_FILE"
    exit "$YASNO_EXIT"
fi
