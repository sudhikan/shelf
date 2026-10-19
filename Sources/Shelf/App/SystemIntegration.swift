import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// Hides Apple's Dock by making it auto-hide with a very long delay. Fully reversible.
/// The Dock process itself can't be removed: it also runs Mission Control, ⌘-Tab and Spaces.
enum AppleDock {
    private static let savedAutoHideKey = "appleDockPreviousAutoHide"
    /// The user's intent; Shelf re-applies it if something (⌥⌘D, System Settings) undoes it.
    static let keepHiddenKey = "keepAppleDockHidden"

    private static func dockValue(_ key: String) -> Any? {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        return CFPreferencesCopyAppValue(key as CFString, "com.apple.dock" as CFString)
    }

    static var isSuppressed: Bool {
        let delay = (dockValue("autohide-delay") as? NSNumber)?.doubleValue ?? 0
        let autohide = (dockValue("autohide") as? NSNumber)?.boolValue ?? false
        return autohide && delay >= 100
    }

    static func setSuppressed(_ suppressed: Bool) {
        UserDefaults.standard.set(suppressed, forKey: keepHiddenKey)
        guard suppressed != isSuppressed else { return }
        if suppressed {
            if (dockValue("autohide-delay") as? NSNumber)?.doubleValue ?? 0 < 100 {
                UserDefaults.standard.set((dockValue("autohide") as? NSNumber)?.boolValue ?? false, forKey: savedAutoHideKey)
            }
            run(["write", "com.apple.dock", "autohide", "-bool", "true"])
            run(["write", "com.apple.dock", "autohide-delay", "-float", "1000"])
            // Minimized windows go into their app's icon, which Shelf can bring back.
            run(["write", "com.apple.dock", "minimize-to-application", "-bool", "true"])
        } else {
            let previous = UserDefaults.standard.bool(forKey: savedAutoHideKey)
            run(["delete", "com.apple.dock", "autohide-delay"])
            run(["write", "com.apple.dock", "autohide", "-bool", previous ? "true" : "false"])
        }
        restartDock()
    }

    /// Checks every few seconds and re-hides Apple's Dock if it came back.
    static func startEnforcing() {
        Task {
            while !Task.isCancelled {
                if UserDefaults.standard.bool(forKey: keepHiddenKey), !isSuppressed {
                    setSuppressed(true)
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private static func restartDock() {
        let killall = Process()
        killall.executableURL = URL(filePath: "/usr/bin/killall")
        killall.arguments = ["Dock"]
        try? killall.run()
    }

    private static func run(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/defaults")
        process.arguments = args
        try? process.run()
        process.waitUntilExit()
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
