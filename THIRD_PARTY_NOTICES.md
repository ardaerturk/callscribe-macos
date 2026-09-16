# Third-party components

- **WhisperKit / Argmax OSS 1.1.0**, Argmax, Inc.: MIT License. https://github.com/argmaxinc/WhisperKit/tree/v1.1.0 . Its ArgmaxCore module includes Apache-2.0-derived Hugging Face tokenizer code; bundled release notices include upstream LICENSE and NOTICES. Swift Argument Parser is a resolved CLI-only dependency, not linked into CallScribe.
- **Whisper large-v3 turbo**, OpenAI, converted/quantized to Core ML by Argmax: https://huggingface.co/argmaxinc/whisperkit-coreml and https://huggingface.co/openai/whisper-large-v3-turbo . Whisper model weights and tokenizer assets are MIT-licensed. Turkish and German share this download.

- **FluidAudio 0.15.6**, Fluid Inference: Apache License 2.0. Source and license: https://github.com/FluidInference/FluidAudio/tree/v0.15.6
- FluidAudio includes FastCluster native code, its platform support wrapper, and the **NemoTextProcessing** static library from `text-processing-rs` v0.3.0. Consult their upstream license notices when redistributing a release. The binary artifact is pinned by SHA-256 in FluidAudio's package manifest.
- **Parakeet Unified English 0.6B**, NVIDIA, converted to Core ML by Fluid Inference: model card and attribution at https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml . Model licensing is separate from the Swift library (CC-BY-4.0 in the model card).
- **Community-1 offline speaker diarization**, pyannote / Fluid Inference Core ML conversion: https://huggingface.co/FluidInference/speaker-diarization-coreml and https://huggingface.co/pyannote/speaker-diarization-community-1 . Consult the model cards for CC-BY-4.0 attribution and upstream component notices.

Models are downloaded separately into the user's local cache and are not committed to this repository. CallScribe does not use the package's speech-generation features or their resources. Apple system frameworks remain subject to Apple's terms.

This initial repository is for personal evaluation. Preserve the upstream notices and verify the model cards and transitive native notices before wider distribution.
