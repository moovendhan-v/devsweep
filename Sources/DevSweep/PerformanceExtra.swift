// Maintenance task list, login-item handling and launch-agent toggling adapted from Mac Sai
// (https://github.com/iliyami/MacSai), Copyright (c) 2026, Mac Sai Contributors, BSD 3-Clause License.
import AppKit
import Darwin
import Foundation
import Observation

struct Maintenance: Identifiable, Hashable, Sendable {
    enum Severity: String, Sendable { case safe = "Safe", advanced = "Advanced" }
    let id: String
    let name: String
    let detail: String
    let sideEffect: String
    let symbol: String
    let command: String
    let tool: String
    let admin: Bool
    let severity: Severity

    var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: tool) }

    static let all: [Maintenance] = [
        Maintenance(id: "purgeable", name: "Free Up Purgeable Space", detail: "Removes local Time Machine snapshots macOS marked purgeable.",
                    sideEffect: "Local snapshots older than now are removed.", symbol: "internaldrive",
                    command: "/usr/bin/tmutil thinlocalsnapshots / 999999999999 1", tool: "/usr/bin/tmutil", admin: true, severity: .safe),
        Maintenance(id: "dns", name: "Flush DNS Cache", detail: "Fixes sites that won't load after network or DNS changes.",
                    sideEffect: "None. Names are looked up again.", symbol: "network",
                    command: "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder", tool: "/usr/bin/dscacheutil", admin: true, severity: .safe),
        Maintenance(id: "periodic", name: "Run Maintenance Scripts", detail: "Apple's daily, weekly and monthly housekeeping scripts.",
                    sideEffect: "Rotates logs and cleans temporary files.", symbol: "terminal",
                    command: "/usr/sbin/periodic daily weekly monthly", tool: "/usr/sbin/periodic", admin: true, severity: .safe),
        Maintenance(id: "verify", name: "Verify Startup Disk", detail: "Read-only check of the startup volume for errors.",
                    sideEffect: "None. Nothing is changed.", symbol: "checkmark.shield",
                    command: "/usr/sbin/diskutil verifyVolume /", tool: "/usr/sbin/diskutil", admin: false, severity: .safe),
        Maintenance(id: "launchservices", name: "Rebuild Launch Services", detail: "Fixes duplicate apps in “Open With” and wrong file icons.",
                    sideEffect: "Default-app choices can reset and double-clicking may be slow until it finishes (can take hours).",
                    symbol: "list.bullet.rectangle",
                    command: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user",
                    tool: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                    admin: false, severity: .advanced),
        Maintenance(id: "spotlight", name: "Reindex Spotlight", detail: "Rebuilds the search index when Spotlight results are wrong.",
                    sideEffect: "Search is incomplete for a while and the Mac works harder until indexing finishes.", symbol: "magnifyingglass",
                    command: "/usr/bin/mdutil -E /", tool: "/usr/bin/mdutil", admin: true, severity: .advanced),
        Maintenance(id: "timemachine", name: "Thin Time Machine Snapshots", detail: "Deletes local Time Machine snapshots to free space.",
                    sideEffect: "You can't restore from those local snapshots afterwards.", symbol: "clock.arrow.circlepath",
                    command: "/usr/bin/tmutil thinlocalsnapshots / 999999999999 4", tool: "/usr/bin/tmutil", admin: true, severity: .advanced),
        Maintenance(id: "mail", name: "Speed Up Mail", detail: "Rebuilds Mail's message index (quit Mail first).",
                    sideEffect: "Mail re-indexes on next launch, which can take a while for big mailboxes.", symbol: "envelope",
                    command: "rm -f ~/Library/Mail/V*/MailData/Envelope\\ Index*", tool: "/bin/rm", admin: false, severity: .advanced),
        Maintenance(id: "fonts", name: "Clear Font Caches", detail: "Fixes garbled or missing fonts.", sideEffect: "Restart afterwards.",
                    symbol: "textformat", command: "/usr/bin/atsutil databases -remove", tool: "/usr/bin/atsutil", admin: true, severity: .advanced),
    ]
}

struct StartupItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case loginItem = "Login Item", agent = "Launch Agent", daemon = "Launch Daemon" }
    let kind: Kind
    let name: String
    let label: String
    let program: String
    let plist: URL?
    let appURL: URL?
    var enabled: Bool
    let isUser: Bool
    var id: String { kind.rawValue + label + (plist?.path ?? "") }
}

struct ProcessCPU: Identifiable, Hashable {
    let pid: pid_t
    let name: String
    let appURL: URL?
    let cpu: Double
    let threads: Int
    var id: pid_t { pid }
}

