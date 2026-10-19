# Live caption review — 19 October 2026

## What failed

The installed 0.3.1 app ran on an Apple M1 MacBook Pro with 8 GB RAM. Its live caption path was experimental batch translation, not streaming speech translation.

1. **Discarded audio and results.** The worker sampled only the latest eight seconds, slept three seconds *after* inference, processed call and microphone sequentially, and discarded an entire update if inference exceeded twelve seconds. A slow run could therefore lose both its own translation and intervening speech.
2. **Artificial startup and silence delays.** It required six seconds of audio, then checked only the last two seconds against a fixed energy threshold. Speech followed by a pause could be ignored. Silence or an unchanged input frame also cleared text.
3. **No usable reading history.** Each update replaced the previous caption, retaining only the last 420 characters. The overlay truncated the beginning of text, ignored all mouse events, recreated its hosting view on every update, and repositioned itself. Scrolling, selecting, moving and customizing it were impossible.
4. **No English caption archive.** Only original-language offline transcripts were saved. A missed live translation could not be reviewed later.
5. **German final transcription was not provisioned.** The Mac had Whisper small for captions but not the separate multilingual Turbo model used for saved German transcripts. Recording was allowed, but subsequent transcription failed before a processing-state file was created.
6. **Unnecessary competing inference.** Processing a second microphone stream used the meeting language even when the user spoke English. Loading the final-transcript models alongside caption models increased memory pressure.

## Evidence from the saved session

The reviewed session ran for 35 minutes, 12 seconds with German selected. Both audio tracks are saved, totaling 282 chunks. The manifest records no capture restart or failure. System-audio gap insertion totals **0.291 seconds**, all at startup; microphone gap insertion totals **0.336 seconds**. Recordings, transcripts and identifying session metadata remain local and are not included in this repository.

Of 986 inspected two-second call-audio blocks within the stored chunks, 943 passed the *old* RMS gate. These energy measurements are not speech recognition or accuracy scores, but they argue against quiet input or capture gaps accounting for 80–90% missing live captions. The old caption output was not archived, so its exact omissions and translation accuracy cannot be reconstructed directly.

An earlier English session had a transcript; neither the short German session nor the 35-minute German session had a final transcript at the start of this review.

## Implemented approach

**Azure Speech Translation** is the cloud option. The official Microsoft Speech SDK receives continuous 16 kHz PCM from the existing system-audio capture, with one English text target. `Recognizing` events revise an in-progress caption; `Recognized` events finalize it. There is no per-sentence LLM request, speech synthesis, or cloud microphone stream. The existing Azure AI Services resource in Sweden Central authenticates successfully.

Each PCM frame is submitted once. Buffer overruns and route discontinuities are exposed as gaps. Cloud errors remain visible and instruct the user to reconnect; there is no unannounced provider switch. The cloud budget survives toggling captions within one recording and resets for the next recording. The default limit is 60 minutes, configurable to 30/60/120 minutes. It stops cloud captions, not durable audio capture.

The offline option remains available. It retains thirty seconds of PCM, consumes audio in chronological order, revises growing windows, emits decoder drafts, removes the fixed post-inference three-second wait, and reports overruns. Silence does not erase history; slow translations are not discarded simply for being late. It remains an approximate Whisper streaming adaptation, with less reliable latency and phrase boundaries than Azure.

The panel remains approximately 980 × 210 points by default. A+/A− and appearance controls adjust 16–40 point text, width, height, background opacity and original-language text. Drag the header to move it. Position and preferences persist. Scrolling up freezes the reading snapshot while recognition continues; Return to live reveals current captions. Text can be selected. The panel stays available after Stop and can be reopened from the menu. Open Last English Captions opens the latest saved caption file or recovered English transcript.

Final English captions are flushed to `english-captions.jsonl` during recording. At Stop, `english-captions.md` includes timestamps, original text when available, and explicit draft labels for unfinished text. These are separate from `transcript.*` and the audio archive.

## Recovered recording

The 35:12 call was recovered using Azure fast transcription and Translator into its local `Recovery-Azure` folder. It contains **351 nonempty English passages**, approximately **5,085 source words**, with the final phrase ending at **35:11.21**. Original chunks were preserved. This recovery covers the call track; the independent microphone track remains in the archive. It is machine output, not a verified verbatim transcript.

