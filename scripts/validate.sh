#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ "${1:-}" == scenarios ]]; then
    YASNO_VALIDATION_PROFILE="${2:-quick}"
    YASNO_VALIDATION_SEED="${3:-20261018}"
    if [[ "$YASNO_VALIDATION_PROFILE" != quick && "$YASNO_VALIDATION_PROFILE" != full && "$YASNO_VALIDATION_PROFILE" != huge ]]; then
        print -u2 'Usage: ./scripts/validate.sh scenarios quick|full|huge [seed]'
        exit 2
    fi
    if [[ ! -f .build/testdata/prepared/manifest.json ]]; then
        python3 scripts/fetch-testdata.py
    fi
    swift run -c release YasnoValidate --suite scenarios --profile "$YASNO_VALIDATION_PROFILE" \
        --seed "$YASNO_VALIDATION_SEED" --testdata "$PWD/.build/testdata/prepared" \
        --output "$PWD/.build/validation/scenarios-${YASNO_VALIDATION_PROFILE}-${YASNO_VALIDATION_SEED}"
    exit
fi
YASNO_VALIDATION_PROFILE="${1:-quick}"
YASNO_VALIDATION_SEED="${2:-20261018}"
if [[ "$YASNO_VALIDATION_PROFILE" != quick && "$YASNO_VALIDATION_PROFILE" != full ]]; then
    print -u2 'Usage: ./scripts/validate.sh quick|full [seed]  or  ./scripts/validate.sh scenarios quick|full|huge [seed]'
    exit 2
fi
YASNO_VALIDATION_OUTPUT="$PWD/.build/validation/${YASNO_VALIDATION_PROFILE}-${YASNO_VALIDATION_SEED}"
python3 -m unittest discover -s Tests/ValidationTools -v
swift test
swift run -c release YasnoValidate --profile "$YASNO_VALIDATION_PROFILE" --seed "$YASNO_VALIDATION_SEED" \
    --lexicon-root "$PWD/Sources/SwitchCore/Resources" --output "$YASNO_VALIDATION_OUTPUT"
