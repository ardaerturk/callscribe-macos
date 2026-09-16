import AppKit
import CallScribeTranscription
import SwiftUI

@MainActor
final class CaptionOverlay {
    private var panel: NSPanel?
    private var screenNumber: NSNumber?
    private var screenObserver: NSObjectProtocol?
    private var latestUpdate = LiveCaptionUpdate()

    init() {
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.position() }
            }
    }

    func show(_ update: LiveCaptionUpdate) {
        latestUpdate = update
        if panel == nil {
            let created = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            created.level = .floating
            created.isOpaque = false
            created.backgroundColor = .clear
            created.hasShadow = true
            created.ignoresMouseEvents = true
            created.hidesOnDeactivate = false
            created.isReleasedWhenClosed = false
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            created.title = "CallScribe English Captions"
            panel = created
        }
        if panel?.isVisible != true {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            screenNumber = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        }
        position()
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    static func renderPreview(to url: URL) throws {
        let update = LiveCaptionUpdate(callText: "We can review the project budget together next week.",
            yourText: "Thank you. I’ll send the updated report on Friday.",
            status: "English · live translation · may contain errors")
        let view = NSHostingView(rootView: CaptionOverlayView(update: update, width: 980))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CallScribeBackendError.unavailable("Could not render caption preview")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CallScribeBackendError.unavailable("Could not encode caption preview")
        }
        try png.write(to: url, options: .atomic)
    }

    static func frame(in visibleFrame: NSRect) -> NSRect {
        let width = max(200, min(980, visibleFrame.width - 64))
        return NSRect(x: visibleFrame.midX - width / 2, y: visibleFrame.minY + 32,
                      width: width, height: min(220, visibleFrame.height - 64))
    }

    private func position() {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == screenNumber
        } ?? NSScreen.main
        guard let screen else { return }
        var frame = Self.frame(in: screen.visibleFrame)
        let view = NSHostingView(rootView: CaptionOverlayView(update: latestUpdate, width: frame.width))
        frame.size.height = min(frame.height, max(60, view.fittingSize.height))
        panel?.contentView = view
        panel?.setFrame(frame, display: true)
    }
}

private struct CaptionOverlayView: View {
    let update: LiveCaptionUpdate
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !update.callText.isEmpty { caption("Call", update.callText) }
            if !update.yourText.isEmpty { caption("You", update.yourText) }
            Text(update.status).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .frame(width: width - 8, alignment: .leading)
        .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 16))
        .padding(4)
    }

    private func caption(_ label: String, _ text: String) -> some View {
        Text("\(label): \(text)")
            .font(.system(size: 21, weight: .medium)).foregroundStyle(.white)
            .lineLimit(update.callText.isEmpty || update.yourText.isEmpty ? 3 : 2)
            .truncationMode(.head).fixedSize(horizontal: false, vertical: true)
    }
}