## Cost and alternatives

Microsoft's Retail Prices API returned **USD 2.50 / audio hour** for `Azure Speech / S1 Speech Translation` in `swedencentral` on 19 October 2026. That is approximately $0.042/minute. Standard translation includes up to two target text languages; this app requests one. Subscription agreements, taxes, exchange rates and credit eligibility determine the actual bill; authenticated access does not verify credit coverage.

| Option | Fit for this app |
| --- | --- |
| Azure Speech Translation | Chosen: continuous native SDK, provisional/final translations, one metered audio stream, existing resource, no separate LLM deployment. |
| Azure-hosted OpenAI transcription plus text translation | Possible alternative, but source transcription and translation require separate orchestration and deployments. Realtime transcription deltas alone are not English translations of German. No specific Azure OpenAI deployment was provisioned or billed. |
| WhisperStreaming | Established local-agreement approach; reports 3.3-second latency on its own benchmark, not this Mac. Shows why independent rolling-window snapshots are inadequate. |
| SimulStreaming | More advanced simultaneous translation; its recommended best-model hardware is a GPU with at least 10 GB VRAM. Not a straightforward fit for this 8 GB M1 Mac. |
| WhisperLiveKit | Rich streaming, buffering, draft/final and translation architecture, including Apple Silicon backends. A useful future local alternative, with a larger Python/server/model footprint than the native app. |

The chosen engine improves timing and coverage. German word order can require revising earlier English words. Literal zero-delay, permanently correct word-for-word translation is not a realistic guarantee.

## Validation and remaining limits

- Native Swift debug and optimized release builds, packaged app and strict code-signature verification succeeded. Version 0.4.0 is installed with Azure selected; the installed binary successfully read its Keychain credential and produced 14 provisional updates and 2 finals.
- Azure synthetic German replay: first English at **1.75 seconds**, 12 interim updates and 2 completed translations. This is first-result latency on one fixture, not a percentile or real-call guarantee.
- Actual saved meeting: a 15-second German excerpt produced **27 interim updates and 2 completed translations**. The clip boundary cuts speech; a final fragment was poor. This is a smoke test, not a scored accuracy benchmark.
- Programmatic checks exercise draft replacement, late-partial protection, repeated sentences, PCM overlap/stalls/gaps/clock resets, persisted settings, caption journaling, scroll-to-pause, frozen reading while captions arrive, and returning to live.
- The overlay was rendered and visually inspected. Native computer-use inspection repeatedly timed out for CallScribe. Fullscreen, multi-display dragging and real meeting interaction still need a hands-on check.
- `swift test` cannot run on this host: Command Line Tools are installed, but XCTest is absent. XCTest regression cases were added for a full Xcode host; the packaged diagnostic runner provides executable coverage here.
- Source language is manually selected. Mixed English/German passages can be less accurate; continuous language identification is not documented as supported by Microsoft's Swift SDK. Do not claim automatic code-switching support.
- A disconnected Azure stream requires toggling captions to reconnect. Already recorded audio remains local for recovery; cloud captions have no automatic retrospective backfill.
- German/Turkish model files were downloaded, but first Neural Engine compilation exceeded twenty minutes on this M1; offline model readiness is not claimed. Recording becomes available before the background readiness check completes.
- Final offline transcription still runs after Stop and prevents starting another recording while processing. This review prioritizes live understanding and caption retention.

## Sources

- [Microsoft: speech translation and intermediate results](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/how-to-translate-speech)
- [Microsoft: native Speech SDK installation](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/quickstarts/setup-platform?pivots=programming-language-swift)
- [Microsoft: Speech pricing](https://azure.microsoft.com/en-us/pricing/details/cognitive-services/speech-services/)
- [Microsoft: Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices)
- [Microsoft: language identification limitations](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/language-identification)
- [OpenAI: realtime transcription](https://developers.openai.com/api/docs/guides/realtime-transcription)
- [WhisperStreaming](https://github.com/ufal/whisper_streaming)
- [SimulStreaming](https://github.com/ufal/SimulStreaming)
- [WhisperLiveKit](https://github.com/QuentinFuxa/WhisperLiveKit)
