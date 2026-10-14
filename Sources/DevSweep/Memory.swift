import AppKit
import Darwin
import Foundation
import Observation
import UserNotifications

/// One reading of the VM system, matching Activity Monitor's categories.
struct MemorySnapshot: Sendable {
    var date = Date()
    var total: Int64 = Int64(ProcessInfo.processInfo.physicalMemory)
    var app: Int64 = 0
    var wired: Int64 = 0
    var compressed: Int64 = 0
    var cached: Int64 = 0
    var free: Int64 = 0
    var swapTotal: Int64 = 0
    var swapUsed: Int64 = 0
    var pressure: MemoryPressure = .normal
    /// Kernel's estimate of memory still available, in percent.
    var availablePercent = 100
    // Cumulative counters (pages / events) used to compute rates.
    var swapIns: UInt64 = 0
    var swapOuts: UInt64 = 0
    var pageIns: UInt64 = 0
    var pageOuts: UInt64 = 0

    var used: Int64 { app + wired + compressed }
    var usedFraction: Double { Double(used) / Double(max(total, 1)) }
    var swapFraction: Double { Double(swapUsed) / Double(max(swapTotal, 1)) }
}

enum MemoryPressure: Int, Sendable {
    case normal = 1, warning = 2, critical = 4

    var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "Critical"
        }
    }

    var advice: String {
        switch self {
        case .normal: "Your Mac has enough memory for what's running."
        case .warning: "macOS is compressing memory and using swap. Quitting a heavy app will help."
        case .critical: "Your Mac is short on memory and slowing down. Quit apps or free up RAM now."
        }
    }

    var color: NSColor {
        switch self {
        case .normal: .systemGreen
        case .warning: .systemOrange
        case .critical: .systemRed
        }
    }
}

/// Memory used by one app (including its helper processes) or one standalone process.
struct ProcessGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let appURL: URL?
    let pids: [pid_t]
    let memory: Int64
    let isMine: Bool

    var processCount: Int { pids.count }
}

struct SwapFile: Identifiable, Hashable {
    let name: String
    let size: Int64
    let modified: Date?
    var id: String { name }
}

@MainActor
@Observable
final class MemoryMonitor {
    private(set) var current = MemorySnapshot()
    private(set) var history: [MemorySnapshot] = []
    private(set) var groups: [ProcessGroup] = []
    private(set) var swapFiles: [SwapFile] = []
    /// Per-second rates over the last sample.
    private(set) var swapInRate: Double = 0
    private(set) var swapOutRate: Double = 0
    private(set) var pageOutRate: Double = 0
    private(set) var peakUsed: Int64 = 0
    private(set) var peakSwap: Int64 = 0

    private var timer: Task<Void, Never>?
    private var tick = 0
    private var lastAlert: Date = .distantPast
    private var lastPressure: MemoryPressure = .normal

    var interval: Double { max(1, UserDefaults.standard.double(forKey: "memoryInterval").nonZero ?? 2) }
    /// Keep 30 minutes of history.
    private var maxSamples: Int { Int(1800 / interval) }

