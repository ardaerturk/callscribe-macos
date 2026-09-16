#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
APP_BINARY="$PROJECT_DIR/dist/CallScribe.app/Contents/MacOS/CallScribe"
LANGUAGE_CODE="${1:-en}"
PREPARE_MODELS="${2:-}"
if [[ "$LANGUAGE_CODE" == --prepare ]]; then LANGUAGE_CODE=en; PREPARE_MODELS=--prepare; fi
if [[ "$LANGUAGE_CODE" != en && "$LANGUAGE_CODE" != tr && "$LANGUAGE_CODE" != de ]]; then
    echo 'Usage: verify-models.sh [en|tr|de] [--prepare]' >&2
    exit 1
fi
FIXTURE_DIR="$HOME/Library/Containers/app.aifirm.callscribe/Data/Library/Application Support/CallScribe/Verification/$LANGUAGE_CODE"

if [[ ! -x "$APP_BINARY" ]]; then
    "$PROJECT_DIR/scripts/build-app.sh"
fi
if [[ "$PREPARE_MODELS" == "--prepare" ]]; then
    "$APP_BINARY" --prepare-models --language "$LANGUAGE_CODE"
fi
mkdir -p "$FIXTURE_DIR"
if [[ "$LANGUAGE_CODE" == tr ]]; then
    say -v Yelda -r 155 -o "$FIXTURE_DIR/mic.aiff" \
        "Merhaba, bugün proje takvimini konuşacağız. Raporu cuma günü göndereceğim. Bütçeyi tekrar kontrol etmemiz gerekiyor."
    say -v Yelda -r 145 -o "$FIXTURE_DIR/system.aiff" \
        "Teşekkür ederim. Toplantıdan sonra tasarım dosyalarını paylaşacağım. Gelecek hafta sonuçları birlikte değerlendirebiliriz."
elif [[ "$LANGUAGE_CODE" == de ]]; then
    say -v Anna -r 155 -o "$FIXTURE_DIR/mic.aiff" \
        "Guten Morgen. Heute besprechen wir den Projektplan. Ich werde den Bericht am Freitag schicken. Wir müssen das Budget noch einmal prüfen."
    say -v 'Eddy (German (Germany))' -r 150 -o "$FIXTURE_DIR/system.aiff" \
        "Vielen Dank. Ich werde die neuen Entwürfe nach der Besprechung teilen. Nächste Woche können wir die Ergebnisse gemeinsam prüfen."
else
say -v Samantha -r 155 -o "$FIXTURE_DIR/mic.aiff" \
    "I will send the project report on Friday. We should review the budget before our next meeting. Thank you for your help today."
say -v Daniel -r 150 -o "$FIXTURE_DIR/system.aiff" \
    "That sounds good. Please include the delivery schedule in the report. Our team can review the numbers on Monday morning."
say -v Karen -r 155 -o "$FIXTURE_DIR/system2.aiff" \
    "I have a different update from the design team. The new layouts are ready and I will share them after this meeting."
fi
"$APP_BINARY" --verify-models --language "$LANGUAGE_CODE"
