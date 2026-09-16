# CallScribe

A native Mac menu-bar app for local meeting transcripts. Built for Apple Silicon Macs running macOS 14.2 or later, including Mac mini and M1 MacBook Pro.

This is an initial personal-use build. Automated recovery checks pass; real calls, headphone changes, long meetings and M1 performance still need hands-on validation before relying on it for important meetings. See [VALIDATION.md](VALIDATION.md).

## Use

1. Open `CallScribe.app`. Its microphone appears in the menu bar. Right-click it for settings and saved sessions.
2. Right-click → **Language** → **English**, **Türkçe (Turkish)**, or **Deutsch (German)**. Choose **Prepare Offline Models** once for the selected language. Turkish and German share one multilingual download. Later launches and language changes load only local files. Language changes are disabled while starting, recording, processing, or preparing models.
3. Choose a microphone. Automatic selection prefers a recognized physical wired or built-in input when the default is Bluetooth, and otherwise keeps the Bluetooth input. Temporary internal audio devices are excluded. A Mac mini needs an external microphone, such as a webcam or USB mic.
4. Left-click the menu-bar microphone to start. Grant macOS microphone and system-audio permission when requested. Red means recording; orange means the mic is paused or recording needs attention. Open the menu to read the status.
5. Click again to stop. When processing finishes, the transcript is copied to the clipboard. Paste it into Codex or any other app.

`Control–Option–Command–R` starts/stops. `Control–Option–Command–M` pauses/resumes your microphone track while meeting audio continues. Muting Zoom, Meet or Teams does **not** pause CallScribe's microphone.

Recording is available before models are ready. Audio remains saved if processing cannot run. Prepare the models, then choose **Retry Saved Sessions**. Copy Last and Open Last remain available after relaunch. The app currently finishes processing before allowing another recording.

The chosen language is saved in each session before capture starts. Retries use that saved language, not the menu's current setting. Archives created before version 0.2 default to English. The app transcribes in the selected language rather than translating to English. Choose the main language of the meeting; mixed-language accuracy is not guaranteed. Changing the menu language does not rewrite older transcripts.

## Live English captions (optional)

Right-click → choose the meeting's **Language** → enable **Live English Captions**, then start recording normally. You can toggle captions during recording too. Enabling captions alone does not start recording. Use **Prepare Caption Model (one-time)** on a Mac that has not downloaded it yet; this additional model/tokenizer download is about 220 MB. There is no subscription, API key, per-minute charge, or cloud translation service.

Captions appear in a click-through panel near the bottom of the screen where recording/captions were enabled. The panel stays above ordinary windows and supports fullscreen Spaces. It moves to an available screen if its display disconnects. It displays translated **Call** and **You** lines, not live identities for individual remote speakers. English meetings get English captions without translation. Captions hide when disabled or recording stops. **An entire-screen share may include the panel**; do not assume it is hidden from viewers.

Live translation uses multilingual Whisper small (quantized `openai_whisper-small_216MB`), because the existing Turbo transcription model is not trained for translation. It waits for at least six seconds of audio context after starting or resetting a track, then processes the latest eight seconds approximately every three seconds plus inference time. Expect several seconds of lag, revisions/repetition across overlapping windows, and possible mistranslations, including unrelated phrases. Small-model translation is an experimental convenience feature, not an authoritative interpreter. Headphones reduce duplicated speech. Quiet speech may be missed by the silence-energy heuristic.

Caption inference never runs on the capture callback/recorder queue. Buffers and pending work are bounded; slow captions skip to newer audio rather than queueing the entire meeting. A slow or failed caption operation does not stop durable recording. Captions add CPU/Neural Engine work, memory use and battery consumption, and call performance still needs testing on both Macs. The caption model can remain loaded until quitting the app, even after captions are disabled. The original-language transcript and recoverable audio remain unchanged. Live English captions themselves are not saved or copied to the clipboard.

## What is saved

**Open Sessions Folder** opens the actual archive. In the packaged sandboxed app it is normally:

```
~/Library/Containers/app.aifirm.callscribe/Data/Library/Application Support/CallScribe/Sessions/
```

Each session contains an atomic JSON manifest, separate `mic/` and `system/` WAV chunks, and—after processing—`transcript.txt`, `transcript.md`, `transcript.json`, and `processing-state.json`. Chunks are 16 kHz mono, 16-bit PCM, finalized every 15 seconds and synchronized approximately every five seconds. Two tracks use about 230 MB per recorded hour. Processing temporarily uses additional disk space for the meeting-audio timeline.

Audio is retained until you remove its session in Finder. Relaunch repairs interrupted sessions and preserves unreadable chunks in `Corrupt/`. **Retry Saved Sessions** processes recoverable audio again. A power failure can still lose recent buffers; no recorder can recover audio that never reached disk.