    func start() {
        guard timer == nil else { return }
        sample()
        refreshProcesses()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.interval ?? 2))
                guard let self else { return }
                self.sample()
                self.tick += 1
                if self.tick % 3 == 0 { self.refreshProcesses() }
            }
        }
    }

    func restart() {
        timer?.cancel()
        timer = nil
        start()
    }

    func sample() {
        var snapshot = Self.read()
        let previous = current
        let elapsed = max(snapshot.date.timeIntervalSince(previous.date), 0.5)
        if previous.swapIns > 0 {
            swapInRate = Double(snapshot.swapIns &- previous.swapIns) / elapsed
            swapOutRate = Double(snapshot.swapOuts &- previous.swapOuts) / elapsed
            pageOutRate = Double(snapshot.pageOuts &- previous.pageOuts) / elapsed
        }
        snapshot.date = .now
        current = snapshot
        history.append(snapshot)
        if history.count > maxSamples { history.removeFirst(history.count - maxSamples) }
        peakUsed = max(peakUsed, snapshot.used)
        peakSwap = max(peakSwap, snapshot.swapUsed)
        alertIfNeeded(snapshot.pressure)
    }

    func refreshProcesses() {
        Task {
            let (groups, files) = await Task.detached { (Self.readProcesses(), Self.readSwapFiles()) }.value
            self.groups = groups
            self.swapFiles = files
        }
    }

    func resetPeaks() {
        peakUsed = current.used
        peakSwap = current.swapUsed
    }

    // MARK: Actions

    func quit(_ group: ProcessGroup, force: Bool) {
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            group.pids.contains(app.processIdentifier)
                || (group.appURL != nil && app.bundleURL?.standardizedFileURL == group.appURL?.standardizedFileURL)
        }
        if apps.isEmpty {
            for pid in group.pids where group.isMine { kill(pid, force ? SIGKILL : SIGTERM) }
        } else {
            for app in apps { _ = force ? app.forceTerminate() : app.terminate() }
        }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            sample()
            refreshProcesses()
        }
    }

    /// Runs `purge` (asks for the admin password) and reports how much memory came back.
    func freeUpRAM() async -> (ok: Bool, freed: Int64) {
        let before = current.used
        let ok = await Task.detached { () -> Bool in
            var error: NSDictionary?
            NSAppleScript(source: "do shell script \"/usr/sbin/purge\" with administrator privileges")?
                .executeAndReturnError(&error)
            return error == nil
        }.value
        try? await Task.sleep(for: .seconds(1))
        sample()
        refreshProcesses()
        return (ok, max(0, before - current.used))
    }

    // MARK: Alerts

    private func alertIfNeeded(_ pressure: MemoryPressure) {
        defer { lastPressure = pressure }
        guard UserDefaults.standard.bool(forKey: "memoryAlerts"),
              pressure.rawValue > lastPressure.rawValue, pressure != .normal,
              Date().timeIntervalSince(lastAlert) > 600 else { return }
        lastAlert = .now
        let content = UNMutableNotificationContent()
        content.title = pressure == .critical ? "Memory pressure is critical" : "Memory pressure is rising"
        let top = groups.first.map { " \($0.name) is using \($0.memory.byteString)." } ?? ""
        content.body = pressure.advice + top
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "memory", content: content, trigger: nil))
    }

    static func requestAlertPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: Readers

    nonisolated static func read() -> MemorySnapshot {
        var snapshot = MemorySnapshot()
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let page = Int64(vm_kernel_page_size)
            snapshot.app = max(0, Int64(stats.internal_page_count) - Int64(stats.purgeable_count)) * page
            snapshot.wired = Int64(stats.wire_count) * page
            snapshot.compressed = Int64(stats.compressor_page_count) * page
            snapshot.cached = (Int64(stats.external_page_count) + Int64(stats.purgeable_count)) * page
            snapshot.free = max(0, snapshot.total - snapshot.used - snapshot.cached)
            snapshot.swapIns = stats.swapins
            snapshot.swapOuts = stats.swapouts
            snapshot.pageIns = stats.pageins
            snapshot.pageOuts = stats.pageouts
        }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            snapshot.swapTotal = Int64(swap.xsu_total)
            snapshot.swapUsed = Int64(swap.xsu_used)
        }
        var level: Int32 = 1
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            snapshot.pressure = MemoryPressure(rawValue: Int(level)) ?? .normal
        }
        var available: Int32 = 100
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_level", &available, &size, nil, 0) == 0 {
            snapshot.availablePercent = Int(available)
        }
        return snapshot
    }

    /// Every process we can read, with helpers folded into their parent app.
    nonisolated static func readProcesses() -> [ProcessGroup] {
        let capacity = Int(proc_listallpids(nil, 0)) + 128
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        let myUID = getuid()

        struct Entry { var name: String; var appURL: URL?; var pids: [pid_t]; var memory: Int64; var isMine: Bool }
        var entries: [String: Entry] = [:]
        var pathBuffer = [CChar](repeating: 0, count: 4096)

        for pid in pids.prefix(max(count, 0)) where pid > 0 {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0, info.ri_phys_footprint > 0 else { continue }

            let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let path = pathLength > 0 ? String(cString: pathBuffer) : ""
            var bsd = proc_bsdinfo()
            let bsdOK = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0
            let isMine = bsdOK && bsd.pbi_uid == myUID

            var key = path.isEmpty ? "pid:\(pid)" : path
            var name = path.isEmpty ? "Process \(pid)" : URL(fileURLWithPath: path).lastPathComponent
            var appURL: URL?
            // Fold "…/Google Chrome.app/Contents/Frameworks/…/Helper" into "Google Chrome".
            if let range = path.range(of: ".app/") {
                let appPath = String(path[..<range.lowerBound]) + ".app"
                key = appPath
                appURL = URL(fileURLWithPath: appPath)
                name = URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
            } else if path.isEmpty, bsdOK {
                let comm = withUnsafeBytes(of: bsd.pbi_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                if !comm.isEmpty { name = comm }
            }
            if path.contains("Virtualization.VirtualMachine") {
                key = "virtual-machines"
                name = "Virtual Machines (Docker, Colima, Podman, UTM)"
            }

            var entry = entries[key] ?? Entry(name: name, appURL: appURL, pids: [], memory: 0, isMine: isMine)
            entry.pids.append(pid)
            entry.memory += Int64(info.ri_phys_footprint)
            entry.isMine = entry.isMine || isMine
            entries[key] = entry
        }
        return entries.map { key, entry in
            ProcessGroup(id: key, name: entry.name, appURL: entry.appURL, pids: entry.pids, memory: entry.memory, isMine: entry.isMine)
        }
        .sorted { $0.memory > $1.memory }
    }

    nonisolated static func readSwapFiles() -> [SwapFile] {
        let dir = URL(fileURLWithPath: "/System/Volumes/VM")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("swapfile") }.map { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return SwapFile(name: url.lastPathComponent, size: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
