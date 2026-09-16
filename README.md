# CallScribe

A native Mac menu-bar app for local meeting transcripts. Built for Apple Silicon Macs running macOS 14.2 or later, including Mac mini and M1 MacBook Pro.

This is an initial personal-use build. Automated recovery checks pass; real calls, headphone changes, long meetings and M1 performance still need hands-on validation before relying on it for important meetings. See [VALIDATION.md](VALIDATION.md).

## Use

1. Open `CallScribe.app`. Its microphone appears in the menu bar. Right-click it for settings and saved sessions.
2. Choose **Prepare Models** once. The English speech and speaker models download to this Mac. Later launches load the cache with downloads disabled.
3. Choose a microphone. Automatic selection prefers a recognized physical wired or built-in input when the default is Bluetooth, and otherwise keeps the Bluetooth input. Temporary internal audio devices are excluded. A Mac mini needs an external microphone, such as a webcam or USB mic.
4. Left-click the menu-bar microphone to start. Grant macOS microphone and system-audio permission when requested. Red means recording; orange means the mic is paused or recording needs attention. Open the menu to read the status.
5. Click again to stop. When processing finishes, the transcript is copied to the clipboard. Paste it into Codex or any other app.

`Control–Option–Command–R` starts/stops. `Control–Option–Command–M` pauses/resumes your microphone track while meeting audio continues. Muting Zoom, Meet or Teams does **not** pause CallScribe's microphone.

Recording is available before models are ready. Audio remains saved if processing cannot run. Prepare the models, then choose **Retry Saved Sessions**. Copy Last and Open Last remain available after relaunch. The app currently finishes processing before allowing another recording.

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
- Recording itself does not run speech models. Models process saved audio after Stop. The model set remains loaded while the app is open; model memory is materially larger than the small menu UI. Audio processing reads chunks and uses a disk-backed remote timeline instead of holding an entire call's PCM in RAM.
- Inference is local after model preparation. English is the initial supported language. No cloud transcription, analytics, automatic updates, or account system.

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

Swift/AppKit + SwiftUI, Core Audio process taps, AVAudioEngine and local files. One pinned Swift package: FluidAudio 0.15.6. It supplies English Parakeet Unified recognition with an INT8 encoder and offline Community-1 speaker clustering through Core ML, plus bundled native components. The expected model download is approximately 640 MB, with additional local compilation/cache space. No Python runtime, web server or Electron.

`CallScribeCore` owns capture, device recovery and chunk persistence. `CallScribeTranscription` owns explicit model preparation and retryable processing. `CallScribeApp` owns state, settings, shortcuts and clipboard integration. `ModelHub.offlineMode` is enabled except during explicit model preparation.

## Research references

- [Apple Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [Apple Bluetooth audio behavior](https://support.apple.com/en-us/102217)
- [FluidAudio](https://github.com/FluidInference/FluidAudio)
- [Superwhisper meeting mode](https://superwhisper.com/docs/modes/meeting)
- [MacWhisper meeting recording](https://docs.macwhisper.com/article/30-record-meetings)
- [Audio Hijack](https://rogueamoeba.com/audiohijack/)

See [PRIVACY.md](PRIVACY.md) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
