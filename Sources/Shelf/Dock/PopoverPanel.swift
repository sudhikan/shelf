import AppKit
import SwiftUI

/// Borderless, non-activating panel for a widget's expanded view. Like Spotlight, it can take
/// keyboard input without bringing Shelf forward — macOS 14+ won't let an accessory app
/// activate itself while another app is in front, so NSPopover text fields never got focus.
final class PopoverPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc closes it.
    override func cancelOperation(_ sender: Any?) { DockPopover.shared.close() }
}

/// Shows one expanded widget at a time above its tile; closes on Esc or a click elsewhere.
final class DockPopover {
    static let shared = DockPopover()

    private var panel: PopoverPanel?
    private var anchor: NSRect = .zero
    private var onClose: (() -> Void)?
    private var monitors: [Any] = []

    private static let cornerRadius: CGFloat = 16
    private static let gap: CGFloat = 8

    /// - Parameters:
    ///   - anchor: the tile's frame in screen coordinates.
    ///   - onClose: called when the panel closes for any reason other than the owner asking.
    func show<Content: View>(anchor: NSRect, onClose: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        close()
        self.anchor = anchor
        self.onClose = onClose

        let panel = PopoverPanel()
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Self.cornerRadius
        effect.layer?.masksToBounds = true

        let root = content()
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { DockPopover.shared.resize(to: $0) }
        let host = DockHostingView(rootView: root)
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        panel.contentView = effect

        let size = host.fittingSize
        panel.setFrame(frame(for: size), display: false)
        host.frame = effect.bounds
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        DockController.shared.hold()
        installMonitors()
    }

    /// Closes the panel. `notify` is false when the owning tile closed it itself.
    func close(notify: Bool = true) {
        guard let panel else { return }
        self.panel = nil
        panel.orderOut(nil)
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        DockController.shared.release()
        let callback = onClose
        onClose = nil
        if notify { callback?() }
    }

    private func resize(to size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        panel.setFrame(frame(for: size), display: true)
    }

    /// Centered above the tile, kept on screen.
    private func frame(for size: CGSize) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? .zero
        var x = anchor.midX - size.width / 2
        x = min(max(x, bounds.minX + 6), bounds.maxX - size.width - 6)
        let y = min(anchor.maxY + Self.gap, bounds.maxY - size.height - 6)
        return NSRect(x: round(x), y: round(y), width: ceil(size.width), height: ceil(size.height))
    }

    private func installMonitors() {
        // A click in another app closes it.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { _ in
            MainActor.assumeIsolated { DockPopover.shared.close() }
        }) {
            monitors.append(m)
        }
        // A click in one of Shelf's own windows other than the panel or the dock (e.g. Settings).
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { event in
            let popover = DockPopover.shared
            if event.window !== popover.panel, !(event.window is DockPanel) { popover.close() }
            return event
        }) {
            monitors.append(m)
        }
    }
}
