import AVFoundation
import Foundation
import CallScribeCore

struct MicrophoneChoice: Identifiable, Hashable {
    let id: String
    let name: String
}

@MainActor
final class AudioDeviceCatalog: ObservableObject {
    @Published private(set) var microphones: [MicrophoneChoice] = []

    init() {
        refresh()
        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        microphones = ((try? CaptureCoordinator.availableInputDevices()) ?? [])
            .map { MicrophoneChoice(id: $0.uid, name: $0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
