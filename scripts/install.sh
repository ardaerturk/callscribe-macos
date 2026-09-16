#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
SOURCE_APP="$PROJECT_DIR/dist/CallScribe.app"
DESTINATION_APP="/Applications/CallScribe.app"

if [[ ! -d "$SOURCE_APP" ]]; then
    "$PROJECT_DIR/scripts/build-app.sh"
fi

if [[ -e "$DESTINATION_APP" ]]; then
    echo "An installation already exists at $DESTINATION_APP. Quit it and move it aside before installing this build." >&2
    exit 1
fi

ditto "$SOURCE_APP" "$DESTINATION_APP"
open "$DESTINATION_APP"
echo "$DESTINATION_APP"
