import AppKit
import Foundation
import IOKit.pwr_mgt
import Observation
import ServiceManagement
import UserNotifications

/// A task DevSweep runs on a schedule, in the app or from its background agent.
struct ScheduledTask: Codable, Identifiable, Hashable {
    enum Action: String, Codable, CaseIterable, Identifiable {
        case cleanDevCaches = "Clean safe developer caches"
        case cleanJunk = "Clean safe system junk"
        case cleanDerivedData = "Clear Xcode DerivedData"
        case brewCleanup = "Homebrew cleanup"
        case dockerPrune = "Docker: prune build cache & dangling images"
        case staleProjects = "Remove node_modules untouched for 30+ days"
        case emptyTrash = "Empty the Trash"
        case networkReport = "Notify me of today's network usage"
        case diskReport = "Notify me if free space drops below 20 GB"
        case custom = "Run a shell command"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .cleanDevCaches: "hammer.circle"
            case .cleanJunk: "trash.circle"
            case .cleanDerivedData: "swift"
            case .brewCleanup: "mug"
            case .dockerPrune: "cube.transparent"
            case .staleProjects: "shippingbox"
            case .emptyTrash: "trash.slash"
            case .networkReport: "network"
            case .diskReport: "internaldrive"
            case .custom: "terminal"
            }
        }

        var isDestructive: Bool { [.emptyTrash, .staleProjects, .custom].contains(self) }
    }

    enum Repeat: String, Codable, CaseIterable, Identifiable {
        case hourly = "Every hour", every6h = "Every 6 hours", daily = "Every day", weekly = "Every week", atLogin = "At login"
        var id: String { rawValue }
    }

    var id = UUID()
    var action: Action
    var repeatEvery: Repeat = .daily
    var hour = 3
    var minute = 0
    var weekday = 1          // 1 = Sunday
    var command = ""
    var projectFolder = ""
    var moveToTrash = true
    var enabled = true
    var keepAwake = true
    var lastRun: Date?
    var lastResult: String?

    var title: String { action == .custom && !command.isEmpty ? command : action.rawValue }

    var scheduleText: String {
        let time = String(format: "%02d:%02d", hour, minute)
        switch repeatEvery {
        case .hourly: return "Every hour"
        case .every6h: return "Every 6 hours"
        case .daily: return "Daily at \(time)"
        case .weekly: return "\(Calendar.current.weekdaySymbols[(weekday - 1) % 7])s at \(time)"
        case .atLogin: return "At login"
        }
    }

    /// The most recent moment this task should have run at or before `now`.
    func lastDue(before now: Date) -> Date? {
        let cal = Calendar.current
        switch repeatEvery {
        case .hourly: return now.addingTimeInterval(-3600) > (lastRun ?? .distantPast) ? now : nil
        case .every6h: return now.addingTimeInterval(-6 * 3600) > (lastRun ?? .distantPast) ? now : nil
        case .atLogin: return nil
        case .daily:
            var c = cal.dateComponents([.year, .month, .day], from: now); c.hour = hour; c.minute = minute
            guard let today = cal.date(from: c) else { return nil }
            return today <= now ? today : cal.date(byAdding: .day, value: -1, to: today)
        case .weekly:
            var c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now); c.weekday = weekday; c.hour = hour; c.minute = minute
            guard let thisWeek = cal.date(from: c) else { return nil }
            return thisWeek <= now ? thisWeek : cal.date(byAdding: .day, value: -7, to: thisWeek)
        }
    }

    func isDue(now: Date = .now) -> Bool {
        guard enabled, let due = lastDue(before: now) else { return false }
        return (lastRun ?? .distantPast) < due
    }
}

