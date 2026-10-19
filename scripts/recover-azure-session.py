#!/usr/bin/env python3
"""Explicit cloud recovery of an archived call track; never changes original audio.
Uses the signed-in Azure CLI for credentials without logging or saving keys.
Existing responses are reused so rerunning does not repeat paid transcription.
"""
import argparse
import json
import pathlib
import subprocess
import wave
import requests

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('session', type=pathlib.Path)
parser.add_argument('--resource', required=True)
parser.add_argument('--resource-group', required=True)
parser.add_argument('--region', required=True)
args = parser.parse_args()
manifest = json.loads((args.session / 'manifest.json').read_text())
out = args.session / 'Recovery-Azure'
out.mkdir(exist_ok=True)
keys = json.loads(subprocess.check_output(['az', 'cognitiveservices', 'account', 'keys', 'list', '-n', args.resource, '-g', args.resource_group, '-o', 'json']))
key = keys['key1']
response_path = out / 'azure-transcription.json'
if not response_path.exists():
    chunks = sorted((c for c in manifest['chunks'] if c['track'] == 'system'), key=lambda c: c['startFrame'])
    wav_path = out / 'call-recovery.wav'
    cursor = 0
    with wave.open(str(wav_path), 'wb') as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(16000)
        for chunk in chunks:
            with wave.open(str(args.session / chunk['relativePath']), 'rb') as source:
                if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, 16000):
                    raise ValueError('Unexpected source format')
                pcm = source.readframes(source.getnframes())
            gap = chunk['startFrame'] - cursor
            if gap > 0:
                output.writeframes(b'\0' * (gap * 2))
                cursor += gap
            elif gap < 0:
                pcm = pcm[min(-gap * 2, len(pcm)):]
            output.writeframes(pcm)
            cursor += len(pcm) // 2
    print(f'Transcribing {cursor / 16000 / 60:.1f} minutes of saved call audio in Azure…', flush=True)
    endpoint = f'https://{args.resource}.cognitiveservices.azure.com/speechtotext/transcriptions:transcribe?api-version=2025-10-15'
    with wav_path.open('rb') as audio:
        response = requests.post(endpoint, headers={'Ocp-Apim-Subscription-Key': key}, files={
            'audio': (wav_path.name, audio, 'audio/wav'),
            'definition': (None, json.dumps({'locales': ['de-DE', 'en-US'], 'diarization': {'enabled': True, 'maxSpeakers': 8}}), 'application/json')
        }, timeout=(30, 900))
    response.raise_for_status()
    result = response.json()
    response_path.write_text(json.dumps(result, ensure_ascii=False, indent=2))
    wav_path.unlink()  # Only the temporary assembled copy; source chunks are retained.
else:
    result = json.loads(response_path.read_text())
phrases = result.get('phrases', [])
if not phrases:
    raise ValueError('Azure returned no phrases; original audio is retained')
translations_path = out / 'english-phrases.json'
if translations_path.exists():
    english = json.loads(translations_path.read_text())
else:
    english = [None] * len(phrases)
    for language in ['de', 'en']:
        indices = [i for i, p in enumerate(phrases) if (p.get('locale', 'de-DE').startswith('en')) == (language == 'en')]
        if language == 'en':
            for i in indices: english[i] = phrases[i]['text']
            continue
        while indices:
            batch, chars = [], 0
            while indices and len(batch) < 100 and chars + len(phrases[indices[0]]['text']) < 45000:
                i = indices.pop(0)
                batch.append(i)
                chars += len(phrases[i]['text'])
            if not batch: raise ValueError('An individual phrase exceeds the translation request limit')
            response = requests.post('https://api.cognitive.microsofttranslator.com/translate', params={'api-version': '3.0', 'from': 'de', 'to': 'en'},
                headers={'Ocp-Apim-Subscription-Key': key, 'Ocp-Apim-Subscription-Region': args.region},
                json=[{'Text': phrases[i]['text']} for i in batch], timeout=(30, 120))
            response.raise_for_status()
            for i, translated in zip(batch, response.json()): english[i] = translated['translations'][0]['text']
    translations_path.write_text(json.dumps(english, ensure_ascii=False, indent=2))
for name, translated in [('recovered-original.md', False), ('recovered-english.md', True)]:
    lines = ['# Recovered call — ' + ('English' if translated else 'original language'), '',
        'Machine transcription' + (' and translation' if translated else '') + ' of the saved call-audio track. Speaker labels are approximate. The separate microphone track is not included.', '']
    for i, phrase in enumerate(phrases):
        sec = int(phrase.get('offsetMilliseconds', 0) / 1000)
        text = english[i] if translated else phrase['text']
        lines.append(f'**{sec // 60:02}:{sec % 60:02} · Speaker {phrase.get("speaker", "?")}** {text}\n')
    (out / name).write_text('\n'.join(lines))
print(f'Recovered {len(phrases)} phrases; English: {out / "recovered-english.md"}', flush=True)
