#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
# Never interrupt a recording to exercise a Run button.
python3 - <<'PY'
import pathlib,json,sys
root=pathlib.Path.home()/'Library/Containers/app.aifirm.callscribe/Data/Library/Application Support/CallScribe/Sessions'
for p in root.glob('*/manifest.json'):
    if json.loads(p.read_text()).get('state') == 'recording':
        sys.exit('Stop recording in CallScribe before rebuilding.')
PY
pkill -x CallScribe 2>/dev/null || true
./scripts/build-app.sh
open -n "$PROJECT_DIR/dist/CallScribe.app"
if [[ "${1:-}" == --verify ]]; then
    sleep 1
    pgrep -x CallScribe >/dev/null
elif [[ "${1:-}" == --logs ]]; then
    /usr/bin/log stream --info --style compact --predicate 'process == "CallScribe"'
fi
