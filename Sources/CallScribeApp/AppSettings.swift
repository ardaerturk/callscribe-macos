import Foundation
import ServiceManagement
import CallScribeCore

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

enum CaptionProvider: String, CaseIterable, Identifiable, Sendable {
    case offline, azure
    var id: String { rawValue }
    var title: String { self == .azure ? "Azure · streaming translation" : "On this Mac · experimental" }
}

struct CaptionServiceSettings: Sendable {
    var provider: CaptionProvider = .offline
    var region: String = "swedencentral"
    var limitMinutes: Double = 60
}

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let selectedMicrophoneID = "selectedMicrophoneID"
        static let transcriptFormatting = "transcriptFormatting"
        static let keepRecordingPolicy = "keepRecordingPolicy"
        static let didShowFirstRun = "didShowFirstRun"
        static let language = "transcriptionLanguage"
        static let liveCaptions = "liveEnglishCaptions"
    }

    private let defaults: UserDefaults

    @Published var captionProvider: CaptionProvider { didSet { defaults.set(captionProvider.rawValue, forKey: "captionProvider") } }
    @Published var azureRegion: String { didSet { defaults.set(azureRegion, forKey: "azureSpeechRegion") } }
    @Published var captionLimitMinutes: Double { didSet { defaults.set(captionLimitMinutes, forKey: "captionLimitMinutes") } }
    @Published var captionFontSize: Double { didSet { defaults.set(captionFontSize, forKey: "captionFontSize") } }
    @Published var captionWidth: Double { didSet { defaults.set(captionWidth, forKey: "captionWidth") } }
    @Published var captionHeight: Double { didSet { defaults.set(captionHeight, forKey: "captionHeight") } }
    @Published var captionOpacity: Double { didSet { defaults.set(captionOpacity, forKey: "captionOpacity") } }
    @Published var captionOriginal: Bool { didSet { defaults.set(captionOriginal, forKey: "captionOriginal") } }

    var captionServiceSettings: CaptionServiceSettings {
        .init(provider: captionProvider, region: azureRegion, limitMinutes: captionLimitMinutes)
    }

    @Published var liveCaptionsEnabled: Bool {
        didSet { defaults.set(liveCaptionsEnabled, forKey: Key.liveCaptions) }
    }

    @Published var language: TranscriptionLanguage {
        didSet { defaults.set(language.rawValue, forKey: Key.language) }
    }

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
        captionProvider = CaptionProvider(rawValue: defaults.string(forKey: "captionProvider") ?? "") ?? .offline
        azureRegion = defaults.string(forKey: "azureSpeechRegion") ?? "swedencentral"
        captionLimitMinutes = defaults.object(forKey: "captionLimitMinutes") as? Double ?? 60
        captionFontSize = min(40, max(16, defaults.object(forKey: "captionFontSize") as? Double ?? 23))
        captionWidth = min(1400, max(520, defaults.object(forKey: "captionWidth") as? Double ?? 980))
        captionHeight = min(400, max(150, defaults.object(forKey: "captionHeight") as? Double ?? 210))
        captionOpacity = min(1, max(0.45, defaults.object(forKey: "captionOpacity") as? Double ?? 0.9))
        captionOriginal = defaults.bool(forKey: "captionOriginal")
        liveCaptionsEnabled = defaults.bool(forKey: Key.liveCaptions)
        language = TranscriptionLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .english
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
