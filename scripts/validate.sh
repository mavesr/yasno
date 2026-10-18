#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
YASNO_VALIDATION_PROFILE="${1:-quick}"
YASNO_VALIDATION_SEED="${2:-20261018}"
if [[ "$YASNO_VALIDATION_PROFILE" != quick && "$YASNO_VALIDATION_PROFILE" != full ]]; then
    print -u2 'Usage: ./scripts/validate.sh quick|full [seed]'
    exit 2
fi
YASNO_VALIDATION_OUTPUT="$PWD/.build/validation/${YASNO_VALIDATION_PROFILE}-${YASNO_VALIDATION_SEED}"
python3 -m unittest discover -s Tests/ValidationTools -v
swift test
swift run -c release YasnoValidate --profile "$YASNO_VALIDATION_PROFILE" --seed "$YASNO_VALIDATION_SEED" \
    --lexicon-root "$PWD/Sources/SwitchCore/Resources" --output "$YASNO_VALIDATION_OUTPUT"
