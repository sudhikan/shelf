import SwiftUI

/// A city the user follows: its display name plus its time zone ("Mumbai" → Asia/Kolkata).
struct WorldClock: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var zone: String
    var detail: String = ""     // "Maharashtra, India"

    var timeZone: TimeZone? { TimeZone(identifier: zone) }
}

@Observable
final class WorldClockStore {
    static let shared = WorldClockStore()
    private static let key = "worldClocks"
    private static let legacyKey = "worldClockZones"

    var clocks: [WorldClock] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(clocks), forKey: Self.key) }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([WorldClock].self, from: data) {
            clocks = saved
        } else {
            // Earlier builds stored bare zone IDs.
            let zones = UserDefaults.standard.stringArray(forKey: Self.legacyKey) ?? ["Europe/London", "Asia/Kolkata", "Asia/Tokyo"]
            clocks = zones.map { WorldClock(name: Self.city($0), zone: $0) }
        }
    }

    func contains(_ clock: WorldClock) -> Bool {
        clocks.contains { $0.name == clock.name && $0.zone == clock.zone }
    }

    func add(_ clock: WorldClock) { if !contains(clock) { clocks.append(clock) } }
    func remove(_ id: UUID) { clocks.removeAll { $0.id == id } }

    func move(_ id: UUID, before target: UUID) {
        guard id != target, let from = clocks.firstIndex(where: { $0.id == id }) else { return }
        let clock = clocks.remove(at: from)
        clocks.insert(clock, at: clocks.firstIndex { $0.id == target } ?? clocks.count)
    }

    /// Cities by name from Open-Meteo's geocoder (which includes each city's time zone),
    /// plus matching macOS time-zone IDs so search still works offline.
    static func search(_ query: String) async -> [WorldClock] {
        var results: [WorldClock] = []
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: query), .init(name: "count", value: "8")]
        if let (data, _) = try? await URLSession.shared.data(from: c.url!),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let found = root["results"] as? [[String: Any]] {
            results = found.compactMap { r in
                guard let name = r["name"] as? String, let zone = r["timezone"] as? String,
                      TimeZone(identifier: zone) != nil else { return nil }
                let detail = [r["admin1"] as? String, r["country"] as? String].compactMap { $0 }.joined(separator: ", ")
                return WorldClock(name: name, zone: zone, detail: detail)
            }
        }
        let offline = TimeZone.knownTimeZoneIdentifiers
            .filter { $0.replacingOccurrences(of: "_", with: " ").localizedCaseInsensitiveContains(query) }
            .prefix(4)
            .map { WorldClock(name: city($0), zone: $0, detail: $0) }
        for clock in offline where !results.contains(where: { $0.name == clock.name && $0.zone == clock.zone }) {
            results.append(clock)
        }
        return results
    }

    /// "America/New_York" → "New York"
    static func city(_ id: String) -> String {
        (id.split(separator: "/").last.map(String.init) ?? id).replacingOccurrences(of: "_", with: " ")
    }

    /// "+5:30" style offset from the local time zone, or "Same time".
    static func offset(_ zone: TimeZone, at date: Date) -> String {
        let diff = zone.secondsFromGMT(for: date) - TimeZone.current.secondsFromGMT(for: date)
        guard diff != 0 else { return "Same time" }
        let hours = abs(diff) / 3600, minutes = (abs(diff) % 3600) / 60
        return (diff > 0 ? "+" : "−") + (minutes == 0 ? "\(hours)h" : "\(hours):\(String(format: "%02d", minutes))")
    }

    static func isNight(_ zone: TimeZone, at date: Date) -> Bool {
        var calendar = Calendar.current
        calendar.timeZone = zone
        let hour = calendar.component(.hour, from: date)
        return hour < 6 || hour >= 19
    }
}

struct WorldClockCompact: View {
    @AppStorage(SettingsKey.tileSize) private var tileSize = SettingsDefault.tileSize
    private var store: WorldClockStore { .shared }

    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: 10) {
                if store.clocks.isEmpty {
                    Image(systemName: "globe").font(.system(size: tileSize * 0.42)).frame(width: tileSize * 0.8)
                }
                ForEach(store.clocks.prefix(3)) { clock in
                    if let zone = clock.timeZone {
                        VStack(alignment: .center, spacing: 0) {
                            Text(clock.name)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(context.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone)))
                                .font(.system(size: 13, weight: .semibold))
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                        .fixedSize()
                    }
                }
            }
        }
    }
}

struct WorldClockExpanded: View {
    @State private var query = ""
    @State private var results: [WorldClock] = []
    @State private var searching = false
    private var store: WorldClockStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetHeader(title: "World Clocks", symbol: "globe")

            TimelineView(.everyMinute) { context in
                VStack(spacing: 0) {
                    ForEach(store.clocks) { clock in
                        if let zone = clock.timeZone {
                            ClockRow(clock: clock, zone: zone, date: context.date)
                            if clock.id != store.clocks.last?.id { Divider() }
                        }
                    }
                }
            }
            Text("The dock shows the first three. Drag rows to reorder.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Add a city (e.g. Mumbai, Bengaluru, Paris)", text: $query)
                    .textFieldStyle(.roundedBorder)
                if searching { ProgressView().controlSize(.small) }
            }
            if query.count >= 2, !searching, results.isEmpty {
                Text("No cities found for “\(query)”").font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(results) { clock in
                    SearchResultRow(clock: clock, added: store.contains(clock)) {
                        store.add(clock)
                        query = ""
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 340)
        .task(id: query) {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard text.count >= 2 else { results = []; return }
            try? await Task.sleep(for: .milliseconds(300)) // debounce typing
            guard !Task.isCancelled else { return }
            searching = true
            let found = await WorldClockStore.search(text)
            guard !Task.isCancelled else { return }
            results = found
            searching = false
        }
    }
}

private struct SearchResultRow: View {
    let clock: WorldClock
    let added: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(clock.name)
                Text(clock.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if added {
                Label("Added", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
            } else if let zone = clock.timeZone {
                Text(Date.now.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone)))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(hovering && !added ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 5))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if !added { action() } }
    }
}

private struct ClockRow: View {
    let clock: WorldClock
    let zone: TimeZone
    let date: Date
    @State private var hovering = false

    var body: some View {
        HStack {
            Image(systemName: WorldClockStore.isNight(zone, at: date) ? "moon.fill" : "sun.max.fill")
                .foregroundStyle(WorldClockStore.isNight(zone, at: date) ? .indigo : .orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(clock.name).font(.body)
                Text("\(dayLabel) · \(WorldClockStore.offset(zone, at: date))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone)))
                .font(.title3.weight(.medium))
                .monospacedDigit()
            if hovering {
                Button { WorldClockStore.shared.remove(clock.id) } label: { Image(systemName: "minus.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(object: clock.id.uuidString as NSString) }
        .onDrop(of: [.plainText], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: NSString.self) { object, _ in
                guard let text = object as? String, let source = UUID(uuidString: text) else { return }
                let target = clock.id
                Task { @MainActor in WorldClockStore.shared.move(source, before: target) }
            }
            return true
        }
    }

    private var dayLabel: String {
        var other = Calendar.current
        other.timeZone = zone
        let theirs = other.dateComponents([.year, .month, .day], from: date)
        let ours = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let a = Calendar.current.date(from: theirs), let b = Calendar.current.date(from: ours) else { return "Today" }
        switch Calendar.current.dateComponents([.day], from: b, to: a).day ?? 0 {
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default: return "Today"
        }
    }
}
