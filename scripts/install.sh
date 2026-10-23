#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
SOURCE_APP="$PROJECT_DIR/dist/Build.noindex/CallScribe.app"
DESTINATION_APP="/Applications/CallScribe.app"

if [[ ! -d "$SOURCE_APP" ]]; then
    "$PROJECT_DIR/scripts/build-app.sh"
fi

"$PROJECT_DIR/scripts/install-app.sh"
open "$DESTINATION_APP"
echo "$DESTINATION_APP"
