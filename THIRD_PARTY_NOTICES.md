# Third-party components

- **FluidAudio 0.15.6**, Fluid Inference: Apache License 2.0. Source and license: https://github.com/FluidInference/FluidAudio/tree/v0.15.6
- FluidAudio includes FastCluster native code, its platform support wrapper, and the **NemoTextProcessing** static library from `text-processing-rs` v0.3.0. Consult their upstream license notices when redistributing a release. The binary artifact is pinned by SHA-256 in FluidAudio's package manifest.
- **Parakeet Unified English 0.6B**, NVIDIA, converted to Core ML by Fluid Inference: model card and attribution at https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml . Model licensing is separate from the Swift library (CC-BY-4.0 in the model card).
- **Community-1 offline speaker diarization**, pyannote / Fluid Inference Core ML conversion: https://huggingface.co/FluidInference/speaker-diarization-coreml and https://huggingface.co/pyannote/speaker-diarization-community-1 . Consult the model cards for CC-BY-4.0 attribution and upstream component notices.

Models are downloaded separately into the user's local cache and are not committed to this repository. CallScribe does not use the package's speech-generation features or their resources. Apple system frameworks remain subject to Apple's terms.

This initial repository is for personal evaluation. Preserve the upstream notices and verify the model cards and transitive native notices before wider distribution.
