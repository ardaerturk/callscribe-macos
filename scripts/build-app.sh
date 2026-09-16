#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/CallScribe.app"
CONTENTS_DIR="$APP_DIR/Contents"
SIGN_IDENTITY="${CALLSCRIBE_SIGN_IDENTITY:--}"

cd "$PROJECT_DIR"
swift build -c release --product CallScribe --arch arm64
BIN_DIR="$(swift build -c release --product CallScribe --arch arm64 --show-bin-path)"

if [[ -d "$APP_DIR" ]]; then
    BACKUP_DIR="$(mktemp -d "$DIST_DIR/previous-build.XXXXXX")"
    mv "$APP_DIR" "$BACKUP_DIR/CallScribe.app"
fi
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$BIN_DIR/CallScribe" "$CONTENTS_DIR/MacOS/CallScribe"
cp "$PROJECT_DIR/Packaging/Info.plist" "$CONTENTS_DIR/Info.plist"
mkdir -p "$CONTENTS_DIR/Resources/Licenses"
cp "$PROJECT_DIR/.build/checkouts/FluidAudio/LICENSE" "$CONTENTS_DIR/Resources/Licenses/FluidAudio-LICENSE"
cp "$PROJECT_DIR/.build/checkouts/FluidAudio/ThirdPartyLicenses/"*.md "$CONTENTS_DIR/Resources/Licenses/"
cp "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$CONTENTS_DIR/Resources/Licenses/"
# FluidAudio's SwiftPM resources belong only to its unused LuxTTS feature.
# CallScribe uses ASR/diarization and needs no SwiftPM resource bundle.
chmod 755 "$CONTENTS_DIR/MacOS/CallScribe"

codesign --force --deep --sign "$SIGN_IDENTITY" \
    --entitlements "$PROJECT_DIR/Packaging/CallScribe.entitlements" \
    "$APP_DIR"

codesign --verify --deep --strict --verbose=2 "$APP_DIR"
echo "$APP_DIR"
