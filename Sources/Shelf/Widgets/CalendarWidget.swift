import SwiftUI

struct CalendarCompact: View {
    @AppStorage(SettingsKey.tileSize) private var tileSize = SettingsDefault.tileSize
    private var service: CalendarService { .shared }

    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: 8) {
                VStack(spacing: -2) {
                    Text(context.date, format: .dateTime.weekday(.abbreviated))
                        .font(.system(size: tileSize * 0.2, weight: .semibold))
                        .foregroundStyle(.red)
                        .textCase(.uppercase)
                    Text(context.date, format: .dateTime.day())
                        .font(.system(size: tileSize * 0.48, weight: .regular))
                        .monospacedDigit()
                }
                .frame(width: tileSize * 0.8)

                if let event = service.nextEvent {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(relative(event, now: context.date))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: tileSize * 1.9, alignment: .leading)
                }
            }
        }
        .onAppear { service.start() }
    }

    private func relative(_ event: EventItem, now: Date) -> String {
        if event.start <= now { return "Now · until \(event.end.formatted(date: .omitted, time: .shortened))" }
        let minutes = Int(event.start.timeIntervalSince(now) / 60)
        if minutes < 60 { return "in \(minutes) min" }
        if Calendar.current.isDateInToday(event.start) {
            return event.start.formatted(date: .omitted, time: .shortened)
        }
        return event.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

struct CalendarExpanded: View {
    @State private var month = Calendar.current.startOfMonth(for: .now)
    private var service: CalendarService { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetHeader(title: month.formatted(.dateTime.month(.wide).year()), symbol: "calendar") {
                HStack(spacing: 2) {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    Button("Today") { month = Calendar.current.startOfMonth(for: .now) }
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }
                }
                .buttonStyle(.borderless)
            }
            MonthGrid(month: month)

            Divider()

            if service.eventAccess != .granted {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shelf needs access to show your events and reminders.")
                        .foregroundStyle(.secondary)
                    Button("Allow Calendar Access") { Task { await service.requestAccess() } }
                    if service.eventAccess == .denied {
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        }
                        .buttonStyle(.link)
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Agenda(events: service.events)
                        if !service.reminders.isEmpty {
                            RemindersList(reminders: Array(service.reminders.prefix(8)))
                        }
                    }
                }
                .frame(maxHeight: 280)
            }

            HStack {
                Button("Open Calendar") { NSWorkspace.shared.open(URL(filePath: "/System/Applications/Calendar.app")) }
                Spacer()
                Button("Open Reminders") { NSWorkspace.shared.open(URL(filePath: "/System/Applications/Reminders.app")) }
            }
            .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { service.start(); service.reload() }
    }

    private func shift(_ months: Int) {
        month = Calendar.current.date(byAdding: .month, value: months, to: month)!
    }
}

private struct MonthGrid: View {
    let month: Date
    private let calendar = Calendar.current

    var body: some View {
        let days = gridDays()
        let symbols = shiftedWeekdaySymbols()
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                ForEach(symbols.indices, id: \.self) { i in
                    Text(symbols[i]).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            ForEach(0..<days.count / 7, id: \.self) { row in
                GridRow {
                    ForEach(0..<7, id: \.self) { col in
                        DayCell(day: days[row * 7 + col], month: month)
                    }
                }
            }
        }
    }

    private func gridDays() -> [Date] {
        let firstWeekday = calendar.component(.weekday, from: month)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -leading, to: month)!
        let count = calendar.range(of: .day, in: .month, for: month)!.count
        let cells = Int(ceil(Double(leading + count) / 7)) * 7
        return (0..<cells).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }

    private func shiftedWeekdaySymbols() -> [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }
}

private struct DayCell: View {
    let day: Date
    let month: Date

    var body: some View {
        let calendar = Calendar.current
        let isToday = calendar.isDateInToday(day)
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let hasEvents = CalendarService.shared.eventCount(on: day) > 0
        VStack(spacing: 1) {
            Text(day, format: .dateTime.day())
                .font(.system(size: 12, weight: isToday ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(isToday ? AnyShapeStyle(.white) : inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 24, height: 24)
                .background(isToday ? Color.red : .clear, in: Circle())
            Circle().fill(.secondary).frame(width: 3, height: 3).opacity(hasEvents ? 1 : 0)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct Agenda: View {
    let events: [EventItem]

    var body: some View {
        let grouped = Dictionary(grouping: events.prefix(25)) { Calendar.current.startOfDay(for: $0.start) }
        VStack(alignment: .leading, spacing: 10) {
            if events.isEmpty {
                Text("No upcoming events").foregroundStyle(.secondary)
            }
            ForEach(grouped.keys.sorted(), id: \.self) { day in
                VStack(alignment: .leading, spacing: 4) {
                    Text(dayTitle(day)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(grouped[day]!) { event in
                        HStack(alignment: .top, spacing: 8) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(nsColor: event.color))
                                .frame(width: 3, height: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(event.title).font(.callout).lineLimit(1)
                                Text(timeText(event)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "TODAY" }
        if Calendar.current.isDateInTomorrow(day) { return "TOMORROW" }
        return day.formatted(.dateTime.weekday(.wide).month().day()).uppercased()
    }

    private func timeText(_ event: EventItem) -> String {
        var text = event.isAllDay ? "All day"
            : "\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))"
        if let location = event.location, !location.isEmpty { text += " · \(location)" }
        return text
    }
}

private struct RemindersList: View {
    let reminders: [ReminderItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("REMINDERS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(reminders) { reminder in
                HStack(spacing: 8) {
                    Button { CalendarService.shared.complete(reminder) } label: {
                        Image(systemName: "circle").foregroundStyle(Color(nsColor: reminder.color))
                    }
                    .buttonStyle(.plain)
                    Text(reminder.title).font(.callout).lineLimit(1)
                    Spacer()
                    if let due = reminder.due {
                        Text(due, format: .dateTime.month(.abbreviated).day())
                            .font(.caption)
                            .foregroundStyle(due < .now ? .red : .secondary)
                    }
                }
            }
        }
    }
}

extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date))!
    }
}