/// Persists tasks and runs them. Shared by the app and the headless `--run-due-tasks` agent mode.
enum TaskStore {
    static var url: URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/DevSweep")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scheduled-tasks.json")
    }

    static func load() -> [ScheduledTask] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ScheduledTask].self, from: data)) ?? []
    }

    static func save(_ tasks: [ScheduledTask]) {
        if let data = try? JSONEncoder().encode(tasks) { try? data.write(to: url, options: .atomic) }
    }

    /// Runs every due task once. Uses a lock file so the app and the agent never run the same task twice.
    static func runDue(includeLogin: Bool = false) async -> [String] {
        let lockPath = url.deletingLastPathComponent().appendingPathComponent(".tasks.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { return [] }
        defer { flock(fd, LOCK_UN); close(fd) }

        var tasks = load()
        var lines: [String] = []
        for index in tasks.indices where tasks[index].isDue() || (includeLogin && tasks[index].enabled && tasks[index].repeatEvery == .atLogin) {
            let result = await execute(tasks[index])
            tasks[index].lastRun = .now
            tasks[index].lastResult = result
            lines.append(result)
            save(tasks)   // save after each so a crash doesn't re-run finished tasks
        }
        return lines
    }

    static func execute(_ task: ScheduledTask) async -> String {
        let assertion = task.keepAwake ? KeepAwake.hold(reason: "DevSweep: \(task.title)") : nil
        defer { if let assertion { IOPMAssertionRelease(assertion) } }

        let result: String
        switch task.action {
        case .cleanDevCaches, .cleanJunk:
            let developer = task.action == .cleanDevCaches
            let targets = await Discovery.targets().filter {
                $0.group.isDeveloper == developer && $0.risk == .safe && $0.command == nil && $0.mode != .thin
            }
            var freed: Int64 = 0
            var errors = 0
            for target in targets {
                freed += FileOps.size(of: target)
                errors += FileOps.clean(target, toTrash: task.moveToTrash).count
            }
            CleanHistory.commit(label: "Scheduled: \(task.action.rawValue)")
            result = "✓ \(task.action.rawValue): \(freed.byteString) from \(targets.count) locations" + (errors > 0 ? " (\(errors) skipped)" : "")
        case .cleanDerivedData:
            let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Developer/Xcode/DerivedData")
            let size = FileOps.size(of: url)
            let errors = FileOps.clearContents(of: url, toTrash: task.moveToTrash)
            CleanHistory.commit(label: "Scheduled: DerivedData")
            result = errors.isEmpty ? "✓ Cleared DerivedData (\(size.byteString))" : "⚠︎ DerivedData: \(errors.first ?? "")"
        case .brewCleanup:
            let r = FileOps.run("command -v brew >/dev/null || exit 3; brew cleanup --prune=all -s", timeout: 1800)
            result = r.ok ? "✓ Homebrew cleanup: \(r.output.split(whereSeparator: \.isNewline).last ?? "done")" : "✗ Homebrew cleanup failed"
        case .dockerPrune:
            let r = FileOps.run("command -v docker >/dev/null || exit 3; docker builder prune -f && docker image prune -f", timeout: 1800)
            result = r.ok ? "✓ Docker pruned: \(r.output.split(whereSeparator: \.isNewline).last ?? "done")" : "✗ Docker isn't running"
        case .staleProjects:
            let root = URL(fileURLWithPath: task.projectFolder.isEmpty ? NSHomeDirectory() + "/Desktop" : task.projectFolder)
            let stale = ProjectScanner.scan(root: root) { _ in }.filter { $0.isStale && $0.kind == "node_modules" }
            let freed = stale.reduce(0) { $0 + $1.size }
            let errors = stale.compactMap { FileOps.remove($0.url, toTrash: task.moveToTrash) }
            CleanHistory.commit(label: "Scheduled: stale node_modules")
            result = "✓ Removed \(stale.count - errors.count) stale node_modules (\(freed.byteString))"
        case .emptyTrash:
            let trash = URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")
            let size = FileOps.size(of: trash)
            let errors = FileOps.clearContents(of: trash, toTrash: false)
            result = errors.isEmpty ? "✓ Emptied the Trash (\(size.byteString))" : "⚠︎ Trash: \(errors.count) items couldn't be removed (grant Full Disk Access)"
        case .networkReport:
            let days = (try? JSONDecoder().decode([NetworkDay].self, from: Data(contentsOf: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/DevSweep/network-usage.json")))) ?? []
            let today = days.last { $0.day == NetworkDay.formatter.string(from: .now) }
            result = "Network today: ↓ \((today?.down ?? 0).byteString) ↑ \((today?.up ?? 0).byteString)"
        case .diskReport:
            let free = FileOps.diskSpace().free
            result = free < 20_000_000_000 ? "⚠︎ Only \(free.byteString) free on your disk" : "✓ \(free.byteString) free"
        case .custom:
            let r = FileOps.run(task.command, timeout: 3600)
            result = (r.ok ? "✓ " : "✗ ") + "\(task.command): " + String(r.output.suffix(200))
        }
        notify(title: task.title, body: result)
        return result
    }

    static func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = "DevSweep · \(title)"
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Prevents idle sleep while something important runs (lid-close sleep still happens on battery).
enum KeepAwake {
    static func hold(reason: String, display: Bool = false) -> IOPMAssertionID? {
        var id: IOPMAssertionID = 0
        let type = (display ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
        return IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id) == kIOReturnSuccess ? id : nil
    }
}

/// The background agent: a launchd job that runs `DevSweep --run-due-tasks` every 15 minutes and at login.
/// launchd runs jobs that came due during sleep as soon as the Mac wakes.
enum BackgroundAgent {
    static let label = "com.teamnova.DevSweep.scheduler"
    static var plistURL: URL { URL(fileURLWithPath: NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist") }
    /// Registered through SMAppService (shows in Login Items & Extensions), plist bundled in Contents/Library/LaunchAgents.
    static var service: SMAppService { SMAppService.agent(plistName: "\(label).plist") }
    static var isInstalled: Bool { service.status == .enabled || FileManager.default.fileExists(atPath: plistURL.path) }
    static var needsApproval: Bool { service.status == .requiresApproval }

    static func install() -> String {
        do {
            try service.register()
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                return "Turn DevSweep on under “Allow in the Background” in Login Items & Extensions."
            }
            return "✓ Background tasks are on. Tasks run even when DevSweep is closed."
        } catch {
            return installManually()
        }
    }

    /// Fallback for builds where SMAppService can't register (e.g. unsigned development builds).
    private static func installManually() -> String {
        guard let executable = Bundle.main.executableURL else { return "✗ Can't find DevSweep's executable" }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path, "--run-due-tasks"],
            "StartInterval": 900,
            "RunAtLoad": true,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 10,
            "StandardOutPath": NSHomeDirectory() + "/Library/Logs/DevSweep-scheduler.log",
            "StandardErrorPath": NSHomeDirectory() + "/Library/Logs/DevSweep-scheduler.log",
        ]
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL)
        } catch {
            return "✗ \(error.localizedDescription)"
        }
        let uid = getuid()
        _ = FileOps.run("/bin/launchctl bootout gui/\(uid) '\(plistURL.path)' 2>/dev/null; /bin/launchctl bootstrap gui/\(uid) '\(plistURL.path)'", timeout: 15)
        return "✓ Background agent installed. Tasks run even when DevSweep is closed."
    }

    static func uninstall() -> String {
        try? service.unregister()
        _ = FileOps.run("/bin/launchctl bootout gui/\(getuid()) '\(plistURL.path)' 2>/dev/null; true", timeout: 15)
        try? FileManager.default.removeItem(at: plistURL)
        return "✓ Background tasks are off"
    }

    /// Wakes the Mac every day at the given time with `pmset repeat` (one system-wide schedule; asks for admin).
    static func scheduleWake(hour: Int, minute: Int) async -> Bool {
        let time = String(format: "%02d:%02d:00", hour, max(0, minute - 2) )
        return await Admin.run("/usr/bin/pmset repeat wakeorpoweron MTWRFSU \(time)")
    }

    static func cancelWake() async -> Bool { await Admin.run("/usr/bin/pmset repeat cancel") }

    /// Only the repeating schedule (set by DevSweep or `pmset repeat`), not macOS's internal one-off wake alarms.
    static func currentWakeSchedule() -> String? {
        let output = FileOps.run("/usr/bin/pmset -g sched", timeout: 10).output
        guard let range = output.range(of: "Repeating power events:") else { return nil }
        let lines = output[range.upperBound...].split(whereSeparator: \.isNewline)
            .prefix { !$0.hasSuffix(":") || $0.contains("wake") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.lowercased().contains("wake") }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

@MainActor
@Observable
final class AutomationModel {
    var tasks: [ScheduledTask] = TaskStore.load()
    private(set) var agentInstalled = BackgroundAgent.isInstalled
    private(set) var wakeSchedule: String?
    private(set) var running: UUID?
    var log: [String] = []

    // Keep awake
    private(set) var keepAwakeUntil: Date?
    private(set) var keepAwakeForever = false
    private var keepAwakeAssertion: IOPMAssertionID?
    var keepDisplayOn = false

    private var loop: Task<Void, Never>?

    var isKeepingAwake: Bool { keepAwakeAssertion != nil }

    func start() {
        guard loop == nil else { return }
        wakeSchedule = BackgroundAgent.currentWakeSchedule()
        Task { _ = await runDue(includeLogin: true) }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                self.checkKeepAwakeExpiry()
                if !self.agentInstalled { _ = await self.runDue() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.agentInstalled else { return }
                _ = await self.runDue()
            }
        }
    }

    func save() { TaskStore.save(tasks) }

    func add(_ task: ScheduledTask) {
        tasks.append(task)
        save()
    }

    func delete(_ task: ScheduledTask) {
        tasks.removeAll { $0.id == task.id }
        save()
    }

    func runNow(_ task: ScheduledTask) async {
        running = task.id
        let result = await TaskStore.execute(task)
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index].lastRun = .now
            tasks[index].lastResult = result
        }
        save()
        log.insert(result, at: 0)
        running = nil
    }

    func runDue(includeLogin: Bool = false) async -> [String] {
        let lines = await TaskStore.runDue(includeLogin: includeLogin)
        if !lines.isEmpty {
            tasks = TaskStore.load()
            log.insert(contentsOf: lines, at: 0)
        }
        return lines
    }

    func setAgent(_ on: Bool) -> String {
        let message = on ? BackgroundAgent.install() : BackgroundAgent.uninstall()
        agentInstalled = BackgroundAgent.isInstalled
        return message
    }

    func scheduleWake(hour: Int, minute: Int) async -> Bool {
        let ok = await BackgroundAgent.scheduleWake(hour: hour, minute: minute)
        wakeSchedule = BackgroundAgent.currentWakeSchedule()
        return ok
    }

    func cancelWake() async {
        _ = await BackgroundAgent.cancelWake()
        wakeSchedule = BackgroundAgent.currentWakeSchedule()
    }

    // MARK: Keep awake

    func keepAwake(for duration: TimeInterval?) {
        stopKeepAwake()
        keepAwakeAssertion = KeepAwake.hold(reason: "DevSweep Keep Awake", display: keepDisplayOn)
        keepAwakeForever = duration == nil
        keepAwakeUntil = duration.map { Date().addingTimeInterval($0) }
    }

    func stopKeepAwake() {
        if let id = keepAwakeAssertion { IOPMAssertionRelease(id) }
        keepAwakeAssertion = nil
        keepAwakeUntil = nil
        keepAwakeForever = false
    }

    private func checkKeepAwakeExpiry() {
        if let until = keepAwakeUntil, until < .now { stopKeepAwake() }
    }
}
