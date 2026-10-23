import AVFoundation
import SwiftUI
import CallScribeCore

/// The launch and reopen surface. Recording never depends on finding a status item.
struct RecordingView: View {
    @ObservedObject private var controller: AppController
    @ObservedObject private var settings: AppSettings
    let showSettings: () -> Void
    let showCaptions: () -> Void

    init(controller: AppController, showSettings: @escaping () -> Void, showCaptions: @escaping () -> Void) {
        self.controller = controller
        _settings = ObservedObject(wrappedValue: controller.settings)
        self.showSettings = showSettings
        self.showCaptions = showCaptions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: controller.state.isCapturing ? "record.circle.fill" : "waveform")
                    .font(.system(size: 30)).foregroundStyle(controller.state.isCapturing ? Color.red : Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(controller.state.isCapturing ? "Recording your call" : "CallScribe").font(.title2.bold())
                    Text(controller.state.title).foregroundStyle(.secondary)
                }
                Spacer()
                if controller.state == .starting || controller.state == .recovering {
                    ProgressView().controlSize(.small)
                }
            }

            Picker("Meeting language", selection: Binding(
                get: { settings.language }, set: { controller.selectLanguage($0) })) {
                ForEach(TranscriptionLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }.disabled(!controller.canChangeLanguage)

            VStack(alignment: .leading, spacing: 7) {
                Toggle("Live English captions", isOn: Binding(
                    get: { settings.liveCaptionsEnabled }, set: { _ in controller.toggleLiveCaptions() }))
                    .disabled(!controller.canToggleCaptions)
                if settings.liveCaptionsEnabled {
                    Text(settings.captionProvider == .azure
                         ? "Azure streaming · \(settings.language.title) → English · \(Int(settings.captionLimitMinutes)) min limit"
                         : "On this Mac · experimental translation")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if let warning = controller.captureWarning {
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            } else if case .error(let message) = controller.state {
                Text(message).font(.callout).foregroundStyle(.orange)
            } else {
                Text(controller.state.isCapturing ? "\(controller.liveCaption.status)" : "Start when your call begins. Captions appear in a movable panel, and audio is saved locally.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Button(action: controller.toggleRecording) {
                Label(controller.state.isCapturing ? "Stop Recording" : "Start Recording",
                      systemImage: controller.state.isCapturing ? "stop.fill" : "record.circle")
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(!controller.state.canStartOrStop || controller.preparingCaptions)
            .accessibilityIdentifier("callscribe.recording.toggle")

            HStack {
                Button("Settings…", action: showSettings)
                Button("Show Captions", action: showCaptions)
                Spacer()
                Text("⌃⌥⌘R").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
