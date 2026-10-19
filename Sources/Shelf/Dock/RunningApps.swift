import AppKit

/// Live list of regular (Dock-visible) running apps, driven by NSWorkspace notifications.
@Observable
final class RunningApps {
    static let shared = RunningApps()

    private(set) var apps: [NSRunningApplication] = []
    private(set) var frontmostPID: pid_t?

    private init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in names {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RunningApps.shared.refresh() }
            }
        }
    }

    private func refresh() {
        apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleURL != nil
        }
        frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func app(at path: String) -> NSRunningApplication? {
        apps.first { $0.bundleURL?.path(percentEncoded: false).trimmingSuffix("/") == path }
    }

    /// Running apps that aren't pinned, in launch order.
    func unpinned(excluding pinned: [String]) -> [String] {
        let pinnedSet = Set(pinned)
        var seen = Set<String>()
        return apps.compactMap { app in
            guard let path = app.bundleURL?.path(percentEncoded: false).trimmingSuffix("/"),
                  !pinnedSet.contains(path), seen.insert(path).inserted else { return nil }
            return path
        }
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}

enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let image = cache[path] { return image }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 256, height: 256)
        cache[path] = image
        return image
    }
}

enum AppActions {
    static func displayName(_ path: String) -> String {
        FileManager.default.displayName(atPath: path).trimmingSuffix(".app")
    }

    /// Same behaviour as clicking in the Dock: launch, or activate + reopen.
    static func open(_ path: String) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: URL(filePath: path), configuration: config)
    }

    static func open(files: [URL], with appPath: String) {
        NSWorkspace.shared.open(files, withApplicationAt: URL(filePath: appPath),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
    }
}
