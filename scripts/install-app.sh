#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
python3 - "$PROJECT_DIR/dist/Build.noindex/CallScribe.app" <<'PY'
import json, os, pathlib, shutil, signal, subprocess, sys, tempfile, time

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path('/Applications/CallScribe.app')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(source)], check=True)
sessions = pathlib.Path.home() / 'Library/Containers/app.aifirm.callscribe/Data/Library/Application Support/CallScribe/Sessions'
def require_idle():
    for manifest in sessions.glob('*/manifest.json'):
        if json.loads(manifest.read_text()).get('state') == 'recording':
            sys.exit('Stop recording in CallScribe before installing. No app was replaced.')

require_idle()

def processes():
    result = subprocess.run(['pgrep', '-x', 'CallScribe'], capture_output=True, text=True)
    return [int(pid) for pid in result.stdout.split()]

staging = pathlib.Path(tempfile.mkdtemp(prefix='.CallScribe-install.', suffix='.noindex', dir='/Applications'))
try:
    staged_app = staging / 'CallScribe.app'
    subprocess.run(['ditto', str(source), str(staged_app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(staged_app)], check=True)
    require_idle()
    for pid in processes():
        try: os.kill(pid, signal.SIGTERM)
        except ProcessLookupError: pass
    for _ in range(50):
        if not processes(): break
        time.sleep(0.1)
    else:
        sys.exit('CallScribe is still running; installation cancelled.')
    backup = None
    if destination.exists():
        archive = pathlib.Path.home() / 'Library/Application Support/CallScribe/App Backups.noindex'
        archive.mkdir(parents=True, exist_ok=True)
        backup = pathlib.Path(tempfile.mkdtemp(prefix='installed-', dir=archive)) / 'CallScribe.app.backup'
        destination.rename(backup)
    try:
        staged_app.rename(destination)
    except Exception:
        if backup is not None: backup.rename(destination)
        raise
finally:
    shutil.rmtree(staging)
register = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
subprocess.run([register, '-f', str(destination)], check=True)
print('Installed and registered /Applications/CallScribe.app')
PY
