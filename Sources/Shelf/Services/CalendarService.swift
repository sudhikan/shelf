import AppKit
import EventKit

nonisolated struct EventItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    let color: NSColor
    let url: URL?
}

nonisolated struct ReminderItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let due: Date?
    let color: NSColor
}

/// Upcoming events and reminders from EventKit (the same data as Calendar and Reminders).
@Observable
final class CalendarService {
    static let shared = CalendarService()

    enum Access { case unknown, granted, denied }

    private(set) var eventAccess: Access = .unknown
    private(set) var reminderAccess: Access = .unknown
    private(set) var events: [EventItem] = []
    private(set) var reminders: [ReminderItem] = []

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        eventAccess = Self.access(EKEventStore.authorizationStatus(for: .event))
        reminderAccess = Self.access(EKEventStore.authorizationStatus(for: .reminder))
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { CalendarService.shared.reload() }
        }
        Task {
            while !Task.isCancelled {
                if DockStore.shared.hasWidget(.calendar) { reload() }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func requestAccess() async {
        let events = (try? await store.requestFullAccessToEvents()) ?? false
        let reminders = (try? await store.requestFullAccessToReminders()) ?? false
        eventAccess = events ? .granted : .denied
        reminderAccess = reminders ? .granted : .denied
        reload()
    }

    private static func access(_ status: EKAuthorizationStatus) -> Access {
        switch status {
        case .fullAccess: .granted
        case .notDetermined: .unknown
        default: .denied
        }
    }

    func reload() {
        if eventAccess == .granted {
            let start = Calendar.current.startOfDay(for: .now)
            let end = Calendar.current.date(byAdding: .day, value: 14, to: start)!
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            events = store.events(matching: predicate)
                .filter { $0.endDate > .now }
                .sorted { $0.startDate < $1.startDate }
                .map {
                    EventItem(id: $0.calendarItemIdentifier + "\($0.startDate.timeIntervalSince1970)",
                              title: ($0.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : $0.title!,
                              start: $0.startDate, end: $0.endDate, isAllDay: $0.isAllDay,
                              location: $0.location, color: $0.calendar.color, url: $0.url)
                }
        }
        if reminderAccess == .granted {
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            store.fetchReminders(matching: predicate, completion: Self.remindersFetched)
        }
    }

    /// EventKit calls this on a background queue, so it must not touch main-actor state directly.
    private nonisolated static func remindersFetched(_ result: [EKReminder]?) {
        let items = (result ?? []).map {
            ReminderItem(id: $0.calendarItemIdentifier, title: $0.title ?? "",
                         due: $0.dueDateComponents?.date, color: $0.calendar.color)
        }
        .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        Task { @MainActor in CalendarService.shared.reminders = items }
    }

    /// Next timed event that hasn't ended, for the compact view.
    var nextEvent: EventItem? {
        events.first { !$0.isAllDay && $0.end > .now }
    }

    func eventCount(on day: Date) -> Int {
        events.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }.count
    }

    func complete(_ reminder: ReminderItem) {
        guard let item = store.calendarItem(withIdentifier: reminder.id) as? EKReminder else { return }
        item.isCompleted = true
        try? store.save(item, commit: true)
        reminders.removeAll { $0.id == reminder.id }
    }
}
