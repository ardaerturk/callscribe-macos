# Optional Azure live captions (0.4)

Choosing Azure in Settings sends the call/system-audio track to the configured Microsoft Azure Speech resource for live English translation. It does not send the microphone track for captions. It uses one speech-translation stream and no speech synthesis. The Speech key is stored in macOS Keychain, not preferences or session files. Local mode remains available; the app never switches to cloud automatically.

Azure use is metered. The default 60-minute per-recording limit stops cloud captions; audio recording continues locally. Turning captions off closes the connection. Hiding the panel only hides it. Final English translations and source text are saved locally in the session as `english-captions.jsonl`, `english-captions.md` and `english-captions.txt`. Microsoft service terms and your Azure resource configuration govern cloud processing.

The local-processing description below applies to the audio archive, offline captions and final offline transcription. Azure captions are the explicit exception.

# Data handling

CallScribe records only after you start it. It requests the normal macOS permissions, displays local recording status, and preserves OS privacy indicators.

Audio, transcripts, speaker labels and processing metadata are stored locally in the app container. There is no app account or telemetry. Cloud audio transmission occurs only when Azure captions are explicitly configured and enabled. Choosing Prepare Models permits downloads from the model provider. The provider receives ordinary download connection metadata, but no meeting audio. Normal launches and inference enable FluidAudio's offline mode.

Turkish and German use locally downloaded Whisper models and tokenizer files. The normal model loader disables downloads and injects a local-only tokenizer parser; it does not fall back to a network request for missing files. Language selection is stored in app preferences and in each recording's manifest. Model downloads use Hugging Face and its delivery hosts.

Offline English captions use a separate local translation model. Azure captions use the cloud service described above. English caption text is saved locally alongside the audio archive. The subtitle panel may appear in entire-screen sharing or screenshots. The caption toggle is remembered, but enabling it alone never starts capture. Offline caption startup never permits downloads; Prepare Caption Model is the explicit provisioning action.

Models and session audio consume disk space. Recordings are retained for recovery and reprocessing until you delete them. The app does not add its own encryption; macOS filesystem protections and FileVault apply. Backups may retain copies.

Completed transcripts are copied to the system clipboard. Other apps, clipboard managers, and Universal Clipboard can access or retain that content according to their own settings. Pasting into another app subjects it to that app's data handling.

System audio may include unrelated apps and browser tabs. The microphone remains independent of a meeting app's mute state. Pause CallScribe's microphone when needed.
