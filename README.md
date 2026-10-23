# CallScribe

A native Mac app for local meeting transcripts and live English captions, with a recording window and menu-bar controls. Built for Apple Silicon Macs running macOS 14.2 or later, including Mac mini and M1 MacBook Pro.

This is an initial personal-use build. Automated recovery checks pass; real calls, headphone changes, long meetings and M1 performance still need hands-on validation before relying on it for important meetings. See [VALIDATION.md](VALIDATION.md).

## Use

1. Open **CallScribe** from Applications, Spotlight or the Dock. A recording window appears with a **Start Recording** button. Opening the app again brings that window back, including after closing or minimizing it. The menu-bar microphone remains an additional control.
2. Choose **English**, **Türkçe (Turkish)**, or **Deutsch (German)** in the meeting-language picker. For local saved transcripts, choose **Prepare Offline Models** in Settings. Turkish and German share one multilingual download. Startup and language selection check readiness without compiling or loading models; preparation and final transcription load them when needed. Language changes are disabled while starting, recording, processing, or preparing models.
3. Choose a microphone. Automatic selection prefers a recognized physical wired or built-in input when the default is Bluetooth, and otherwise keeps the Bluetooth input. Temporary internal audio devices are excluded. A Mac mini needs an external microphone, such as a webcam or USB mic.
4. Click **Start Recording** in the window, or left-click the menu-bar microphone. Grant macOS microphone and system-audio permission when requested. Red means recording; orange means the mic is paused or recording needs attention. The window shows recording and caption status.
5. Click **Stop Recording** when finished. If live English captions were saved, their text is exported and copied after the stream finishes; no second transcription or cloud charge is needed. **Open Saved Text** and **Copy Saved Text** remain available after relaunch. Without saved captions, a local transcript is generated only if its models are already prepared.

`Control–Option–Command–R` starts/stops. `Control–Option–Command–M` pauses/resumes your microphone track while meeting audio continues. Muting Zoom, Meet or Teams does **not** pause CallScribe's microphone.

Recording is available before models are ready. Audio remains saved if processing cannot run. Stop never automatically loads or compiles offline models: it returns an actionable message if they are not ready. To create a separate offline transcript, prepare the models, then choose **Retry Saved Sessions**. Explicit offline processing still finishes before another recording can begin.

The chosen language is saved in each session before capture starts. Retries use that saved language, not the menu's current setting. Archives created before version 0.2 default to English. The app transcribes in the selected language rather than translating to English. Choose the main language of the meeting; mixed-language accuracy is not guaranteed. Changing the menu language does not rewrite older transcripts.

## Live English captions

Choose the meeting language, then enable **Live English Captions** and start recording. **Settings → Live English captions → Translation** offers two engines:

- **Azure · streaming translation:** enter an Azure AI Speech / AI Services key and region. The key is stored in macOS Keychain. Call audio is continuously sent to Azure, with English text updated while someone is speaking. Your microphone is not sent for captions. Standard Speech Translation is about USD 2.50 per audio hour in Sweden Central as of 19 October 2026; actual Azure billing and credits may differ. A 30/60/120-minute limit controls usage, with 60 minutes as the default. The limit persists across caption toggles in the same recording. No OpenAI deployment or speech synthesis is needed.
- **On this Mac · experimental:** use **Prepare Caption Model** once to download multilingual Whisper small (~220 MB). Audio stays on the Mac. Growing audio windows produce revisable drafts; latency and translation quality depend on the Mac and audio context.

The compact caption panel floats above meeting windows. **Drag its header** to move it. **A− / A+** change text size; the appearance menu controls text size, width, height, background and optional original text. Preferences and position are remembered. **Scroll up** to freeze the reading position while translation continues, then choose **Return to live**. Text remains available after Stop. **Show Caption Panel** in the menu reopens it; **Open Last English Captions** opens the saved English file. Hiding the panel does not stop translation; disabling Live English Captions does.

Final translations are saved incrementally as `english-captions.jsonl`, with readable `english-captions.md` and `english-captions.txt` files at Stop. The English text covers call audio, not your independent microphone track, and is labelled as live machine translation. Drafts may change, contain errors or be incomplete at the recording boundary. Saved original-language transcripts remain separate. An entire-screen share may include the panel.

Caption work runs independently of durable capture. Audio buffers retain thirty seconds; overruns, disconnected cloud captions and missing call audio are surfaced. Azure connection failures require toggling captions to reconnect. English/German code-switching is not automatically detected; select the main meeting language. Offline translation still needs context and cannot guarantee simultaneous word-for-word interpretation.

See [the full review and measured checks](docs/LIVE_CAPTION_REVIEW.md).

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
- With captions off, speech inference runs only after Stop. Live captions use either Azure streaming or their own local small model during capture, independently of the recorder. Models can remain loaded while the app is open; model memory is materially larger than the small menu UI. Final transcript processing reads chunks and uses a disk-backed remote timeline instead of holding an entire call's PCM in RAM.
- Saved-transcript inference is local after model preparation. English, Turkish and German are supported with manual selection. Optional Azure live translation is explicitly configured in Settings. No analytics, automatic updates, or app account system.

## Build and install

Requires Xcode 16 or later / Swift 6 and an Apple Silicon Mac. Xcode 26 was used for the initial build.

```sh
swift test
./scripts/build-app.sh
./scripts/install.sh
```

The script creates an ARM64 `.app` with a stable bundle identifier, permissions and sandbox entitlements. It signs ad hoc by default. Set `CALLSCRIBE_SIGN_IDENTITY` to your Apple signing identity to sign differently. Ad-hoc signing is suitable for local builds; it is not Developer ID notarization. A downloaded copy on another Mac may require local rebuilding or normal macOS approval.

`./scripts/install.sh` installs into `/Applications` and opens the app. It refuses to interrupt an active recording, verifies the new bundle before replacing the installation, and preserves the old bundle under `~/Library/Application Support/CallScribe/App Backups.noindex/` with an `.app.backup` suffix. Build output and previous builds live under `dist/Build.noindex/`, outside Spotlight indexing. `./script/build_and_run.sh` builds, installs and opens this same canonical application; it does not launch another copy from the repository.

Install separately on the MacBook Pro. It needs macOS 14.2+, its own model cache, and its own permission grants. Transcripts and settings do not synchronize automatically. Clipboard synchronization, if enabled in macOS, follows your system settings.

## Implementation

Swift/AppKit + SwiftUI, Core Audio process taps, AVAudioEngine and local files. Three pinned Swift packages: Microsoft Speech SDK 1.52.0 for optional Azure streaming translation, FluidAudio 0.15.6 for English Parakeet Unified recognition and Community-1 speaker clustering, and WhisperKit 1.1.0 for multilingual Whisper large-v3 turbo (quantized `openai_whisper-large-v3-v20240930_turbo_632MB`) and optional Whisper small captions. The English/speaker download is approximately 640 MB; Turkish and German share approximately 650 MB of additional model/tokenizer files, plus compilation/cache space. Captions add about 220 MB. WhisperKit's CLI dependency resolves Swift Argument Parser but the app does not link its CLI/server targets. No Python runtime, web server or Electron. Only one final-transcript speech-model selection is retained at a time, alongside the optional caption model; switching language can take time to load it.

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
