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
        // One above Apple's Dock, which reorders itself on restart.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        // Joins full-screen Spaces too, where DockController keeps it hidden until the bottom edge.
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

/// Owns the dock panel: sizing, positioning, and auto-hide (always, on full-screen Spaces).
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
    /// The dock's screen is showing a full-screen window, so the dock auto-hides there.
    private(set) var isFullScreen = false
    /// Number of popovers/menus currently open; the dock never hides while > 0.
    private(set) var holdCount = 0

    @ObservationIgnored private let panel = DockPanel()
    @ObservationIgnored private var contentSize: CGSize = .zero
    @ObservationIgnored private var screen: NSScreen?
    /// Observed, so the bar re-fits its apps when it moves to a narrower or wider display.
    private(set) var screenWidth: CGFloat = NSScreen.screens.first?.frame.width ?? 1440
    /// Shelf's top edge last time windows were fenced to it.
    @ObservationIgnored private var lastFence: CGFloat?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var monitors: [Any] = []

    func start() {
        let host = DockHostingView(rootView: DockRootView())
        host.sizingOptions = []
        panel.contentView = host
        screen = NSScreen.screens.first

        isShown = !UserDefaults.standard.autoHide
        layout()
        updateFullScreen()
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
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DockController.shared.spaceChanged() }
        }
        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DockController.shared.updateFullScreen() }
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
        guard let screen = currentScreen() else { return }
        let f = screen.frame
        let w = ceil(contentSize.width), h = ceil(contentSize.height)
        let shownY = f.minY + Self.bottomMargin
        let hiddenY = f.minY - h // fully below the edge
        let frame = NSRect(x: round(f.midX - w / 2), y: isShown ? shownY : hiddenY, width: w, height: h)
        if frame != panel.frame { panel.setFrame(frame, display: true) }

        // Shelf's top edge appeared or moved up: trim windows already reaching under it.
        let top = fence?.top
        if let top, top > (lastFence ?? -.infinity) { WindowFence.shared.fenceAll() }
        lastFence = top
    }

    /// The dock's screen, looked up again each time: a kept NSScreen goes stale when displays change.
    private func currentScreen() -> NSScreen? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let id = screen?.deviceDescription[key] as? NSNumber
        screen = NSScreen.screens.first { $0.deviceDescription[key] as? NSNumber == id } ?? NSScreen.screens.first
        if let width = screen?.frame.width, width != screenWidth { screenWidth = width }
        return screen
    }

    /// Re-positions after displays change. Also called every few seconds as a fallback.
    func screenParametersChanged() {
        layout()
        updateFullScreen()
    }

    private func settingsChanged() {
        if !autoHides && !isShown { reveal() }
    }

    /// Widest the bar can be on its screen, including the transparent side padding.
    var maxWidth: CGFloat { screenWidth - 2 * Self.bottomMargin }

    /// Shelf's top edge while it stays on screen, for WindowFence; nil while it auto-hides.
    var fence: (screen: NSRect, top: CGFloat)? {
        guard !autoHides, isShown, let screen else { return nil }
        return (screen.frame, panel.frame.maxY - Self.headroom + Self.bottomMargin)
    }

    // MARK: Full screen

    /// The dock auto-hides when the setting says so, and always on a full-screen Space.
    var autoHides: Bool { UserDefaults.standard.autoHide || isFullScreen }

    private func spaceChanged() {
        updateFullScreen()
        // Entering or leaving full screen animates; look again once windows have settled.
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            DockController.shared.updateFullScreen()
        }
    }

    private func updateFullScreen() {
        guard let screen = currentScreen() else { return }
        let full = Self.hasFullScreenWindow(on: screen)
        guard full != isFullScreen else { return }
        isFullScreen = full
        hideTask?.cancel()
        // An open popover or menu keeps the dock up; it hides once that closes.
        if holdCount == 0 || !autoHides { isShown = !autoHides }
        layout()
    }

    /// Whether the screen is showing a full-screen Space, or a window covering the whole screen
    /// (apps that fake full screen, like some games and slideshows). Neither depends on which app or
    /// display has focus. Window bounds alone can't tell: on displays with a notch a full-screen
    /// window starts below the notch, exactly like a zoomed one.
    private static func hasFullScreenWindow(on screen: NSScreen) -> Bool {
        if FullScreenSpaces.isCurrentSpaceFullScreen(on: screen) == true { return true }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return false }
        // Window bounds use a top-left origin on the primary screen.
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let f = screen.frame
        let target = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
        let me = ProcessInfo.processInfo.processIdentifier
        return windows.contains { window in
            guard window[kCGWindowLayer as String] as? Int == 0,
                  window[kCGWindowOwnerPID as String] as? pid_t != me,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return rect == target
        }
    }

    // MARK: Auto-hide

    func reveal() {
        hideTask?.cancel()
        let mouse = NSEvent.mouseLocation
        // Only an auto-hiding dock follows the pointer to another display; otherwise it stays home
        // (and is merely hidden while that display shows a full-screen window).
        if UserDefaults.standard.autoHide,
           let s = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }), s != screen, !isShown {
            screen = s
            isFullScreen = Self.hasFullScreenWindow(on: s)
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
        if isShown && autoHides {
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
               mouse.y <= s.frame.minY + Self.revealEdge,
               UserDefaults.standard.autoHide || s == screen { // see reveal()
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
        guard autoHides, isShown, holdCount == 0, hideTask == nil || hideTask!.isCancelled else { return }
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

/// Reads each display's current Space from the window server. These calls are private (no public
/// API says whether a Space is full screen) but long-standing; if they ever go away this returns nil
/// and only the window-bounds check is left.
private enum FullScreenSpaces {
    /// The window server's type for a full-screen Space (0 is a regular desktop).
    private static let fullScreenType = 4

    static func isCurrentSpaceFullScreen(on screen: NSScreen) -> Bool? {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]],
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let uuidString = CFUUIDCreateString(nil, uuid) as String? else { return nil }
        // With "Displays have separate Spaces" off there's a single entry, called "Main".
        let display = displays.first { $0["Display Identifier"] as? String == uuidString }
            ?? displays.first { $0["Display Identifier"] as? String == "Main" }
        guard let space = display?["Current Space"] as? [String: Any], let type = space["type"] as? Int else { return nil }
        return type == fullScreenType
    }
}

@_silgen_name("CGSMainConnectionID") nonisolated private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") nonisolated private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> CFArray?
