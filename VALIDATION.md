# Validation record

Host: Apple M4 Mac mini, 24 GB RAM, macOS 26.0 (25A354), Xcode 26. Date: 2026-09-16.

## Completed

- `swift test`: 23 tests pass across capture, durable storage, transcript assembly and app lifecycle.
- Release build: ARM64 macOS app compiles.
- Packaged application: ad-hoc signature passes `codesign --verify --deep --strict`; macOS launches it.
- Native tests cover aligned two-track timestamps, device fallback, callback stall restart, sleep/wake restart, mic pause, chunk finalization, interruption recovery, corrupt-chunk preservation and exposed disk-write failures.
- Transcript tests cover both sources, stable anonymous labels, speaker-playback deduplication, genuine overlap preservation, saved artifacts and retryable failure for missing chunks.
- App lifecycle tests cover rapid repeated start/stop, one clipboard copy, recording before model preparation and retained sessions after transcription failure. These tests inject a permission response and clipboard writer and do not record or change the real clipboard.
- Model implementation reads recording chunks incrementally and passes a disk-backed CAF timeline to the diarizer. Capture does not run inference.

## Runtime checks in progress / outstanding

- First model provisioning is in progress. Download speed from the provider is low. Model preparation and real offline inference must complete before the app is ready to produce transcripts on this Mac.
- `scripts/verify-models.sh` runs real models on speech generated locally by macOS. It never opens microphone or system-audio inputs. The inference step sets FluidAudio offline mode; `--prepare` optionally provisions first.
- Visual inspection is blocked because the Mac is locked. The process-launch check does not substitute for a visual check.
- No live Zoom, Meet or Teams call has been recorded in this build.
- No physical headset disconnect, Bluetooth profile change, forced app termination during live capture, long call, speakerphone echo trial, or M1 runtime measurement has been performed. Their recovery logic has deterministic tests; hardware behavior still requires validation.

## Before relying on this for important meetings

Use a short permitted test call. Check that both sides appear; repeat with headphones and speakers; pause the recorder microphone; disconnect/reconnect the chosen input; verify the warning and archived event; then test recovery after an interrupted session. Run the same checks on the MacBook Pro. Keep a separate established recording method for important calls until those checks pass.

Speaker separation is an estimate. Matching text deduplication is not full acoustic echo cancellation. This initial build should not be described as production-validated or lossless.
