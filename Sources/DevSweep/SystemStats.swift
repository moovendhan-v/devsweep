// CPU / battery / GPU readers are adapted from Mac Sai (https://github.com/iliyami/MacSai),
// Copyright (c) 2026, Mac Sai Contributors, BSD 3-Clause License.
import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.ps
import Observation
import UserNotifications

struct BatteryInfo: Sendable {
    var level: Double
    var isCharging: Bool
    var onAC: Bool
    var health: Double?
    var cycles: Int?
    var temperature: Double?
    var timeRemaining: Int?
}

struct ExternalVolume: Identifiable, Sendable {
    let id: String
    let name: String
    let url: URL
    let total: Int64
    let free: Int64
}

/// One day of network traffic, with a per-hour breakdown.
struct NetworkDay: Codable, Identifiable {
    var id: String { day }
    let day: String          // yyyy-MM-dd
    var down: Int64 = 0
    var up: Int64 = 0
    var hourlyDown = [Int64](repeating: 0, count: 24)
    var hourlyUp = [Int64](repeating: 0, count: 24)

    var total: Int64 { down + up }
    var date: Date { NetworkDay.formatter.date(from: day) ?? .now }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

struct AppTraffic: Identifiable, Hashable {
    let id: String
    let name: String
    let pid: Int32
    let bytesIn: Int64
    let bytesOut: Int64
    var total: Int64 { bytesIn + bytesOut }
}

/// Live CPU, battery, GPU, network and device stats, sampled every 2 s for the menu bar and Network screen.
@MainActor
@Observable
final class SystemMonitor {
    private(set) var cpu: Double = 0
    private(set) var cpuHistory: [Double] = []
    private(set) var gpu: Double?
    private(set) var battery: BatteryInfo?
    private(set) var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private(set) var volumes: [ExternalVolume] = []
    private(set) var displays = 1

    // Network
    private(set) var downRate: Double = 0
    private(set) var upRate: Double = 0
    private(set) var rateHistory: [(date: Date, down: Double, up: Double)] = []
    private(set) var days: [NetworkDay] = []
    private(set) var peakDown: Double = 0
    private(set) var appTraffic: [AppTraffic] = []
    private(set) var interfaceName = "—"

    private var lastTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private var lastBytes: (down: UInt64, up: UInt64, date: Date)?
    private var timer: Task<Void, Never>?
    private var tick = 0
    private var lastSave = Date.distantPast
    private var lastHealthAlert: [String: Date] = [:]

    var today: NetworkDay { days.last { $0.day == NetworkDay.formatter.string(from: .now) } ?? NetworkDay(day: NetworkDay.formatter.string(from: .now)) }

    init() {
        days = Self.loadDays()
    }

