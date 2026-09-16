# Validation record

Host: Apple M4 Mac mini, 24 GB RAM, macOS 26.0 (25A354), Xcode 26. Date: 2026-09-16.

## Completed

- `swift test`: 25 tests pass across capture, durable storage, transcript assembly and app lifecycle.
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

## Before relying on this for important meetings

Use a short permitted test call. Check that both sides appear; repeat with headphones and speakers; pause the recorder microphone; disconnect/reconnect the chosen input; verify the warning and archived event; then test recovery after an interrupted session. Run the same checks on the MacBook Pro. Keep a separate established recording method for important calls until those checks pass.

Speaker separation is an estimate. Matching text deduplication is not full acoustic echo cancellation. This initial build should not be described as production-validated or lossless.