## Behavior and limits

- Uses normal macOS permissions and recording indicators. Use it where recording is permitted and with any required agreement from participants.
- Works from microphone and system audio; it does not require a meeting bot, browser extension, virtual audio driver or changes to the call's input/output settings. The private Core Audio aggregate is internal to capture and is never selected as the call's audio device.
- System audio includes other playing apps and browser tabs. Pause unrelated media. It does not read meeting participant names or meeting captions.
- Mic speech is labeled **You**. Remote voices receive **Speaker 1**, **Speaker 2**, etc. Labels are local to a session. Overlapping voices, similar voices and poor audio can produce mistakes.
- With speakers, matching text across aligned tracks is deduplicated in favor of the direct meeting-audio track. This is a conservative transcript heuristic, not acoustic echo cancellation. Headphones are recommended when accurate attribution matters.
- Bluetooth microphones can cause macOS to switch headphones to lower-quality two-way audio. Automatic input selection avoids them when another input exists. Explicitly selecting a Bluetooth mic can still cause that OS behavior.
- Device changes and stalled callbacks trigger a restart with events saved in the manifest. Gaps during reconnects or sleep cannot be reconstructed. Audio timestamps use the running host clock; sleep events also retain wall-clock dates.
- Failure to capture one side leaves the available side recording and displays a warning. Storage errors are surfaced and the session is marked failed rather than complete.
- With captions off, speech inference runs only after Stop. Optional live captions run their own small model during capture, independently of the recorder. Models can remain loaded while the app is open; model memory is materially larger than the small menu UI. Final transcript processing reads chunks and uses a disk-backed remote timeline instead of holding an entire call's PCM in RAM.
- Inference is local after model preparation. English, Turkish and German are supported with manual selection. No cloud transcription, analytics, automatic updates, or account system.

## Build and install

Requires Xcode 16 or later / Swift 6 and an Apple Silicon Mac. Xcode 26 was used for the initial build.

```sh
swift test
./scripts/build-app.sh
open dist/CallScribe.app
```

The script creates an ARM64 `.app` with a stable bundle identifier, permissions and sandbox entitlements. It signs ad hoc by default. Set `CALLSCRIBE_SIGN_IDENTITY` to your Apple signing identity to sign differently. Ad-hoc signing is suitable for local builds; it is not Developer ID notarization. A downloaded copy on another Mac may require local rebuilding or normal macOS approval.

`./scripts/install.sh` installs into `/Applications` and opens the app. It refuses to overwrite an existing installation. Previous build bundles are preserved inside `dist/previous-build.*`.

Install separately on the MacBook Pro. It needs macOS 14.2+, its own model cache, and its own permission grants. Transcripts and settings do not synchronize automatically. Clipboard synchronization, if enabled in macOS, follows your system settings.

## Implementation

Swift/AppKit + SwiftUI, Core Audio process taps, AVAudioEngine and local files. Two pinned Swift packages: FluidAudio 0.15.6 for English Parakeet Unified recognition and Community-1 speaker clustering, and WhisperKit 1.1.0 for multilingual Whisper large-v3 turbo (quantized `openai_whisper-large-v3-v20240930_turbo_632MB`) and optional Whisper small captions. The English/speaker download is approximately 640 MB; Turkish and German share approximately 650 MB of additional model/tokenizer files, plus compilation/cache space. Captions add about 220 MB. WhisperKit's CLI dependency resolves Swift Argument Parser but the app does not link its CLI/server targets. No Python runtime, web server or Electron. Only one final-transcript speech-model selection is retained at a time, alongside the optional caption model; switching language can take time to load it.

`CallScribeCore` owns capture, device recovery and chunk persistence. `CallScribeTranscription` owns explicit model preparation and retryable processing. `CallScribeApp` owns state, settings, shortcuts and clipboard integration. `ModelHub.offlineMode` is enabled except during explicit model preparation.

Whisper is loaded with downloads disabled and an injected local tokenizer, avoiding the library's automatic tokenizer-download fallback. Missing/corrupt files fail locally and leave the audio available for retry. Use `scripts/verify-models.sh tr` or `de` for generated-speech smoke checks; append `--prepare` to allow initial downloads. The script does not record microphone or system audio.

## Research references

- [Apple Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [Apple Bluetooth audio behavior](https://support.apple.com/en-us/102217)
- [FluidAudio](https://github.com/FluidInference/FluidAudio)
- [Superwhisper meeting mode](https://superwhisper.com/docs/modes/meeting)
- [MacWhisper meeting recording](https://docs.macwhisper.com/article/30-record-meetings)
- [Audio Hijack](https://rogueamoeba.com/audiohijack/)

See [PRIVACY.md](PRIVACY.md) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
