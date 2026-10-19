import Charts
import SwiftUI

struct SystemCompact: View {
    @AppStorage(SettingsKey.tileSize) private var tileSize = SettingsDefault.tileSize
    private var monitor: SystemMonitor { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MiniMeter(label: "CPU", value: monitor.cpu)
            MiniMeter(label: "MEM", value: monitor.memory)
            if let battery = monitor.battery {
                MiniMeter(label: "BAT", value: Double(battery.percent) / 100, color: battery.percent <= 20 ? .red : .green)
            }
        }
        .frame(width: tileSize * 1.7)
        .onAppear { monitor.start() }
    }
}

private struct MiniMeter: View {
    let label: String
    let value: Double
    var color: Color?

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)
            Meter(value: value, color: color ?? Meter.color(for: value))
                .frame(height: 5)
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 9, weight: .medium))
                .monospacedDigit()
                .frame(width: 26, alignment: .trailing)
        }
    }
}

struct Meter: View {
    let value: Double
    let color: Color

    static func color(for value: Double) -> Color {
        value > 0.85 ? .red : value > 0.6 ? .orange : .accentColor
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12))
                Capsule().fill(color).frame(width: max(3, geo.size.width * min(max(value, 0), 1)))
            }
        }
    }
}

struct SystemExpanded: View {
    private var monitor: SystemMonitor { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WidgetHeader(title: "System", symbol: "cpu") {
                Button("Activity Monitor") {
                    NSWorkspace.shared.open(URL(filePath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
                .buttonStyle(.link)
            }

            VStack(alignment: .leading, spacing: 4) {
                row("CPU", "\(Int((monitor.cpu * 100).rounded()))%")
                Chart(Array(monitor.cpuHistory.enumerated()), id: \.offset) { point in
                    AreaMark(x: .value("t", point.offset), y: .value("cpu", point.element))
                        .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.5), .accentColor.opacity(0.05)],
                                                         startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("t", point.offset), y: .value("cpu", point.element))
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                }
                .chartYScale(domain: 0...1)
                .chartXScale(domain: 0...59)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 50)
            }

            VStack(alignment: .leading, spacing: 4) {
                row("Memory", "\(bytes(monitor.memoryUsed)) of \(bytes(monitor.memoryTotal))")
                Meter(value: monitor.memory, color: Meter.color(for: monitor.memory)).frame(height: 6)
            }

            if monitor.diskTotal > 0 {
                let used = Double(monitor.diskTotal - monitor.diskFree) / Double(monitor.diskTotal)
                VStack(alignment: .leading, spacing: 4) {
                    row("Disk", "\(bytes(UInt64(monitor.diskFree))) free")
                    Meter(value: used, color: Meter.color(for: used)).frame(height: 6)
                }
            }

            HStack {
                Label(monitor.downBytesPerSec.rateString, systemImage: "arrow.down.circle")
                Spacer()
                Label(monitor.upBytesPerSec.rateString, systemImage: "arrow.up.circle")
            }
            .font(.callout)
            .monospacedDigit()

            if let battery = monitor.battery {
                HStack {
                    Image(systemName: battery.charging ? "battery.100.bolt" : batterySymbol(battery.percent))
                    Text("\(battery.percent)%")
                    Spacer()
                    Text(batteryDetail(battery)).foregroundStyle(.secondary)
                }
                .font(.callout)
            }

            if monitor.thermal == .serious || monitor.thermal == .critical {
                Label("Your Mac is running hot", systemImage: "thermometer.high").foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { monitor.start() }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.callout.weight(.semibold))
            Spacer()
            Text(value).font(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .memory)
    }

    private func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: "battery.0"
        case ..<38: "battery.25"
        case ..<63: "battery.50"
        case ..<88: "battery.75"
        default: "battery.100"
        }
    }

    private func batteryDetail(_ b: SystemMonitor.Battery) -> String {
        let time = b.minutesLeft.map { "\($0 / 60):\(String(format: "%02d", $0 % 60))" }
        if b.charging { return time.map { "\($0) until full" } ?? "Charging" }
        if b.onAC { return "On power adapter" }
        return time.map { "\($0) remaining" } ?? "On battery"
    }
}
