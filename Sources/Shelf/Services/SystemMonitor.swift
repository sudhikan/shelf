import Darwin
import Foundation
import IOKit.ps

/// CPU, memory, network, battery and disk, sampled every 2 seconds from Mach/IOKit.
@Observable
final class SystemMonitor {
    static let shared = SystemMonitor()

    struct Battery { let percent: Int; let charging: Bool; let onAC: Bool; let minutesLeft: Int? }

    private(set) var cpu: Double = 0                 // 0...1
    private(set) var cpuHistory: [Double] = []
    private(set) var memoryUsed: UInt64 = 0
    let memoryTotal = ProcessInfo.processInfo.physicalMemory
    private(set) var downBytesPerSec: Double = 0
    private(set) var upBytesPerSec: Double = 0
    private(set) var battery: Battery?
    private(set) var diskFree: Int64 = 0
    private(set) var diskTotal: Int64 = 0

    var memory: Double { memoryTotal == 0 ? 0 : Double(memoryUsed) / Double(memoryTotal) }
    var thermal: ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }

    @ObservationIgnored private var lastTicks: (busy: UInt64, total: UInt64)?
    @ObservationIgnored private var lastNet: (down: UInt64, up: UInt64, at: Date)?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var tick = 0

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        Task {
            while !Task.isCancelled {
                if DockStore.shared.hasWidget(.system) { sample() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func sample() {
        sampleCPU()
        sampleMemory()
        sampleNetwork()
        if tick % 15 == 0 { // every 30 s
            sampleBattery()
            sampleDisk()
        }
        tick += 1
    }

    private func sampleCPU() {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let user = UInt64(load.cpu_ticks.0), system = UInt64(load.cpu_ticks.1)
        let idle = UInt64(load.cpu_ticks.2), nice = UInt64(load.cpu_ticks.3)
        let busy = user + system + nice, total = busy + idle
        if let last = lastTicks, total > last.total {
            cpu = Double(busy - last.busy) / Double(total - last.total)
            cpuHistory.append(cpu)
            if cpuHistory.count > 60 { cpuHistory.removeFirst() }
        }
        lastTicks = (busy, total)
    }

    private func sampleMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let page = UInt64(getpagesize())
        // Same definition as Activity Monitor's "Memory Used": app + wired + compressed.
        let app = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
        memoryUsed = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }

    private func sampleNetwork() {
        var down: UInt64 = 0, up: UInt64 = 0
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return }
        defer { freeifaddrs(addrs) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            let name = String(cString: ifa.pointee.ifa_name)
            if ifa.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), !name.hasPrefix("lo"),
               let data = ifa.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                down += UInt64(data.pointee.ifi_ibytes)
                up += UInt64(data.pointee.ifi_obytes)
            }
            cursor = ifa.pointee.ifa_next
        }
        let now = Date.now
        if let last = lastNet {
            let dt = now.timeIntervalSince(last.at)
            if dt > 0 {
                // 32-bit interface counters can wrap; treat a decrease as no traffic.
                downBytesPerSec = down >= last.down ? Double(down - last.down) / dt : 0
                upBytesPerSec = up >= last.up ? Double(up - last.up) / dt : 0
            }
        }
        lastNet = (down, up, now)
    }

    private func sampleBattery() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { battery = nil; return }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let onAC = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let minutes = (charging ? d[kIOPSTimeToFullChargeKey] : d[kIOPSTimeToEmptyKey]) as? Int
            battery = Battery(percent: current * 100 / max, charging: charging, onAC: onAC,
                              minutesLeft: (minutes ?? -1) > 0 ? minutes : nil)
            return
        }
        battery = nil
    }

    private func sampleDisk() {
        let values = try? URL(filePath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        diskFree = values?.volumeAvailableCapacityForImportantUsage ?? 0
        diskTotal = Int64(values?.volumeTotalCapacity ?? 0)
    }
}

extension Double {
    /// Bytes/second → "1.2 MB/s"
    var rateString: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file) + "/s"
    }
}
