# Data handling

CallScribe records only after you start it. It requests the normal macOS permissions, displays local recording status, and preserves OS privacy indicators.

Audio, transcripts, speaker labels and processing metadata are stored locally in the app container. There is no account, telemetry, cloud transcription or automatic upload. Choosing Prepare Models permits downloads from the model provider. The provider receives ordinary download connection metadata, but no meeting audio. Normal launches and inference enable FluidAudio's offline mode.

Turkish and German use locally downloaded Whisper models and tokenizer files. The normal model loader disables downloads and injects a local-only tokenizer parser; it does not fall back to a network request for missing files. Language selection is stored in app preferences and in each recording's manifest. Model downloads use Hugging Face and its delivery hosts.

Optional English captions use a separate local translation model. Caption audio windows and translated text are held in memory; no caption service receives audio and the live English text is not saved. The normal source audio archive still applies whenever recording is running. The subtitle panel is visible on your display and may be captured in entire-screen sharing or screenshots. The caption toggle is remembered, but enabling it alone never starts capture. Normal caption startup never permits downloads; Prepare Caption Model is the explicit provisioning action.

Models and session audio consume disk space. Recordings are retained for recovery and reprocessing until you delete them. The app does not add its own encryption; macOS filesystem protections and FileVault apply. Backups may retain copies.

Completed transcripts are copied to the system clipboard. Other apps, clipboard managers, and Universal Clipboard can access or retain that content according to their own settings. Pasting into another app subjects it to that app's data handling.

System audio may include unrelated apps and browser tabs. The microphone remains independent of a meeting app's mute state. Pause CallScribe's microphone when needed.
