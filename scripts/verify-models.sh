#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
APP_BINARY="$PROJECT_DIR/dist/CallScribe.app/Contents/MacOS/CallScribe"
FIXTURE_DIR="$HOME/Library/Containers/app.aifirm.callscribe/Data/Library/Application Support/CallScribe/Verification"

if [[ ! -x "$APP_BINARY" ]]; then
    "$PROJECT_DIR/scripts/build-app.sh"
fi
if [[ "${1:-}" == "--prepare" ]]; then
    "$APP_BINARY" --prepare-models
fi
mkdir -p "$FIXTURE_DIR"
say -v Samantha -r 155 -o "$FIXTURE_DIR/mic.aiff" \
    "I will send the project report on Friday. We should review the budget before our next meeting. Thank you for your help today."
say -v Daniel -r 150 -o "$FIXTURE_DIR/system.aiff" \
    "That sounds good. Please include the delivery schedule in the report. Our team can review the numbers on Monday morning."
say -v Karen -r 155 -o "$FIXTURE_DIR/system2.aiff" \
    "I have a different update from the design team. The new layouts are ready and I will share them after this meeting."
"$APP_BINARY" --verify-models
