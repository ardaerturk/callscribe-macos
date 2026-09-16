import Foundation
import ServiceManagement

enum TranscriptFormatting: String, CaseIterable, Identifiable, Sendable {
    case readable
    case timestamped
    case plainText

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readable:
            return "Speakers and paragraphs"
        case .timestamped:
            return "Speakers with timestamps"
        case .plainText:
            return "Plain text"
        }
    }
}

enum KeepRecordingPolicy: String, CaseIterable, Identifiable, Sendable {
    case always

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always:
            return "Keep audio archive"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let selectedMicrophoneID = "selectedMicrophoneID"
        static let transcriptFormatting = "transcriptFormatting"
        static let keepRecordingPolicy = "keepRecordingPolicy"
        static let didShowFirstRun = "didShowFirstRun"
    }

    private let defaults: UserDefaults

    @Published var selectedMicrophoneID: String? {
        didSet {
            if let selectedMicrophoneID, !selectedMicrophoneID.isEmpty {
                defaults.set(selectedMicrophoneID, forKey: Key.selectedMicrophoneID)
            } else {
                defaults.removeObject(forKey: Key.selectedMicrophoneID)
            }
        }
    }

    @Published var transcriptFormatting: TranscriptFormatting {
        didSet { defaults.set(transcriptFormatting.rawValue, forKey: Key.transcriptFormatting) }
    }

    @Published var keepRecordingPolicy: KeepRecordingPolicy {
        didSet { defaults.set(keepRecordingPolicy.rawValue, forKey: Key.keepRecordingPolicy) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedMicrophoneID = defaults.string(forKey: Key.selectedMicrophoneID)
        transcriptFormatting = TranscriptFormatting(
            rawValue: defaults.string(forKey: Key.transcriptFormatting) ?? ""
        ) ?? .readable
        keepRecordingPolicy = KeepRecordingPolicy(
            rawValue: defaults.string(forKey: Key.keepRecordingPolicy) ?? ""
        ) ?? .always
    }

    var shouldShowFirstRun: Bool {
        !defaults.bool(forKey: Key.didShowFirstRun)
    }

    func markFirstRunShown() {
        defaults.set(true, forKey: Key.didShowFirstRun)
    }

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
        objectWillChange.send()
    }
}
