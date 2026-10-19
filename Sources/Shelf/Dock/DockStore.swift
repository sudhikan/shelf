import AppKit

enum WidgetKind: String, Codable, CaseIterable, Identifiable {
    case calendar, timer, clipboard, stocks, quickActions
    case weather, nowPlaying, worldClock, system, notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: "Calendar"
        case .timer: "Timers"
        case .clipboard: "Clipboard"
        case .stocks: "Stocks"
        case .quickActions: "Quick Actions"
        case .weather: "Weather"
        case .nowPlaying: "Now Playing"
        case .worldClock: "World Clocks"
        case .system: "System"
        case .notes: "Quick Notes"
        }
    }

    var symbol: String {
        switch self {
        case .calendar: "calendar"
        case .timer: "timer"
        case .clipboard: "doc.on.clipboard"
        case .stocks: "chart.line.uptrend.xyaxis"
        case .quickActions: "bolt.fill"
        case .weather: "cloud.sun.fill"
        case .nowPlaying: "music.note"
        case .worldClock: "globe"
        case .system: "cpu"
        case .notes: "note.text"
        }
    }
}

struct WidgetItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: WidgetKind
}

/// Everything the user arranges in the dock. Saved as JSON in Application Support.
struct DockConfig: Codable {
    var pinnedApps: [String] = []   // app bundle paths
    var widgets: [WidgetItem] = []
    var folders: [String] = []      // folder paths
}

@Observable
final class DockStore {
    static let shared = DockStore()

    var config: DockConfig {
        didSet { save() }
    }

    private static let fileURL: URL = {
        let dir = URL.applicationSupportDirectory.appending(path: "Shelf", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "dock.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let config = try? JSONDecoder().decode(DockConfig.self, from: data) {
            self.config = config
            // Drop duplicate widget kinds (keep the first of each).
            var seen = Set<WidgetKind>()
            let unique = config.widgets.filter { seen.insert($0.kind).inserted }
            if unique.count != config.widgets.count { self.config.widgets = unique }
            if config.pinnedApps.count > Self.absoluteMaxApps {
                self.config.pinnedApps = Array(config.pinnedApps.prefix(Self.absoluteMaxApps))
            }
        } else {
            self.config = Self.importFromAppleDock()
            save()
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(config).write(to: Self.fileURL, options: .atomic)
    }

    // MARK: Apps

    /// App icons per row; the rest of the bar is for widgets.
    /// One row holds 8; the two-row grid is 5 × 2.
    static var appsPerRow: Int { UserDefaults.standard.appRows == 2 ? 5 : 8 }
    /// Hard cap on app icons (kept + running): 8 in one row, 10 in two.
    static var maxApps: Int { appsPerRow * UserDefaults.standard.appRows }
    static let absoluteMaxApps = 16

    var canPinMore: Bool { config.pinnedApps.count < Self.maxApps }
    /// Kept apps that fit with the current row setting (extras are kept, just not shown).
    var visiblePinnedApps: [String] { Array(config.pinnedApps.prefix(Self.maxApps)) }

    func isPinned(_ path: String) -> Bool { config.pinnedApps.contains(path) }

    func pin(_ path: String, at index: Int? = nil) {
        guard !isPinned(path), canPinMore else { return }
        config.pinnedApps.insert(path, at: min(index ?? config.pinnedApps.count, config.pinnedApps.count))
    }

    func unpin(_ path: String) {
        config.pinnedApps.removeAll { $0 == path }
    }

    /// Moves (or pins) `path` so it sits just before `target`.
    func movePinned(_ path: String, before target: String) {
        guard path != target else { return }
        config.pinnedApps.removeAll { $0 == path }
        let index = config.pinnedApps.firstIndex(of: target) ?? config.pinnedApps.count
        config.pinnedApps.insert(path, at: index)
    }

    /// Moves a pinned app to `index` among the other pinned apps.
    func movePinned(_ path: String, to index: Int) {
        guard let from = config.pinnedApps.firstIndex(of: path) else { return }
        var apps = config.pinnedApps
        apps.remove(at: from)
        apps.insert(path, at: min(max(index, 0), apps.count))
        if apps != config.pinnedApps { config.pinnedApps = apps }
    }

    /// Moves a pinned app left (negative) or right (positive) by `steps` places.
    func movePinned(_ path: String, by steps: Int) {
        guard steps != 0, let from = config.pinnedApps.firstIndex(of: path) else { return }
        let to = min(max(from + steps, 0), config.pinnedApps.count - 1)
        guard to != from else { return }
        config.pinnedApps.remove(at: from)
        config.pinnedApps.insert(path, at: to)
    }

    // MARK: Widgets

    /// One of each widget kind at most.
    func hasWidget(_ kind: WidgetKind) -> Bool { config.widgets.contains { $0.kind == kind } }

    func addWidget(_ kind: WidgetKind) {
        guard !hasWidget(kind) else { return }
        config.widgets.append(WidgetItem(kind: kind))
    }

    /// Removing a widget also stops its background work (each service checks `hasWidget`).
    func removeWidget(_ id: UUID) {
        guard let item = config.widgets.first(where: { $0.id == id }) else { return }
        config.widgets.removeAll { $0.id == id }
        if item.kind == .timer { TimerService.shared.removeAll() }
    }

    /// Moves a widget to `index` among the other widgets.
    func moveWidget(_ id: UUID, to index: Int) {
        guard let from = config.widgets.firstIndex(where: { $0.id == id }) else { return }
        var widgets = config.widgets
        let item = widgets.remove(at: from)
        widgets.insert(item, at: min(max(index, 0), widgets.count))
        if widgets != config.widgets { config.widgets = widgets }
    }

    func moveWidget(_ id: UUID, before target: UUID) {
        guard id != target, let item = config.widgets.first(where: { $0.id == id }) else { return }
        config.widgets.removeAll { $0.id == id }
        let index = config.widgets.firstIndex { $0.id == target } ?? config.widgets.count
        config.widgets.insert(item, at: index)
    }

    // MARK: Folders

    func addFolder(_ path: String) {
        guard !config.folders.contains(path) else { return }
        config.folders.append(path)
    }

    func removeFolder(_ path: String) {
        config.folders.removeAll { $0 == path }
    }

    // MARK: First launch

    /// Seeds the dock with the apps and folders from Apple's Dock (read-only).
    private static func importFromAppleDock() -> DockConfig {
        let dock = UserDefaults(suiteName: "com.apple.dock")
        func paths(_ key: String) -> [String] {
            let items = dock?.array(forKey: key) as? [[String: Any]] ?? []
            return items.compactMap { item in
                guard let tile = item["tile-data"] as? [String: Any],
                      let file = tile["file-data"] as? [String: Any],
                      let urlString = file["_CFURLString"] as? String,
                      let url = URL(string: urlString) else { return nil }
                let path = url.path(percentEncoded: false)
                let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
                return FileManager.default.fileExists(atPath: trimmed) ? trimmed : nil
            }
        }
        var config = DockConfig()
        config.pinnedApps = Array((["/System/Library/CoreServices/Finder.app"] + paths("persistent-apps")).prefix(maxApps))
        config.folders = paths("persistent-others")
        config.widgets = [.calendar, .timer, .clipboard, .stocks, .quickActions].map { WidgetItem(kind: $0) }
        return config
    }
}