extension PerformanceModel {
    nonisolated static func findStartupItems() -> [StartupItem] {
        var items: [StartupItem] = []
        // Login items (System Events). Paths come back as aliases; resolve to apps.
        let script = """
        tell application "System Events" to get {name, path} of every login item
        """
        let output = FileOps.run("/usr/bin/osascript -e '\(script)'", timeout: 15)
        if output.ok {
            let parts = output.output.components(separatedBy: ", ")
            let half = parts.count / 2
            for i in 0..<half {
                let path = parts[half + i]
                items.append(StartupItem(kind: .loginItem, name: parts[i], label: parts[i], program: path, plist: nil,
                                         appURL: path.hasSuffix(".app") ? URL(fileURLWithPath: path) : nil, enabled: true, isUser: true))
            }
        }
        let uid = getuid()
        let disabled = FileOps.run("/bin/launchctl print-disabled gui/\(uid)", timeout: 10).output
        for (dir, kind, isUser) in [(NSHomeDirectory() + "/Library/LaunchAgents", StartupItem.Kind.agent, true),
                                    ("/Library/LaunchAgents", .agent, false), ("/Library/LaunchDaemons", .daemon, false)] {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where file.hasSuffix(".plist") {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(file)
                let plist = NSDictionary(contentsOf: url)
                let label = plist?["Label"] as? String ?? (file as NSString).deletingPathExtension
                let program = plist?["Program"] as? String ?? (plist?["ProgramArguments"] as? [String])?.first ?? ""
                var appURL: URL?
                if let range = program.range(of: ".app/") { appURL = URL(fileURLWithPath: String(program[..<range.lowerBound]) + ".app") }
                let name = appURL.map { $0.deletingPathExtension().lastPathComponent } ?? label
                let off = (plist?["Disabled"] as? Bool ?? false) || disabled.contains("\"\(label)\" => disabled")
                    || disabled.contains("\"\(label)\" => true")
                items.append(StartupItem(kind: kind, name: name, label: label, program: program, plist: url, appURL: appURL,
                                         enabled: !off,
                                         isUser: isUser))
            }
        }
        return items
    }

    /// Turns a user launch agent on/off now and at future logins.
    nonisolated static func setEnabled(_ item: StartupItem, _ on: Bool) -> String {
        let uid = getuid()
        switch item.kind {
        case .loginItem:
            guard !on else { return "Re-add \(item.name) in System Settings › General › Login Items" }
            let result = FileOps.run("/usr/bin/osascript -e 'tell application \"System Events\" to delete login item \"\(item.name.replacingOccurrences(of: "\"", with: ""))\"'", timeout: 15)
            return result.ok ? "✓ \(item.name) won't open at login" : "✗ \(result.output)"
        case .agent where item.isUser:
            guard let plist = item.plist else { return "✗ No plist" }
            let action = on
                ? "/bin/launchctl enable gui/\(uid)/\(item.label); /bin/launchctl bootstrap gui/\(uid) '\(plist.path)' 2>/dev/null; true"
                : "/bin/launchctl bootout gui/\(uid) '\(plist.path)' 2>/dev/null; /bin/launchctl disable gui/\(uid)/\(item.label)"
            let result = FileOps.run(action, timeout: 15)
            return result.ok ? "✓ \(item.name) \(on ? "enabled" : "disabled")" : "✗ \(result.output)"
        default:
            return "System-wide items need admin rights; manage them in System Settings › General › Login Items › Allow in the Background."
        }
    }

    /// CPU % per process over a short sample window.
    nonisolated static func sampleCPU(window: TimeInterval = 1.0) -> [ProcessCPU] {
        func snapshot() -> [pid_t: (UInt64, String, Int)] {
            let capacity = Int(proc_listallpids(nil, 0)) + 64
            var pids = [pid_t](repeating: 0, count: capacity)
            let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
            var result: [pid_t: (UInt64, String, Int)] = [:]
            var pathBuffer = [CChar](repeating: 0, count: 4096)
            for pid in pids.prefix(max(count, 0)) where pid > 0 {
                var info = proc_taskinfo()
                guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 else { continue }
                let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
                result[pid] = (info.pti_total_user + info.pti_total_system, length > 0 ? String(cString: pathBuffer) : "", Int(info.pti_threadnum))
            }
            return result
        }
        let before = snapshot()
        Thread.sleep(forTimeInterval: window)
        let after = snapshot()
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let toNanos = Double(timebase.numer) / Double(timebase.denom)
        return after.compactMap { pid, value -> ProcessCPU? in
            guard let old = before[pid], value.0 >= old.0 else { return nil }
            let cpu = Double(value.0 - old.0) * toNanos / (window * 1_000_000_000)
            guard cpu > 0.005 else { return nil }
            var appURL: URL?
            var name = URL(fileURLWithPath: value.1).lastPathComponent
            if let range = value.1.range(of: ".app/") {
                appURL = URL(fileURLWithPath: String(value.1[..<range.lowerBound]) + ".app")
                if !value.1.contains("Helper") { name = appURL!.deletingPathExtension().lastPathComponent }
            }
            return ProcessCPU(pid: pid, name: name.isEmpty ? "pid \(pid)" : name, appURL: appURL, cpu: cpu, threads: value.2)
        }
        .sorted { $0.cpu > $1.cpu }
    }
}
