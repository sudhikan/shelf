import AppKit
import SwiftUI

/// Borderless, non-activating panel that floats at Dock level on every Space.
final class DockPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true // clicks on tiles don't steal keyboard focus
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Allow sliding below the bottom edge when auto-hidden.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Lets the very first click act on a tile even when Shelf isn't the active app.
/// Without this, AppKit spends that click focusing the panel and only the second one
/// reaches the widget — the classic "click twice" problem.
final class DockHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the dock panel: sizing, positioning, and auto-hide.
@Observable
final class DockController {
    static let shared = DockController()

    /// Transparent space above the bar for zoomed app icons and their hover labels.
    static let headroom: CGFloat = 72
    /// Transparent space either side of the bar for hover labels.
    static let sidePadding: CGFloat = 40
    private static let bottomMargin: CGFloat = 4
    private static let revealEdge: CGFloat = 2

    private(set) var isShown = true
    /// Number of popovers/menus currently open; the dock never hides while > 0.
    private(set) var holdCount = 0

    @ObservationIgnored private let panel = DockPanel()
    @ObservationIgnored private var contentSize: CGSize = .zero
    @ObservationIgnored private var screen: NSScreen?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var monitors: [Any] = []

    func start() {
        let host = DockHostingView(rootView: DockRootView())
        host.sizingOptions = []
        panel.contentView = host
        screen = NSScreen.screens.first

        isShown = !UserDefaults.standard.autoHide
        layout()
        panel.orderFrontRegardless()

        let handler: (NSEvent) -> Void = { [weak self] _ in self?.mouseMoved() }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { handler($0); return $0 }) {
            monitors.append(m)
        }
        // Clicking anywhere outside the dock (i.e. in another app) ends edit mode.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { _ in
            MainActor.assumeIsolated { DockEditor.shared.end() }
        }) {
            monitors.append(m)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DockController.shared.screenParametersChanged() }
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DockController.shared.settingsChanged() }
        }
    }

    // MARK: Sizing

    func contentSizeChanged(_ size: CGSize) {
        guard size != contentSize else { return }
        contentSize = size
        layout()
    }

    private func layout() {
        guard let screen = screen ?? NSScreen.screens.first else { return }
        let f = screen.frame
        let w = ceil(contentSize.width), h = ceil(contentSize.height)
        let shownY = f.minY + Self.bottomMargin
        let hiddenY = f.minY - h // fully below the edge
        let frame = NSRect(x: round(f.midX - w / 2), y: isShown ? shownY : hiddenY, width: w, height: h)
        panel.setFrame(frame, display: true)
    }

    private func screenParametersChanged() {
        if let s = screen, !NSScreen.screens.contains(s) { screen = NSScreen.screens.first }
        layout()
    }

    private func settingsChanged() {
        if !UserDefaults.standard.autoHide && !isShown { reveal() }
    }

    // MARK: Auto-hide

    func reveal() {
        hideTask?.cancel()
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }), s != screen, !isShown {
            screen = s
            layout()
        }
        guard !isShown else { return }
        isShown = true
        layout()
        scheduleHideIfNeeded()
    }

    /// Converts a rect in the dock's SwiftUI global space (top-left origin) to screen coordinates.
    func screenRect(fromDockRect rect: CGRect) -> NSRect {
        let height = panel.contentView?.bounds.height ?? panel.frame.height
        return panel.convertToScreen(NSRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height))
    }

    func toggle() {
        if isShown && UserDefaults.standard.autoHide {
            hideTask?.cancel()
            isShown = false
            layout()
        } else {
            reveal()
        }
    }

    func hold() { holdCount += 1; hideTask?.cancel() }
    func release() {
        holdCount = max(0, holdCount - 1)
        scheduleHideIfNeeded()
    }

    private func mouseMoved() {
        let mouse = NSEvent.mouseLocation
        if !isShown {
            if let s = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
               mouse.y <= s.frame.minY + Self.revealEdge {
                reveal()
            }
            return
        }
        if barRect.contains(mouse) { hideTask?.cancel() } else { scheduleHideIfNeeded() }
    }

    /// The visible bar (excludes the transparent headroom), padded a little.
    private var barRect: NSRect {
        var r = panel.frame
        r.size.height -= Self.headroom
        r = r.insetBy(dx: Self.sidePadding, dy: 0)
        return r.insetBy(dx: -6, dy: -6)
    }

    private func scheduleHideIfNeeded() {
        guard UserDefaults.standard.autoHide, isShown, holdCount == 0, hideTask == nil || hideTask!.isCancelled else { return }
        guard !barRect.contains(NSEvent.mouseLocation) else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled else { return }
            self.hideTask = nil
            guard self.holdCount == 0, !self.barRect.contains(NSEvent.mouseLocation) else { return }
            self.isShown = false
            self.layout()
        }
    }
}