    func start() {
        guard timer == nil else { return }
        sample()
        refreshSlow()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.sample()
                self.tick += 1
                if self.tick % 15 == 0 { self.refreshSlow() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveDays() }
        }
        // After sleep, don't count the gap as one huge sample.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastBytes = nil }
        }
    }

    func sample() {
        cpu = readCPU() ?? cpu
        cpuHistory.append(cpu)
        if cpuHistory.count > 150 { cpuHistory.removeFirst() }
        uptime = ProcessInfo.processInfo.systemUptime
        sampleNetwork()
        if tick % 5 == 0 { battery = Self.readBattery() }
        if Date().timeIntervalSince(lastSave) > 30 { saveDays() }
    }

    private func refreshSlow() {
        gpu = Self.readGPU()
        battery = Self.readBattery()
        volumes = Self.readVolumes()
        displays = NSScreen.screens.count
        Task { appTraffic = await Task.detached { Self.readAppTraffic() }.value }
    }

    func refreshAppTraffic() {
        Task { appTraffic = await Task.detached { Self.readAppTraffic() }.value }
    }

    // MARK: Network

    private func sampleNetwork() {
        let (down, up, name) = Self.readInterfaceBytes()
        interfaceName = name
        let now = Date()
        defer { lastBytes = (down, up, now) }
        guard let last = lastBytes else { return }
        let elapsed = max(now.timeIntervalSince(last.date), 0.5)
        // Counters reset when an interface goes down; ignore that sample.
        let dDown = down >= last.down ? Int64(down - last.down) : 0
        let dUp = up >= last.up ? Int64(up - last.up) : 0
        guard elapsed < 30 else { return }
        downRate = Double(dDown) / elapsed
        upRate = Double(dUp) / elapsed
        peakDown = max(peakDown, downRate)
        rateHistory.append((now, downRate, upRate))
        if rateHistory.count > 300 { rateHistory.removeFirst() }
        add(down: dDown, up: dUp, at: now)
    }

    private func add(down: Int64, up: Int64, at date: Date) {
        let key = NetworkDay.formatter.string(from: date)
        let hour = Calendar.current.component(.hour, from: date)
        if days.last?.day != key { days.append(NetworkDay(day: key)) }
        let index = days.count - 1
        days[index].down += down
        days[index].up += up
        days[index].hourlyDown[hour] += down
        days[index].hourlyUp[hour] += up
    }

    func resetHistory() {
        days = []
        saveDays()
    }

    private static var daysURL: URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/DevSweep")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("network-usage.json")
    }

    private static func loadDays() -> [NetworkDay] {
        guard let data = try? Data(contentsOf: daysURL),
              let days = try? JSONDecoder().decode([NetworkDay].self, from: data) else { return [] }
        return days
    }

    func saveDays() {
        lastSave = .now
        let kept = Array(days.suffix(120))
        if let data = try? JSONEncoder().encode(kept) { try? data.write(to: Self.daysURL, options: .atomic) }
    }

    /// 64-bit byte counters for physical interfaces (Wi-Fi/Ethernet/cellular), read from the interface MIB
    /// (`net.link.generic.ifdata`), the same source `netstat -ib` uses. NET_RT_IFLIST2 truncates to 32 bits.
    nonisolated static func readInterfaceBytes() -> (down: UInt64, up: UInt64, name: String) {
        // struct ifmibdata: name[16], 5 × u_int, filler[4] → if_data64 at 52; ibytes @ +64, obytes @ +72.
        var countMib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_SYSTEM, IFMIB_IFCOUNT]
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&countMib, 5, &count, &size, nil, 0) == 0, count > 0 else { return (0, 0, "—") }
        var down: UInt64 = 0, up: UInt64 = 0
        var busiest = ("—", UInt64(0))
        var buffer = [UInt8](repeating: 0, count: 512)
        for index in 1...count {
            var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, index, IFDATA_GENERAL]
            var length = buffer.count
            guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0, length >= 52 + 80 else { continue }
            let name = buffer.prefix(16).withUnsafeBufferPointer { ptr in
                String(decoding: ptr.prefix { $0 != 0 }, as: UTF8.self)
            }
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            let (inBytes, outBytes) = buffer.withUnsafeBytes { raw in
                (raw.loadUnaligned(fromByteOffset: 52 + 64, as: UInt64.self), raw.loadUnaligned(fromByteOffset: 52 + 72, as: UInt64.self))
            }
            down &+= inBytes
            up &+= outBytes
            if inBytes &+ outBytes > busiest.1 { busiest = (name, inBytes &+ outBytes) }
        }
        return (down, up, busiest.0)
    }

    /// Per-process bytes since each process started, from `nettop`.
    nonisolated static func readAppTraffic() -> [AppTraffic] {
        let result = FileOps.run("/usr/bin/nettop -P -L 1 -J bytes_in,bytes_out -x", timeout: 10)
        guard result.ok else { return [] }
        var byName: [String: AppTraffic] = [:]
        for line in result.output.split(whereSeparator: \.isNewline).dropFirst() {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, let dot = parts[0].lastIndex(of: ".") else { continue }
            let name = String(parts[0][..<dot])
            let pid = Int32(parts[0][parts[0].index(after: dot)...]) ?? 0
            let bytesIn = Int64(parts[1]) ?? 0, bytesOut = Int64(parts[2]) ?? 0
            guard bytesIn + bytesOut > 0 else { continue }
            let existing = byName[name]
            byName[name] = AppTraffic(id: name, name: name, pid: pid,
                                      bytesIn: bytesIn + (existing?.bytesIn ?? 0), bytesOut: bytesOut + (existing?.bytesOut ?? 0))
        }
        return byName.values.sorted { $0.total > $1.total }
    }

    // MARK: CPU / GPU / battery / devices

    private func readCPU() -> Double? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<Int32>.size)) }
        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        for cpu in 0..<Int(count) {
            let base = Int(CPU_STATE_MAX) * cpu
            user += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            system += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            idle += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            nice += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
        }
        defer { lastTicks = (user, system, idle, nice) }
        guard let last = lastTicks, user >= last.user, idle >= last.idle else { return nil }
        let busy = Double((user - last.user) + (system - last.system) + (nice - last.nice))
        let total = busy + Double(idle - last.idle)
        return total > 0 ? busy / total : nil
    }

    nonisolated static func readGPU() -> Double? {
        guard let matching = IOServiceMatching("IOAccelerator") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                for key in ["Device Utilization %", "GPU Activity(%)", "Renderer Utilization %"] {
                    if let value = (stats[key] as? NSNumber)?.doubleValue { best = max(best ?? 0, min(max(value, 0), 100)) }
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return best.map { $0 / 100 }
    }

    nonisolated static func readBattery() -> BatteryInfo? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
              (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
        else { return nil }
        let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
        let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
        var info = BatteryInfo(level: max > 0 ? Double(current) / Double(max) : 0,
                               isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                               onAC: (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
                               timeRemaining: (description[kIOPSTimeToEmptyKey] as? Int).flatMap { $0 > 0 ? $0 : nil })
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            func number(_ key: String) -> Double? {
                (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.doubleValue
            }
            if let raw = number("AppleRawMaxCapacity") ?? number("NominalChargeCapacity"), let design = number("DesignCapacity"), design > 0 {
                info.health = min(raw / design, 1)
            }
            info.cycles = number("CycleCount").map(Int.init)
            if let t = number("Temperature") { info.temperature = t > 1000 ? t / 100 : t > 120 ? t / 10 : t }
        }
        return info
    }

    nonisolated static func readVolumes() -> [ExternalVolume] {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsInternalKey, .volumeNameKey,
                                      .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.volumeIsRemovable == true || v.volumeIsInternal == false else { return nil }
            return ExternalVolume(id: url.path, name: v.volumeName ?? url.lastPathComponent, url: url,
                                  total: Int64(v.volumeTotalCapacity ?? 0), free: Int64(v.volumeAvailableCapacity ?? 0))
        }
    }

    // MARK: Health alerts

    /// Throttled, opt-in notifications for low disk, high memory pressure and worn batteries.
    func checkHealth(disk: (free: Int64, total: Int64), memory: MemorySnapshot) {
        guard UserDefaults.standard.bool(forKey: "healthAlerts") else { return }
        if disk.free < 5_000_000_000 {
            alert("disk", every: 900, title: "Your disk is almost full",
                  body: "Only \(disk.free.byteString) left. Open DevSweep to free up space.")
        }
        if memory.pressure == .critical {
            alert("memory", every: 1800, title: "Memory pressure is critical", body: memory.pressure.advice)
        }
        if let health = battery?.health, health < 0.8 {
            alert("battery", every: 7 * 86_400, title: "Battery health is \(Int(health * 100))%",
                  body: "Your battery holds noticeably less charge than when new. Consider a service appointment.")
        }
    }

    private func alert(_ kind: String, every interval: TimeInterval, title: String, body: String) {
        guard Date().timeIntervalSince(lastHealthAlert[kind] ?? .distantPast) > interval else { return }
        lastHealthAlert[kind] = .now
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "health.\(kind)", content: content, trigger: nil))
    }
}

extension Double {
    /// "1.2 MB/s"
    var rateString: String {
        if self >= 1_000_000 { return String(format: "%.1f MB/s", self / 1_000_000) }
        if self >= 1_000 { return String(format: "%.0f KB/s", self / 1_000) }
        return String(format: "%.0f B/s", self)
    }
}

extension TimeInterval {
    var uptimeString: String {
        let minutes = Int(self) / 60
        let days = minutes / 1440, hours = (minutes % 1440) / 60, mins = minutes % 60
        return days > 0 ? "\(days)d \(hours)h" : hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
    }
}
