import AppKit
import IOKit.pwr_mgt

enum BuiltInAction: String, CaseIterable, Identifiable {
    case lockScreen, sleepDisplay, screenshot, darkMode, keepAwake, hideAll, emptyTrash, downloads

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lockScreen: "Lock Screen"
        case .sleepDisplay: "Sleep Display"
        case .screenshot: "Screenshot"
        case .darkMode: "Dark Mode"
        case .keepAwake: "Keep Awake"
        case .hideAll: "Hide All Apps"
        case .emptyTrash: "Empty Trash"
        case .downloads: "Downloads"
        }
    }

    var symbol: String {
        switch self {
        case .lockScreen: "lock.fill"
        case .sleepDisplay: "display"
        case .screenshot: "camera.viewfinder"
        case .darkMode: "circle.lefthalf.filled"
        case .keepAwake: "cup.and.saucer.fill"
        case .hideAll: "eye.slash"
        case .emptyTrash: "trash"
        case .downloads: "arrow.down.circle"
        }
    }
}

/// Runs built-in quick actions and the user's Shortcuts.
@Observable
final class QuickActionRunner {
    static let shared = QuickActionRunner()
    static let shortcutsKey = "quickActionShortcuts"

    private(set) var keepAwakeOn = false
    private(set) var availableShortcuts: [String] = []
    private(set) var running: String?
    var pinnedShortcuts: [String] {
        didSet { UserDefaults.standard.set(pinnedShortcuts, forKey: Self.shortcutsKey) }
    }

    @ObservationIgnored private var assertionID: IOPMAssertionID = 0

    private init() {
        pinnedShortcuts = UserDefaults.standard.stringArray(forKey: Self.shortcutsKey) ?? []
    }

    func isActive(_ action: BuiltInAction) -> Bool {
        switch action {
        case .keepAwake: keepAwakeOn
        case .darkMode: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        default: false
        }
    }

    func run(_ action: BuiltInAction) {
        switch action {
        case .lockScreen:
            Self.lockScreen()
        case .sleepDisplay:
            Self.launch("/usr/bin/pmset", ["displaysleepnow"])
        case .screenshot:
            NSWorkspace.shared.open(URL(filePath: "/System/Applications/Utilities/Screenshot.app"))
        case .darkMode:
            Self.appleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
        case .keepAwake:
            toggleKeepAwake()
        case .hideAll:
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app != .current {
                app.hide()
            }
        case .emptyTrash:
            Self.emptyTrash()
        case .downloads:
            NSWorkspace.shared.open(URL.downloadsDirectory)
        }
    }

    // MARK: Shortcuts

    func loadShortcuts() {
        Task {
            let output = await Self.output("/usr/bin/shortcuts", ["list"])
            availableShortcuts = output.split(separator: "\n").map(String.init).sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
        }
    }

    func runShortcut(_ name: String) {
        running = name
        Task {
            _ = await Self.output("/usr/bin/shortcuts", ["run", name])
            if running == name { running = nil }
        }
    }

    func toggleShortcutPinned(_ name: String) {
        if let i = pinnedShortcuts.firstIndex(of: name) { pinnedShortcuts.remove(at: i) } else { pinnedShortcuts.append(name) }
    }

    // MARK: Helpers

    private func toggleKeepAwake() {
        if keepAwakeOn {
            IOPMAssertionRelease(assertionID)
            keepAwakeOn = false
        } else {
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "Shelf Keep Awake" as CFString, &assertionID)
            keepAwakeOn = result == kIOReturnSuccess
        }
    }

    static func emptyTrash() {
        appleScript("tell application \"Finder\" to empty trash")
    }

    private static func lockScreen() {
        // SACLockScreenImmediate is what the Lock Screen menu item calls.
        typealias LockFn = @convention(c) () -> Int32
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let sym = dlsym(handle, "SACLockScreenImmediate") {
            _ = unsafeBitCast(sym, to: LockFn.self)()
        } else {
            launch("/usr/bin/pmset", ["displaysleepnow"])
        }
    }

    private static func appleScript(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("Shelf AppleScript error: \(error)") }
    }

    private static func launch(_ path: String, _ args: [String]) {
        try? Process.run(URL(filePath: path), arguments: args)
    }

    private nonisolated static func output(_ path: String, _ args: [String]) async -> String {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(filePath: path)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
            do { try process.run() } catch { continuation.resume(returning: "") }
        }
    }
}
