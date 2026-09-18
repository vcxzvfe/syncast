import AppKit
import SwiftUI

/// Keeps the `MenuBarExtra(.window)` panel exactly as tall as its content.
///
/// The panel SwiftUI creates for a window-style menu bar extra sizes itself
/// when it opens and then follows content changes only loosely: when a row
/// appears or an inline editor collapses while it is open — or between two
/// opens — the panel keeps its old height and the difference shows as a
/// transparent, empty band above or below the content. And content taller
/// than the screen simply runs off it.
///
/// So the height is owned here instead: the content is measured, capped to
/// what the screen can show (scrolling beyond that), given to the scroll view
/// as an explicit frame — which is also what keeps a `ScrollView` from
/// collapsing to nothing inside this kind of panel — and the hosting window
/// is resized to match with its top edge held where the menu bar put it.
struct PopoverAutosize: ViewModifier {
    /// Space kept free below the panel so it never touches the screen edge.
    static let screenMargin: CGFloat = 16
    /// Differences smaller than this are layout noise, not a resize.
    static let tolerance: CGFloat = 0.5

    @State private var contentHeight: CGFloat?
    @State private var window: NSWindow?

    func body(content: Content) -> some View {
        let height = contentHeight.map { Self.fittedHeight(content: $0, available: availableHeight) }
        ScrollView(.vertical, showsIndicators: false) {
            content
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: height)
        .background(WindowReader { window = $0 })
        .onPreferenceChange(ContentHeightKey.self) { measured in
            guard measured > 0 else { return }
            if let current = contentHeight, abs(current - measured) < Self.tolerance { return }
            contentHeight = measured
        }
        .onChange(of: height) { _, _ in fitWindow() }
        .onChange(of: window) { _, _ in fitWindow() }
        .onAppear { fitWindow() }
    }

    /// Height the screen under the panel can show.
    private var availableHeight: CGFloat {
        let screen = window?.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return 900 }
        if let window {
            // From the panel's top edge down to the bottom of the usable area.
            return max(200, window.frame.maxY - visible.minY - Self.screenMargin)
        }
        return max(200, visible.height - Self.screenMargin)
    }

    /// Pure: content height capped to what is available.
    static func fittedHeight(content: CGFloat, available: CGFloat) -> CGFloat {
        min(max(content, 1), max(available, 1))
    }

    /// Pure: the frame that shows `contentHeight` with the top edge fixed.
    static func fittedFrame(current: NSRect, currentContentHeight: CGFloat, contentHeight: CGFloat) -> NSRect {
        let chrome = max(0, current.height - currentContentHeight)
        let newHeight = contentHeight + chrome
        return NSRect(x: current.minX, y: current.maxY - newHeight, width: current.width, height: newHeight)
    }

    private func fitWindow() {
        guard let window, let contentHeight else { return }
        let target = Self.fittedHeight(content: contentHeight, available: availableHeight)
        let contentNow = window.contentLayoutRect.height
        guard abs(contentNow - target) >= Self.tolerance else { return }
        let frame = Self.fittedFrame(current: window.frame, currentContentHeight: contentNow, contentHeight: target)
        window.setFrame(frame, display: true, animate: false)
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Hands back the `NSWindow` hosting this view once it is in one.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { WindowProbeView(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowProbeView: NSView {
        let onWindow: (NSWindow?) -> Void
        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let found = window
            DispatchQueue.main.async { [onWindow] in onWindow(found) }
        }
    }
}

extension View {
    /// See `PopoverAutosize`.
    func popoverAutosize() -> some View { modifier(PopoverAutosize()) }
}
