import AppKit
import CallScribeTranscription
import Combine
import SwiftUI

@MainActor
final class CaptionPresentation: ObservableObject {
    @Published var history = CaptionHistory()
    @Published var status = "Waiting for call audio…"
    @Published var followingLive = true
    func receive(_ update: LiveCaptionUpdate) {
        if let segment = update.segment { history.apply(segment) }
        status = update.status
    }
}

@MainActor
final class CaptionOverlay: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let model = CaptionPresentation()
    private let settings: AppSettings
    private var observers = Set<AnyCancellable>()
    private var dismissed = false
    private var positioning = false

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        settings.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.resize() }
        }.store(in: &observers)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.keepOnScreen() }.store(in: &observers)
    }

    func beginSession() {
        model.history = CaptionHistory()
        model.followingLive = true
        dismissed = false
    }

    func show(_ update: LiveCaptionUpdate) {
        model.receive(update)
        guard !dismissed else { return }
        present()
    }

    func review() {
        dismissed = false
        present()
    }

    func finish(_ update: LiveCaptionUpdate) {
        if let segment = update.segment { model.history.apply(segment) }
        model.status = "Meeting ended · captions kept here for review"
    }

    func hide() { panel?.orderOut(nil) }

    private func present() {
        if panel == nil {
            let created = CaptionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            created.level = .floating
            created.becomesKeyOnlyIfNeeded = true
            created.isOpaque = false
            created.backgroundColor = .clear
            created.hasShadow = true
            created.hidesOnDeactivate = false
            created.isReleasedWhenClosed = false
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            created.title = "CallScribe English Captions"
            created.delegate = self
            created.contentView = NSHostingView(rootView: CaptionOverlayView(model: model, settings: settings,
                reset: { [weak self] in self?.resetPosition() }, close: { [weak self] in self?.dismissed = true; self?.hide() }))
            panel = created
            if let saved = UserDefaults.standard.string(forKey: "captionWindowFrame") {
                created.setFrame(NSRectFromString(saved), display: false)
                keepOnScreen()
            } else { resetPosition() }
        }
        panel?.orderFrontRegardless()
    }

    func windowDidMove(_ notification: Notification) {
        guard !positioning, let panel else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "captionWindowFrame")
    }

    static func frame(in visibleFrame: NSRect) -> NSRect {
        let width = max(200, min(980, visibleFrame.width - 32))
        return NSRect(x: visibleFrame.midX - width / 2, y: visibleFrame.minY + 32,
                      width: width, height: min(210, visibleFrame.height - 64))
    }

    private func resetPosition() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        panel?.setFrame(Self.frame(in: screen.visibleFrame), display: true)
        resize()
    }

    private func resize() {
        guard let panel else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - settings.captionHeight
        frame.size = NSSize(width: settings.captionWidth, height: settings.captionHeight)
        panel.setFrame(frame, display: true)
        keepOnScreen()
    }

    private func keepOnScreen() {
        guard let panel, let screen = NSScreen.screens.max(by: {
            $0.visibleFrame.intersection(panel.frame).size.area < $1.visibleFrame.intersection(panel.frame).size.area
        }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        var frame = panel.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        positioning = true
        panel.setFrame(frame, display: true)
        positioning = false
    }

    static func renderPreview(to url: URL) throws {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "CallScribe.Preview")!)
        let model = CaptionPresentation()
        model.receive(.init(status: "Azure · live English · updating…", segment: .init(id: "1",
            text: "We can review the project budget together next week.", startTime: 12, isFinal: true)))
        model.receive(.init(status: "Azure · live English · updating…", segment: .init(id: "2",
            text: "I’ll send the updated report on Friday, so we have time to", startTime: 19, isFinal: false)))
        let view = NSHostingView(rootView: CaptionOverlayView(model: model, settings: settings, reset: {}, close: {}))
        view.frame = NSRect(x: 0, y: 0, width: 980, height: 210)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: url, options: .atomic) }
    }
}

private extension NSSize {
    var area: CGFloat { max(0, width) * max(0, height) }
}

private struct CaptionOverlayView: View {
    @ObservedObject var model: CaptionPresentation
    @ObservedObject var settings: AppSettings
    let reset: () -> Void
    let close: () -> Void
    @State private var showOptions = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "line.3.horizontal")
                    Text("ENGLISH CAPTIONS").font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(1)
                }.foregroundStyle(.white.opacity(0.6))
                    .overlay(CaptionDragHandle())
                Spacer().frame(minWidth: 12).overlay(CaptionDragHandle())
                Button { settings.captionFontSize = max(16, settings.captionFontSize - 2) } label: {
                    Text("A−").font(.system(size: 13, weight: .medium))
                }.help("Smaller caption text").accessibilityLabel("Smaller caption text")
                Button { settings.captionFontSize = min(40, settings.captionFontSize + 2) } label: {
                    Text("A+").font(.system(size: 15, weight: .medium))
                }.help("Larger caption text").accessibilityLabel("Larger caption text")
                Button {
                    model.followingLive.toggle()
                } label: {
                    Label(model.followingLive ? "Live" : "Return to live", systemImage: model.followingLive ? "pause.circle" : "arrow.down.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(model.followingLive ? .white.opacity(0.85) : .mint)
                }.help("Pause scrolling to read earlier captions. Audio keeps translating.")
                Button { showOptions.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Caption appearance").help("Caption appearance")
                    .popover(isPresented: $showOptions) { appearance.padding(20).frame(width: 300) }
                Button(action: close) { Image(systemName: "xmark") }
                    .help("Hide panel; translation continues. Reopen from the menu bar.").accessibilityLabel("Hide captions")
            }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 20).padding(.top, 13).padding(.bottom, 9)
            if model.history.segments.isEmpty {
                Text("English will appear here as people speak.\nScroll back whenever you need to catch up.")
                    .font(.system(size: settings.captionFontSize)).foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(.horizontal, 20)
            } else {
                CaptionTranscriptView(segments: model.history.segments, fontSize: settings.captionFontSize,
                    showOriginal: settings.captionOriginal, followingLive: $model.followingLive)
                    .padding(.horizontal, 16)
            }
            HStack {
                Circle().fill(model.followingLive ? .mint : .orange).frame(width: 5, height: 5)
                Text(model.followingLive ? model.status : "Reading earlier captions · translation continues")
                    .font(.system(size: 10)).lineLimit(1)
                Spacer()
                Text("Drag header to move").font(.system(size: 10))
            }.foregroundStyle(.white.opacity(0.55)).padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 11)
        }
        .background(.black.opacity(settings.captionOpacity), in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(0.12)))
        .padding(4)
        .preferredColorScheme(.dark)
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Make captions comfortable").font(.headline)
            LabeledContent("Text", value: "\(Int(settings.captionFontSize)) pt")
            Slider(value: $settings.captionFontSize, in: 16...40, step: 1)
            Text("Width")
            Slider(value: $settings.captionWidth, in: 520...1400, step: 20)
            Text("Height")
            Slider(value: $settings.captionHeight, in: 150...400, step: 10)
            Text("Background")
            Slider(value: $settings.captionOpacity, in: 0.45...1)
            Toggle("Show original German / source text", isOn: $settings.captionOriginal)
            Button("Reset position") { reset() }
        }
    }
}

/// Only the header's non-interactive area drags the panel. Text remains selectable.
private struct CaptionDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
}

private final class CaptionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
