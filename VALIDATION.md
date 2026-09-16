# Validation record

Host: Apple M4 Mac mini, 24 GB RAM, macOS 26.0 (25A354), Xcode 26. Date: 2026-09-16.

## Completed

- `swift test`: 40 tests pass across capture, durable storage, transcript assembly and app lifecycle.
- Release build: ARM64 macOS app compiles.
- Packaged application: ad-hoc signature passes `codesign --verify --deep --strict`; macOS launches it.
- Native tests cover aligned two-track timestamps, device fallback, callback stall restart, sleep/wake restart, mic pause, chunk finalization, interruption recovery, corrupt-chunk preservation and exposed disk-write failures.
- Transcript tests cover both sources, stable anonymous labels, speaker-playback deduplication, genuine overlap preservation, saved artifacts and retryable failure for missing chunks.
- App lifecycle tests cover rapid repeated start/stop, one clipboard copy, recording before model preparation and retained sessions after transcription failure. These tests inject a permission response and clipboard writer and do not record or change the real clipboard.
- Model implementation reads recording chunks incrementally and passes a disk-backed CAF timeline to the diarizer. Capture does not run inference.
- First model provisioning completed on this Mac. The active speech and speaker model directories total approximately 617 MiB (additional compilation caches may use more space).
- Real local inference passed using `scripts/verify-models.sh`, with model downloads disabled. Three locally generated macOS voices produced **You**, **Speaker 1**, and **Speaker 2** with intelligible text. The test exposed a delayed word-end timing error at a pause; the corrected speaker assignment passed both a regression test and a repeated real-model run. Synthetic voices do not establish real-call accuracy.
- The verification script never opens microphone or system-audio inputs. `--prepare` optionally provisions models first; normal verification loads cached models in offline mode. This is an application-level offline-mode check, not a packet-capture network audit.

## Runtime checks outstanding

- Visual inspection is blocked because the Mac is locked. The process-launch check does not substitute for a visual check.
- No live Zoom, Meet or Teams call has been recorded in this build.
- No physical headset disconnect, Bluetooth profile change, forced app termination during live capture, long call, speakerphone echo trial, or M1 runtime measurement has been performed. Their recovery logic has deterministic tests; hardware behavior still requires validation.

## 0.1.1 microphone-selection repair

User test-session metadata exposed selection of a transient `CADefaultDeviceAggregate` as the non-Bluetooth alternative to AirPods. A route change then caused fallback and a 1.16-second microphone gap. An earlier test also contained repeated restarts and an AVAudioEngine format failure; this repair does not establish that every Bluetooth restart issue is resolved.

The device catalog now excludes hidden/internal inputs, restricts automatic Bluetooth alternatives to recognized physical transports, and tolerates individual devices disappearing during enumeration. Explicit public aggregate devices remain supported. The coordinator preserves the requested input separately from the resolved input, so Automatic is re-evaluated after route changes and explicit selections are retried after temporary fallback. Seven regression tests cover these cases. Existing saved recordings are not rewritten. A fresh real AirPods recording and disconnect/reconnect test are still required after installation.

A metadata-only check of the actual Mac's Core Audio catalog listed the AirPods and resolved Automatic to the AirPods using the repaired code. It did not open an audio input or start a recording.

## 0.2.0 manual Turkish and German selection

- Right-click language submenu and Settings support English, Turkish and German. Changes are blocked during capture, processing and model preparation.
- Sessions persist their chosen language before capture starts. Interrupted-session recovery preserves it. Older manifests without the field still decode as English. A processor rejects a mismatched session language.
- Turkish/German use the same quantized Whisper large-v3 turbo model via WhisperKit 1.1.0. Explicit decoder options disable language detection and request transcription, not English translation. Speaker diarization remains separate.
- Missing/corrupt tokenizer tests exercise a strictly local parser. Model loading injects that tokenizer and disables model downloading, so missing files do not cause an implicit Hub fallback. Initial downloads resume cached partial files and retry transient network failures.
- English, Turkish and German generated-speech smoke checks passed with downloads disabled after setup. Turkish retained accented characters and the expected project/budget/design phrases; German retained umlauts and the expected project/report/design/results phrases. Both produced You and Speaker 1 from separate tracks. The English test continued to produce You plus two remote speaker labels. These are synthetic checks, not a real-meeting accuracy benchmark.
- Shared Whisper model/tokenizer cache is approximately 626 MiB on this Mac. Setup recovered from a timed-out download and completed Neural Engine compilation. The cached German verification (including local speech generation, loading and processing the short two-track fixture) took about 5 seconds on the M4 Mac mini; this does not predict long-call or M1 performance.
- UI automation is unavailable in this session (app-control timeout / browser authentication error); menu behavior is not visually verified. No new live audio was recorded by the agent.

## Before relying on this for important meetings

Use a short permitted test call. Check that both sides appear; repeat with headphones and speakers; pause the recorder microphone; disconnect/reconnect the chosen input; verify the warning and archived event; then test recovery after an interrupted session. Run the same checks on the MacBook Pro. Keep a separate established recording method for important calls until those checks pass.

Speaker separation is an estimate. Matching text deduplication is not full acoustic echo cancellation. This initial build should not be described as production-validated or lossless.
