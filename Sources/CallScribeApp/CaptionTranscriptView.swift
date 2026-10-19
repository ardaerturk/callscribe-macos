import AppKit
import CallScribeTranscription
import SwiftUI

/// AppKit preserves normal selection and trackpad scrolling in a nonactivating
/// panel. Once the user scrolls up, keep the rendered snapshot still until Live.
struct CaptionTranscriptView: NSViewRepresentable {
    let segments: [CaptionSegment]
    let fontSize: Double
    let showOriginal: Bool
    @Binding var followingLive: Bool
    let followsLive: Bool

    init(segments: [CaptionSegment], fontSize: Double, showOriginal: Bool, followingLive: Binding<Bool>) {
        self.segments = segments
        self.fontSize = fontSize
        self.showOriginal = showOriginal
        self._followingLive = followingLive
        self.followsLive = followingLive.wrappedValue
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let text = NSTextView(frame: .zero)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isRichText = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainerInset = NSSize(width: 3, height: 3)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.heightTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        scroll.documentView = text
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak scroll, weak coordinator = context.coordinator] _ in
                guard let scroll, let coordinator, !coordinator.programmatic else { return }
                let bottomDistance = (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.maxY
                if bottomDistance > 12 { coordinator.pause?() }
            }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.pause = { if followingLive { followingLive = false } }
        guard let text = scroll.documentView as? NSTextView else { return }
        guard followsLive || text.string.isEmpty else { context.coordinator.wasFollowing = false; return }
        let signature = segments.map { "\($0.id):\($0.isFinal):\($0.text):\($0.originalText)" }.joined() + "\(fontSize)-\(showOriginal)"
        guard context.coordinator.signature != signature || !context.coordinator.wasFollowing else { return }
        context.coordinator.signature = signature
        context.coordinator.wasFollowing = followsLive
        context.coordinator.programmatic = true
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 9
        paragraph.lineSpacing = 3
        for (index, segment) in segments.enumerated() {
            let color = segment.isFinal ? NSColor.white : NSColor.white.withAlphaComponent(0.7)
            result.append(NSAttributedString(string: segment.text + (index == segments.count - 1 ? "" : "\n"), attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium), .foregroundColor: color, .paragraphStyle: paragraph]))
            if showOriginal, !segment.originalText.isEmpty {
                result.append(NSAttributedString(string: "\n" + segment.originalText + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: max(12, fontSize * 0.7)),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.45), .paragraphStyle: paragraph]))
            }
        }
        text.textStorage?.setAttributedString(result)
        text.setFrameSize(NSSize(width: scroll.contentSize.width, height: text.frame.height))
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let height = (text.layoutManager?.usedRect(for: text.textContainer!).height ?? 0) + 8
        text.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(scroll.contentSize.height, height)))
        if followsLive {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, text.frame.height - scroll.contentSize.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        context.coordinator.programmatic = false
    }

    final class Coordinator {
        var observer: NSObjectProtocol?
        var programmatic = false
        var signature = ""
        var wasFollowing = true
        var pause: (() -> Void)?
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
