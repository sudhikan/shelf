import AppKit
import UserNotifications

struct DockTimer: Codable, Identifiable, Hashable {
    var id = UUID()
    var label: String
    var duration: TimeInterval
    /// Set while running.
    var endDate: Date?
    /// Set while paused.
    var pausedRemaining: TimeInterval?

    var isRunning: Bool { endDate != nil }
    var isFinished: Bool { endDate == nil && pausedRemaining == 0 }

    func remaining(at now: Date = .now) -> TimeInterval {
        if let endDate { return max(0, endDate.timeIntervalSince(now)) }
        return pausedRemaining ?? duration
    }
}

/// Countdown timers that survive relaunches. Alerts go through Notification Center.
@Observable
final class TimerService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TimerService()

    private(set) var timers: [DockTimer] = [] {
        didSet { save() }
    }

    @ObservationIgnored private var completionTasks: [UUID: Task<Void, Never>] = [:]

    private static let fileURL = URL.applicationSupportDirectory.appending(path: "Shelf/timers.json")

    private override init() {
        super.init()
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([DockTimer].self, from: data) {
            timers = saved
        }
        UNUserNotificationCenter.current().delegate = self
        for timer in timers where timer.isRunning { scheduleCompletion(timer) }
    }

    private func save() {
        try? JSONEncoder().encode(timers).write(to: Self.fileURL, options: .atomic)
    }

    var soonest: DockTimer? {
        timers.filter(\.isRunning).min { $0.endDate! < $1.endDate! }
            ?? timers.first { $0.pausedRemaining != nil && !$0.isFinished }
    }

    // MARK: Actions

    func start(minutes: Double, label: String? = nil) {
        let duration = minutes * 60
        var timer = DockTimer(label: label ?? Self.defaultLabel(duration), duration: duration)
        timer.endDate = .now + duration
        timers.insert(timer, at: 0)
        scheduleCompletion(timer)
        requestAuthorization()
    }

    func pause(_ id: UUID) {
        guard let i = index(id), let end = timers[i].endDate else { return }
        timers[i].pausedRemaining = max(1, end.timeIntervalSinceNow)
        timers[i].endDate = nil
        cancelCompletion(id)
    }

    func resume(_ id: UUID) {
        guard let i = index(id), let remaining = timers[i].pausedRemaining, remaining > 0 else { return }
        timers[i].endDate = .now + remaining
        timers[i].pausedRemaining = nil
        scheduleCompletion(timers[i])
    }

    func restart(_ id: UUID) {
        guard let i = index(id) else { return }
        timers[i].endDate = .now + timers[i].duration
        timers[i].pausedRemaining = nil
        scheduleCompletion(timers[i])
    }

    func remove(_ id: UUID) {
        cancelCompletion(id)
        timers.removeAll { $0.id == id }
    }

    func removeAll() {
        for timer in timers { cancelCompletion(timer.id) }
        timers.removeAll()
    }

    func clearFinished() {
        timers.removeAll(where: \.isFinished)
    }

    private func index(_ id: UUID) -> Int? { timers.firstIndex { $0.id == id } }

    private static func defaultLabel(_ duration: TimeInterval) -> String {
        let minutes = Int(duration / 60)
        return minutes >= 60 && minutes % 60 == 0 ? "\(minutes / 60) hr timer" : "\(minutes) min timer"
    }

    // MARK: Completion

    private func scheduleCompletion(_ timer: DockTimer) {
        cancelCompletion(timer.id)
        guard let end = timer.endDate else { return }

        let content = UNMutableNotificationContent()
        content.title = timer.label
        content.body = "Time's up"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, end.timeIntervalSinceNow), repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: timer.id.uuidString, content: content, trigger: trigger))

        let id = timer.id
        completionTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, let i = self.index(id) else { return }
            self.timers[i].endDate = nil
            self.timers[i].pausedRemaining = 0
            NSSound(named: "Glass")?.play()
            DockController.shared.reveal()
        }
    }

    private func cancelCompletion(_ id: UUID) {
        completionTasks.removeValue(forKey: id)?.cancel()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id.uuidString])
    }

    private func requestAuthorization() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

extension TimeInterval {
    /// 4:05 or 1:02:03
    var clockString: String {
        let total = Int(ceil(self))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
