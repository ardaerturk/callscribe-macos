import AVFoundation
import SwiftUI
import CallScribeCore

struct SettingsView: View {
    @ObservedObject private var controller: AppController
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var devices: AudioDeviceCatalog

    @State private var launchAtLogin = false
    @State private var loginError: String?

    init(controller: AppController) {
        self.controller = controller
        _settings = ObservedObject(wrappedValue: controller.settings)
        _devices = ObservedObject(wrappedValue: controller.audioDevices)
    }

    var body: some View {
        Form {
            Section("Status") {
                Text(controller.state.title).font(.headline)
                Text(controller.captureWarning ?? controller.statusDetail)
                    .font(.caption).foregroundStyle(.secondary)
                if controller.pendingCount > 0 {
                    Button("Retry \(controller.pendingCount) saved sessions") { controller.retryPending() }
                        .disabled(controller.state.isCapturing || controller.modelReadiness != .ready)
                }
            }
            Section("Offline readiness") {
                HStack {
                    Label(modelTitle, systemImage: modelSymbol)
                    Spacer()
                    Button(modelButtonTitle) { controller.prepareModels() }
                        .disabled(isPreparingModels || controller.modelReadiness == .ready || !controller.state.canStartOrStop || controller.state.isCapturing)
                }
                if case .downloading(let progress) = controller.modelReadiness,
                   let progress {
                    ProgressView(value: progress)
                }
                Text("Models are downloaded once, then meeting audio and transcripts stay on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Microphone") {
                Picker("Input", selection: $settings.selectedMicrophoneID) {
                    Text("Automatic (prefer wired / built-in)").tag(String?.none)
                    ForEach(devices.microphones) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                Button("Refresh devices") { devices.refresh() }
                Text(microphonePermissionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transcript") {
                Picker("Language", selection: Binding(get: { settings.language }, set: { controller.selectLanguage($0) })) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }.disabled(!controller.canChangeLanguage)
                Picker("Format", selection: $settings.transcriptFormatting) {
                    ForEach(TranscriptFormatting.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                Text("Audio is kept locally so you can recover or retry a transcript. Manage saved sessions in Finder.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("App") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: updateLaunchAtLogin
                ))
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button("Open sessions folder") { controller.openSessionsDirectory() }
            }

            Section("Recording notice") {
                Text("CallScribe follows normal macOS recording permissions and status indicators. Use it only when recording is permitted and everyone who must be informed has been informed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Shortcuts: ⌥⌃⌘R starts or stops. ⌥⌃⌘M pauses or resumes your microphone track.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 600)
        .onAppear {
            launchAtLogin = settings.launchAtLogin
            devices.refresh()
        }
    }

    private var isPreparingModels: Bool {
        if case .downloading = controller.modelReadiness { return true }
        return false
    }

    private var modelTitle: String {
        switch controller.modelReadiness {
        case .failed(let message): return "Offline models need attention: \(message)"
        default: return controller.modelReadiness.title
        }
    }

    private var modelSymbol: String {
        switch controller.modelReadiness {
        case .ready: return "checkmark.circle.fill"
        case .downloading: return "arrow.down.circle"
        case .failed: return "exclamationmark.triangle"
        case .notPrepared: return "externaldrive.badge.plus"
        }
    }

    private var modelButtonTitle: String {
        switch controller.modelReadiness {
        case .ready: return "Ready"
        case .downloading: return "Preparing..."
        case .failed: return "Retry"
        case .notPrepared: return "Prepare Models"
        }
    }

    private var microphonePermissionText: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "Microphone access is enabled."
        case .notDetermined: return "macOS will ask for microphone access when recording starts."
        case .denied, .restricted: return "Microphone access is disabled in System Settings > Privacy & Security."
        @unknown default: return "Microphone permission status is unavailable."
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            try settings.setLaunchAtLogin(enabled)
            launchAtLogin = settings.launchAtLogin
            loginError = nil
        } catch {
            launchAtLogin = settings.launchAtLogin
            loginError = error.localizedDescription
        }
    }
}
