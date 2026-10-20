import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// Keeps Apple's Dock out of sight. Fully reversible.
/// The Dock process itself can't be removed: it also runs Mission Control, ⌘-Tab and Spaces.
///
/// Only Apple's Dock can reserve space at the bottom of the screen (NSScreen.visibleFrame),
/// which is what makes windows, zoom and tiling stop above it. So when Shelf stays visible,
/// Apple's Dock stays on too, trimmed to running apps and sized to Shelf's height, and Shelf
/// sits on top of it. When Shelf auto-hides, Apple's Dock auto-hides with a very long delay instead.
enum AppleDock {
    /// The user's intent; Shelf re-applies it if something (⌥⌘D, System Settings) undoes it.
    static let keepHiddenKey = "keepAppleDockHidden"
    /// The user's own values for the keys below, restored when Shelf lets go of Apple's Dock.
    private static let originalKey = "appleDockOriginal"
    private static let legacyAutoHideKey = "appleDockPreviousAutoHide"
    private static let managedKeys = ["autohide", "autohide-delay", "static-only", "magnification",
                                      "tilesize", "minimize-to-application"]
    private static let domain = "com.apple.dock" as CFString

    private static func dockValue(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, domain)
    }

    static var isSuppressed: Bool { UserDefaults.standard.bool(forKey: keepHiddenKey) }

    static func setSuppressed(_ suppressed: Bool) {
        UserDefaults.standard.set(suppressed, forKey: keepHiddenKey)
        apply()
    }

    /// Apple's Dock size whose reserved space just covers a Shelf bar of this tile size.
    static func tileSize(forShelfTile tile: Double) -> Int { min(128, max(16, Int(tile) - 2)) }

    /// Brings Apple's Dock settings in line with Shelf's, restarting the Dock only if something changed.
    static func apply() {
        CFPreferencesAppSynchronize(domain)
        let desired: [String: Any]
        if isSuppressed {
            let original = saveOriginalIfNeeded()
            var values = original
            if UserDefaults.standard.autoHide {
                values["autohide"] = true
                values["autohide-delay"] = 1000.0
            } else {
                values["autohide"] = false
                values["autohide-delay"] = nil
                values["static-only"] = true // running apps only, so it stays narrower than Shelf
                values["magnification"] = false
                values["tilesize"] = tileSize(forShelfTile: UserDefaults.standard.tileSize)
            }
            // Minimized windows go into their app's icon, which Shelf can bring back.
            values["minimize-to-application"] = true
            desired = values
        } else if let original = UserDefaults.standard.dictionary(forKey: originalKey) {
            desired = original
            UserDefaults.standard.removeObject(forKey: originalKey)
        } else {
            return
        }

        var changed = false
        for key in managedKeys {
            let current = dockValue(key) as? NSObject
            let wanted = desired[key] as? NSObject
            guard current != wanted else { continue }
            CFPreferencesSetAppValue(key as CFString, wanted, domain)
            changed = true
        }
        guard changed else { return }
        CFPreferencesAppSynchronize(domain)
        restartDock()
    }

    private static func saveOriginalIfNeeded() -> [String: Any] {
        if let saved = UserDefaults.standard.dictionary(forKey: originalKey) { return saved }
        var original: [String: Any] = [:]
        for key in managedKeys { original[key] = dockValue(key) }
        // Older Shelf builds hid the Dock and only remembered the auto-hide setting.
        if let legacy = UserDefaults.standard.object(forKey: legacyAutoHideKey) as? Bool {
            original["autohide"] = legacy
            original["autohide-delay"] = nil
            original["minimize-to-application"] = nil
            UserDefaults.standard.removeObject(forKey: legacyAutoHideKey)
        }
        UserDefaults.standard.set(original, forKey: originalKey)
        return original
    }

    /// Checks every few seconds and re-applies if something (or a Shelf setting) changed.
    static func startEnforcing() {
        Task {
            while !Task.isCancelled {
                apply()
                DockController.shared.screenParametersChanged()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private static func restartDock() {
        let killall = Process()
        killall.executableURL = URL(filePath: "/usr/bin/killall")
        killall.arguments = ["Dock"]
        try? killall.run()
    }
}

/// Launches Shelf at login with a LaunchAgent in ~/Library/LaunchAgents, which also
/// relaunches it if it crashes (KeepAlive on unsuccessful exit). Quitting normally keeps it quit.
/// A plain user agent (rather than SMAppService) isn't pinned to one signed build, so rebuilds just work.
enum LaunchAtLogin {
    static let label = "local.shelf.app"
    private static let didSetUpKey = "didEnableLaunchAgentByDefault"
    private static var plistURL: URL {
        URL.homeDirectory.appending(path: "Library/LaunchAgents/\(label).plist")
    }
    private static var domain: String { "gui/\(getuid())" }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path(percentEncoded: false)) }
    /// Set by the agent plist, so we know launchd is supervising this process.
    static var isRunningUnderAgent: Bool { ProcessInfo.processInfo.environment["SHELF_AGENT"] != nil }

    static func set(_ enabled: Bool) {
        if enabled {
            writePlist()
            launchctl(["bootstrap", domain, plistURL.path(percentEncoded: false)])
            if !isRunningUnderAgent { exit(0) } // RunAtLoad starts the supervised copy
        } else {
            try? FileManager.default.removeItem(at: plistURL)
            // Booting out stops the supervised process (possibly this one), so do it last.
            launchctl(["bootout", "\(domain)/\(label)"])
        }
    }

    /// On by default, since Shelf replaces the Dock.
    static func enableByDefaultOnce() {
        guard !UserDefaults.standard.bool(forKey: didSetUpKey) else { return }
        UserDefaults.standard.set(true, forKey: didSetUpKey)
        set(true)
    }

    /// A copy started by Finder/`open` isn't supervised; let launchd start the real one.
    static func handOffToAgentIfNeeded() {
        guard isEnabled, !isRunningUnderAgent else { return }
        writePlist() // keeps the program path current if the app moved
        launchctl(["bootstrap", domain, plistURL.path(percentEncoded: false)]) // no-op error if loaded
        launchctl(["kickstart", "\(domain)/\(label)"], wait: false)
        exit(0)
    }

    private static func writePlist() {
        let plist: [String: Any] = [
            "Label": label,
            "Program": Bundle.main.executablePath ?? "",
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 5,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "EnvironmentVariables": ["SHELF_AGENT": "1"],
        ]
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: plistURL, options: .atomic)
        }
    }

    private static func launchctl(_ args: [String], wait: Bool = true) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = args
        process.standardError = FileHandle.nullDevice
        try? process.run()
        if wait { process.waitUntilExit() }
    }

}

/// Only one Shelf at a time (launchd and `open` can both start one).
enum SingleInstance {
    static func exitIfAlreadyRunning() {
        let me = NSRunningApplication.current
        func others() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .filter { $0.processIdentifier != me.processIdentifier && !$0.isTerminated }
        }
        // The supervised copy gives a handing-off copy a moment to exit.
        if LaunchAtLogin.isRunningUnderAgent {
            for _ in 0..<15 where !others().isEmpty { Thread.sleep(forTimeInterval: 0.2) }
        }
        if !others().isEmpty { exit(0) }
    }
}

/// System-wide ⌃⌥D to show the dock. Carbon hot keys need no Accessibility permission.
enum GlobalHotKey {
    private static var ref: EventHotKeyRef?

    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { DockController.shared.toggle() }
            }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x53484C46), id: 1) // 'SHLF'
        RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &ref)
    }
}
