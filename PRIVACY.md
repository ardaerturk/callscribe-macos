# Data handling

CallScribe records only after you start it. It requests the normal macOS permissions, displays local recording status, and preserves OS privacy indicators.

Audio, transcripts, speaker labels and processing metadata are stored locally in the app container. There is no account, telemetry, cloud transcription or automatic upload. Choosing Prepare Models permits downloads from the model provider. The provider receives ordinary download connection metadata, but no meeting audio. Normal launches and inference enable FluidAudio's offline mode.

Models and session audio consume disk space. Recordings are retained for recovery and reprocessing until you delete them. The app does not add its own encryption; macOS filesystem protections and FileVault apply. Backups may retain copies.

Completed transcripts are copied to the system clipboard. Other apps, clipboard managers, and Universal Clipboard can access or retain that content according to their own settings. Pasting into another app subjects it to that app's data handling.

System audio may include unrelated apps and browser tabs. The microphone remains independent of a meeting app's mute state. Pause CallScribe's microphone when needed.
