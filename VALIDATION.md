# Validation record

Host: Apple M4 Mac mini, 24 GB RAM, macOS 26.0 (25A354), Xcode 26. Date: 2026-09-16.

## Completed

- `swift test`: 53 tests pass across capture, durable storage, transcript assembly, captions and app lifecycle.
- Release build: ARM64 macOS app compiles.
- Packaged application: ad-hoc signature passes `codesign --verify --deep --strict`; macOS launches it.
- Native tests cover aligned two-track timestamps, device fallback, callback stall restart, sleep/wake restart, mic pause, chunk finalization, interruption recovery, corrupt-chunk preservation and exposed disk-write failures.
- Transcript tests cover both sources, stable anonymous labels, speaker-playback deduplication, genuine overlap preservation, saved artifacts and retryable failure for missing chunks.
- App lifecycle tests cover rapid repeated start/stop, one clipboard copy, recording before model preparation and retained sessions after transcription failure. These tests inject a permission response and clipboard writer and do not record or change the real clipboard.
- Final transcript processing reads recording chunks incrementally and passes a disk-backed CAF timeline to the diarizer. Capture callbacks do not run inference; optional captions use a separate worker during recording.
- First model provisioning completed on this Mac. The active speech and speaker model directories total approximately 617 MiB (additional compilation caches may use more space).
- Real local inference passed using `scripts/verify-models.sh`, with model downloads disabled. Three locally generated macOS voices produced **You**, **Speaker 1**, and **Speaker 2** with intelligible text. The test exposed a delayed word-end timing error at a pause; the corrected speaker assignment passed both a regression test and a repeated real-model run. Synthetic voices do not establish real-call accuracy.
- The verification script never opens microphone or system-audio inputs. `--prepare` optionally provisions models first; normal verification loads cached models in offline mode. This is an application-level offline-mode check, not a packet-capture network audit.

## Runtime checks outstanding

- Earlier desktop visual inspection was blocked because the Mac was locked. The 0.3.0 caption view has since been rendered offscreen and inspected; native menu, fullscreen, screen-sharing and multi-display behavior still need interactive validation. Process launch does not substitute for those checks.
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

## 0.3.0 optional offline English captions

- Adds a saved, off-by-default menu/Settings toggle, a bottom-of-screen click-through subtitle panel, and explicit one-time caption model preparation. Enabling captions alone does not start recording. Both captured tracks feed the caption worker; live labels are Call and You, not separate remote identities. Original-language saved transcripts are unchanged; English caption text is ephemeral.
- Reuses WhisperKit with multilingual Whisper small, not Turbo (Turbo is not trained for translation). The additional model/tokenizer download is about 220 MB. Download and first Neural Engine compilation completed on this Mac. Normal live loading explicitly disables downloads; there is no paid API, subscription or server translation.
- All 50 automated tests pass, including bounded buffers, overlap/gap handling, disabled-buffer behavior, mic pause/stop, translation-versus-transcription options, local-only model loading, cancellation of in-flight caption results, stale UI callback rejection, and secondary-display frame geometry. These do not establish hardware or translation accuracy.
- Real model smoke checks translated both Turkish and German synthetic tracks to English with downloads disabled. Full-fixture checks took approximately 2.4 and 1.9 seconds respectively on this M4; they test nonempty output, not accuracy. Original Turkish and German transcription/diarization regressions also passed after the caption changes.
- Progressive synthetic audio was fed through the actual rolling worker in elapsed time, without opening microphone or system-audio inputs. An initial German three-second fragment produced an unrelated sentence about weapons. The worker now waits for at least six seconds of context after start/track reset, with regression assertions rejecting shorter buffers. This mitigates that observed short-fragment issue, but is not a general hallucination fix. Other outputs mistranslated design files as reviews and next week as future; important meaning can be wrong.
- Repeated Turkish and German fixture checks passed after that change, with the first English update at approximately 7.2 seconds and further updates as speech continued. The original short German fixture produced only one update after the warm-up and therefore failed the diagnostic's two-update threshold; the diagnostic now repeats each fixture with a one-second pause, preserving the two-update requirement. Both checks ran for approximately 25 seconds, including trailing silence. The unrelated German opening was absent in the repeat, but lexical/meaning errors remained.
- The app's actual subtitle SwiftUI view was rendered offscreen and visually inspected as a compact 980-by-125 image with two readable source rows. This validates sample layout, not overlay placement above a real meeting, Spaces, display removal, or screen-sharing behavior.
- No live call, M1 performance/battery measurement, or combined sustained capture-plus-caption load test was performed. Capture persists audio before copying it into bounded caption buffers; inference is separate and keeps no unbounded work backlog. These are design safeguards, not proof that captions cannot affect call performance through shared CPU/memory resources.

## 0.3.1 microphone restart crash repair

- All three local crash reports at 18:52–18:53 on 2026-09-16 have the same fault: `EXC_BAD_ACCESS` in `objc_msgSend`, called by an asynchronous `AVAudioIOUnit::IOUnitPropertyListener` block. The last session manifest records microphone configuration/restart events approximately once per second before termination. This strongly implicates engine teardown during a self-triggered configuration loop, not caption inference.
- Microphone capture now retains and reuses one engine/input node for the process lifetime, guarded by an exclusive lease. Stopping still stops the engine and removes its tap; retaining the objects does not keep recording. This avoids disposing the audio-unit objects while framework property callbacks may still be queued.
- It no longer sets CurrentDevice when already selected, and ignores configuration notifications when the engine is running with the same device/sample rate/channel count. Actual changes, stopped engines and unreadable routes still trigger recovery; the watchdog remains active. Engine startup failure stops the engine before tap cleanup.
- Three new tests cover repeated unchanged-route notifications, genuine/stopped/unknown-route changes, and exclusive reusable ownership across 100 restart cycles. The 53-test suite passes. These are deterministic decision/lifecycle tests, not a hardware replay of the AVFoundation crash. A fresh user recording and headset-route test are required to confirm the repair on the affected setup.
- Version 0.3.1 was built, signature-verified, installed and launched. Before launch, the last interrupted session was copied into an ignored local recovery backup. Startup recovered both saved WAV chunks (132,586 microphone frames and 135,568 system frames at 16 kHz) with no recovery warnings. The earlier two crashed sessions already had finalized audio chunks. This recovers audio present on disk, not audio after the crash or the gaps logged before it.

## Before relying on this for important meetings

Use a short permitted test call. Check that both sides appear; repeat with headphones and speakers; pause the recorder microphone; disconnect/reconnect the chosen input; verify the warning and archived event; then test recovery after an interrupted session. Run the same checks on the MacBook Pro. Keep a separate established recording method for important calls until those checks pass.

Speaker separation is an estimate. Matching text deduplication is not full acoustic echo cancellation. This initial build should not be described as production-validated or lossless.
