import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import CallScribeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    private var recordingHotKey: GlobalHotKey?
    private var microphoneHotKey: GlobalHotKey?
    private var settingsWindow: NSWindow?
    private let captionOverlay = CaptionOverlay()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppDiagnostics.startIfRequested() { return }
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configureHotKeys()
        observeController()
        controller.bootstrap()

        if controller.settings.shouldShowFirstRun {
            controller.settings.markFirstRunShown()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showSettings()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The menu's explicit Quit action handles stopping. A system quit during
        // work leaves the archive recoverable, but must not silently discard it.
        if controller.state.isCapturing || controller.state == .starting {
            return .terminateCancel
        }
        return .terminateNow
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "CallScribe ready")
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "CallScribe - left-click to record, right-click for options"
        button.setAccessibilityLabel("CallScribe microphone")
    }

    private func configureHotKeys() {
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        recordingHotKey = GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_R),
            modifiers: modifiers,
            identifier: 1
        ) { [weak self] in
            self?.controller.toggleRecording()
        }
        microphoneHotKey = GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_M),
            modifiers: modifiers,
            identifier: 2
        ) { [weak self] in
            self?.controller.toggleMicrophonePause()
        }
    }

    private func observeController() {
        controller.$liveCaption.combineLatest(controller.$state, controller.settings.$liveCaptionsEnabled)
            .receive(on: RunLoop.main)
            .sink { [weak self] update, state, enabled in
                if enabled && state.isCapturing { self?.captionOverlay.show(update) }
                else { self?.captionOverlay.hide() }
            }.store(in: &cancellables)
        controller.$captureWarning
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateStatusItem(for: self.controller.state)
            }.store(in: &cancellables)
        controller.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.updateStatusItem(for: state)
            }
            .store(in: &cancellables)
    }

    private func updateStatusItem(for state: RecordingState) {
        guard let button = statusItem.button else { return }

        let symbolName: String
        let color: NSColor?
        switch state {
        case .idle:
            symbolName = "mic"
            color = nil
        case .recording:
            symbolName = "record.circle.fill"
            color = .systemRed
        case .microphonePaused:
            symbolName = "mic.slash.fill"
            color = .systemOrange
        case .starting, .recovering:
            symbolName = "arrow.triangle.2.circlepath"
            color = .systemOrange
        case .processing:
            symbolName = "ellipsis.bubble.fill"
            color = .systemBlue
        case .error:
            symbolName = "exclamationmark.triangle.fill"
            color = .systemOrange
        }

        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: state.title)
        button.image?.isTemplate = color == nil
        button.contentTintColor = color
        button.toolTip = "CallScribe: \(state.title). Left-click to start or stop; right-click for options."
        if state.isCapturing, let warning = controller.captureWarning {
            button.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Recording needs attention")
            button.image?.isTemplate = false
            button.contentTintColor = .systemOrange
            button.toolTip = warning
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(relativeTo: sender)
        } else {
            controller.toggleRecording()
        }
    }

    private func showMenu(relativeTo button: NSStatusBarButton) {
        let menu = NSMenu()

        let stateItem = NSMenuItem(title: controller.state.title, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        let detail = NSMenuItem(title: controller.captureWarning ?? controller.statusDetail, action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(detail)

        if case .error(let message) = controller.state {
            let errorItem = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }
        menu.addItem(.separator())

        let toggleTitle = controller.state.isCapturing ? "Stop and Copy Transcript" : "Start Recording"
        let toggle = NSMenuItem(title: toggleTitle, action: #selector(toggleRecording), keyEquivalent: "r")
        toggle.keyEquivalentModifierMask = [.control, .option, .command]
        toggle.target = self
        toggle.isEnabled = controller.state.canStartOrStop
        menu.addItem(toggle)

        let pauseTitle = controller.state == .microphonePaused ? "Resume My Microphone" : "Pause My Microphone"
        let pause = NSMenuItem(title: pauseTitle, action: #selector(toggleMicrophone), keyEquivalent: "m")
        pause.keyEquivalentModifierMask = [.control, .option, .command]
        pause.target = self
        pause.isEnabled = controller.state == .recording || controller.state == .microphonePaused
        menu.addItem(pause)

        let languageMenu = NSMenu()
        languageMenu.autoenablesItems = false
        for language in TranscriptionLanguage.allCases {
            let item = targetedItem(language.title, action: #selector(selectLanguage(_:)), enabled: controller.canChangeLanguage)
            item.representedObject = language.rawValue
            item.state = controller.settings.language == language ? .on : .off
            languageMenu.addItem(item)
        }
        let languageItem = NSMenuItem(title: "Language: \(controller.settings.language.title)", action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        let captions = targetedItem("Live English Captions", action: #selector(toggleCaptions), enabled: controller.canToggleCaptions)
        captions.state = controller.settings.liveCaptionsEnabled ? .on : .off
        menu.addItem(captions)
        menu.addItem(targetedItem(controller.preparingCaptions ? "Preparing Caption Model…" : "Prepare Caption Model (one-time)…",
            action: #selector(prepareCaptions), enabled: controller.canChangeLanguage && !controller.preparingCaptions))

        menu.addItem(.separator())
        menu.addItem(targetedItem("Copy Last Transcript", action: #selector(copyLast), enabled: controller.lastTranscriptURL != nil))
        menu.addItem(targetedItem("Open Last Transcript", action: #selector(openLast), enabled: controller.lastTranscriptURL != nil))
        menu.addItem(targetedItem("Open Sessions Folder", action: #selector(openSessions)))
        menu.addItem(targetedItem("Retry Saved Sessions (\(controller.pendingCount))", action: #selector(retryPending),
            enabled: controller.pendingCount > 0 && controller.state.canStartOrStop && !controller.state.isCapturing))

        if controller.modelReadiness != .ready {
            menu.addItem(.separator())
            let preparing: Bool
            if case .downloading = controller.modelReadiness { preparing = true } else { preparing = false }
            menu.addItem(targetedItem(
                preparing ? "Preparing Offline Models..." : "Prepare Offline Models...",
                action: #selector(prepareModels),
                enabled: !preparing
            ))
        }

        menu.addItem(.separator())
        menu.addItem(targetedItem("Settings...", action: #selector(showSettingsFromMenu), keyEquivalent: ","))
        menu.addItem(targetedItem("Quit CallScribe", action: #selector(quit), keyEquivalent: "q"))
        NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent!, for: button)
    }

    private func targetedItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String = "",
        enabled: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.isEnabled = enabled
        return item
    }

    @objc private func toggleRecording() { controller.toggleRecording() }
    @objc private func toggleCaptions() { controller.toggleLiveCaptions() }
    @objc private func prepareCaptions() { controller.prepareCaptionModels() }
    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String,
              let language = TranscriptionLanguage(rawValue: code) else { return }
        controller.selectLanguage(language)
    }
    @objc private func toggleMicrophone() { controller.toggleMicrophonePause() }
    @objc private func copyLast() { controller.copyLastTranscript() }
    @objc private func openLast() { controller.openLastTranscript() }
    @objc private func openSessions() { controller.openSessionsDirectory() }
    @objc private func prepareModels() { controller.prepareModels() }
    @objc private func retryPending() { controller.retryPending() }
    @objc private func showSettingsFromMenu() { showSettings() }

    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(controller: controller)))
            window.title = "CallScribe"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        if controller.state.isCapturing {
            let alert = NSAlert()
            alert.messageText = "Stop recording before quitting?"
            alert.informativeText = "CallScribe continuously saves recoverable audio, but stopping now also starts transcript processing."
            alert.addButton(withTitle: "Stop and Quit Later")
            alert.addButton(withTitle: "Keep Running")
            if alert.runModal() == .alertFirstButtonReturn {
                controller.stopRecording()
            }
            return
        }
        NSApp.terminate(nil)
    }
}
