import SwiftUI

struct TimerCompact: View {
    @AppStorage(SettingsKey.tileSize) private var tileSize = SettingsDefault.tileSize
    private var service: TimerService { .shared }

    var body: some View {
        if let timer = service.soonest {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = timer.remaining(at: context.date)
                HStack(spacing: 7) {
                    ProgressRing(progress: 1 - remaining / timer.duration, paused: !timer.isRunning)
                        .frame(width: tileSize * 0.55, height: tileSize * 0.55)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(remaining.clockString)
                            .font(.system(size: tileSize * 0.3, weight: .medium))
                            .monospacedDigit()
                        Text(timer.label)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(minWidth: tileSize * 1.1, alignment: .leading)
                }
            }
        } else {
            Image(systemName: "timer")
                .font(.system(size: tileSize * 0.45, weight: .light))
                .frame(width: tileSize * 0.8)
        }
    }
}

struct ProgressRing: View {
    let progress: Double
    var paused = false

    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.15), lineWidth: 3.5)
            Circle()
                .trim(from: 0, to: max(0.001, 1 - progress))
                .stroke(paused ? Color.secondary : Color.orange, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

struct TimerExpanded: View {
    @State private var customMinutes = 15
    private var service: TimerService { .shared }
    private let presets: [(String, Double)] = [("1m", 1), ("3m", 3), ("5m", 5), ("10m", 10), ("25m", 25), ("1h", 60)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetHeader(title: "Timers", symbol: "timer") {
                if service.timers.contains(where: \.isFinished) {
                    Button("Clear Finished") { service.clearFinished() }.buttonStyle(.link)
                }
            }

            HStack(spacing: 6) {
                ForEach(presets, id: \.0) { title, minutes in
                    Button(title) { service.start(minutes: minutes) }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                }
            }

            HStack {
                Stepper(value: $customMinutes, in: 1...600, step: customMinutes < 10 ? 1 : 5) {
                    Text("\(customMinutes) min").monospacedDigit().frame(width: 60, alignment: .leading)
                }
                Spacer()
                Button("Start") { service.start(minutes: Double(customMinutes)) }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }

            if !service.timers.isEmpty {
                Divider()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 8) {
                        ForEach(service.timers) { timer in
                            TimerRow(timer: timer, now: context.date)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

private struct TimerRow: View {
    let timer: DockTimer
    let now: Date
    private var service: TimerService { .shared }

    var body: some View {
        let remaining = timer.remaining(at: now)
        HStack(spacing: 10) {
            ProgressRing(progress: 1 - remaining / timer.duration, paused: !timer.isRunning)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(timer.isFinished ? "Done" : remaining.clockString)
                    .font(.title3.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(timer.isFinished ? .orange : .primary)
                Text(timer.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Group {
                if timer.isFinished {
                    Button { service.restart(timer.id) } label: { Image(systemName: "arrow.counterclockwise") }
                } else if timer.isRunning {
                    Button { service.pause(timer.id) } label: { Image(systemName: "pause.fill") }
                } else {
                    Button { service.resume(timer.id) } label: { Image(systemName: "play.fill") }
                }
                Button { service.remove(timer.id) } label: { Image(systemName: "xmark") }
            }
            .buttonStyle(.borderless)
            .font(.body)
        }
    }
}
