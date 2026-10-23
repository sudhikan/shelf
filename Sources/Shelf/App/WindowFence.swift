import AppKit
import ApplicationServices

/// Keeps windows from reaching under Shelf while it stays on screen, the way Apple's Dock reserves
/// its space. When a window is opened, resized, zoomed or tiled with its bottom edge under Shelf,
/// it's trimmed to end at Shelf's top. Moving a window is left alone, so one can still be dragged
/// down past Shelf. Needs Accessibility permission; does nothing without it.
final class WindowFence {
    static let shared = WindowFence()

    /// Windows shorter than this after trimming are left alone (they mostly sit under Shelf on purpose).
    private static let minHeight: CGFloat = 120
    /// Accessibility calls block until the other app answers; a hung app mustn't hang Shelf.
    private static let messagingTimeout: Float = 0.25
    private static let didPromptKey = "didPromptForAccessibility"

    private var observers: [pid_t: AXObserver] = [:]
    /// Apps that refused to be observed: how often, and when to try again.
    private var failures: [pid_t: (count: Int, retryAt: Date)] = [:]
    /// Windows waiting to be trimmed once resizing settles.
    private var pending: [AXUIElement] = []
    private var flushTask: Task<Void, Never>?
    /// When each window was last trimmed, so an app that insists on its own height isn't fought.
    private var trimmed: [AXUIElement: Date] = [:]

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own prompt pointing at Privacy & Security › Accessibility.
    static func requestAccess() {
        let key = "AXTrustedCheckOptionPrompt" // kAXTrustedCheckOptionPrompt, which Swift 6 treats as mutable global state
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func start() {
        // Applies to every element Shelf creates.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.messagingTimeout)
        // Ask once; after that, Settings has a button for it.
        if !Self.isTrusted && !UserDefaults.standard.bool(forKey: Self.didPromptKey) {
            UserDefaults.standard.set(true, forKey: Self.didPromptKey)
            Self.requestAccess()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WindowFence.shared.sync() }
        }
        // Retries apps that weren't ready to be observed yet, and notices permission granted later.
        Task {
            while !Task.isCancelled {
                sync()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Observes every regular app that isn't observed yet and forgets the ones that quit.
    private func sync() {
        guard Self.isTrusted else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let pids = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
            .map(\.processIdentifier))
        for pid in observers.keys where !pids.contains(pid) {
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
        }
        failures = failures.filter { pids.contains($0.key) }
        let now = Date()
        for pid in pids where observers[pid] == nil && (failures[pid]?.retryAt ?? now) <= now {
            if !watch(pid) {
                // Back off: 3 s, 6 s, 12 s … about 3 minutes in all, then give up on this app.
                let count = (failures[pid]?.count ?? 0) + 1
                let delay = count > 6 ? Double.infinity : 3 * pow(2, Double(count - 1))
                failures[pid] = (count, now.addingTimeInterval(delay))
            }
        }
    }

    private func watch(_ pid: pid_t) -> Bool {
        var created: AXObserver?
        guard AXObserverCreate(pid, fenceCallback, &created) == .success, let observer = created else { return false }
        let app = AXUIElementCreateApplication(pid)
        // An app that's still launching refuses notifications; sync tries again later.
        guard AXObserverAddNotification(observer, app, kAXWindowCreatedNotification as CFString, nil) == .success
        else { return false }
        AXObserverAddNotification(observer, app, kAXWindowResizedNotification as CFString, nil)
        // Not every app passes window notifications up to the app element, so watch each window too.
        for window in Self.windows(of: app) {
            AXObserverAddNotification(observer, window, kAXWindowResizedNotification as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
        return true
    }

    fileprivate func handle(_ window: AXUIElement, _ notification: String) {
        if notification == kAXWindowCreatedNotification {
            var pid: pid_t = 0
            if AXUIElementGetPid(window, &pid) == .success, let observer = observers[pid] {
                AXObserverAddNotification(observer, window, kAXWindowResizedNotification as CFString, nil)
            }
        }
        schedule([window])
    }

    /// Trims every observed app's windows, e.g. after Shelf's top edge moved up.
    func fenceAll() {
        guard Self.isTrusted else { return }
        schedule(observers.keys.flatMap { Self.windows(of: AXUIElementCreateApplication($0)) })
    }

    /// Waits until the windows stop resizing (zoom and tiling animate) and the mouse button is up
    /// (so a live resize isn't fought), then trims them all at once.
    private func schedule(_ windows: [AXUIElement]) {
        for window in windows where !pending.contains(window) { pending.append(window) }
        flushTask?.cancel()
        flushTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            while !Task.isCancelled && NSEvent.pressedMouseButtons & 1 != 0 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }
            let windows = pending
            pending = []
            let now = Date()
            trimmed = trimmed.filter { now.timeIntervalSince($0.value) < 1 }
            for window in windows where trimmed[window] == nil {
                if fence(window) { trimmed[window] = now }
            }
        }
    }

    /// Trims the window's height so its bottom edge meets Shelf's top edge. Returns whether it did.
    private func fence(_ window: AXUIElement) -> Bool {
        guard let fence = DockController.shared.fence,
              Self.value(window, kAXSubroleAttribute) as String? == kAXStandardWindowSubrole,
              Self.value(window, "AXFullScreen") as Bool? != true,
              let origin = Self.point(window, kAXPositionAttribute),
              let size = Self.size(window, kAXSizeAttribute) else { return false }
        // Accessibility uses a top-left origin on the primary screen.
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let fenceY = primaryHeight - fence.top
        let left = fence.screen.minX, right = fence.screen.maxX
        guard origin.x < right, origin.x + size.width > left, // on Shelf's screen
              origin.y < fenceY, origin.y + size.height > fenceY + 1 else { return false }
        let height = fenceY - origin.y
        guard height >= Self.minHeight else { return false }
        var newSize = CGSize(width: size.width, height: height)
        guard let value = AXValueCreate(.cgSize, &newSize) else { return false }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
    }

    // MARK: Accessibility values

    private static func windows(of app: AXUIElement) -> [AXUIElement] {
        value(app, kAXWindowsAttribute) as [AXUIElement]? ?? []
    }

    private static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    private static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var point = CGPoint.zero
        guard let value = axValue(element, attribute), AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var size = CGSize.zero
        guard let value = axValue(element, attribute), AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }
}

/// Runs on the main run loop, where the observers' sources are added.
nonisolated private func fenceCallback(_ observer: AXObserver, _ element: AXUIElement,
                           _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    nonisolated(unsafe) let element = element // only ever used on the main thread
    let name = notification as String
    MainActor.assumeIsolated { WindowFence.shared.handle(element, name) }
}
