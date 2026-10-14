// Signature lists, browser-extension parsing, Wi-Fi and TCC permission logic adapted from Mac Sai
// (https://github.com/iliyami/MacSai), Copyright (c) 2026, Mac Sai Contributors, BSD 3-Clause License.
import AppKit
import CoreServices
import Foundation
import Observation
import Security
import SQLite3
import UserNotifications

// MARK: - Malware

struct Threat: Identifiable, Hashable, Sendable {
    enum Level: String, Sendable { case known = "Known adware/malware", suspicious = "Suspicious" }
    let url: URL
    let level: Level
    let reason: String
    let size: Int64
    var id: URL { url }
}

@MainActor
@Observable
final class MalwareModel {
    enum Depth: String, CaseIterable, Identifiable { case quick = "Quick", balanced = "Balanced", deep = "Deep"; var id: String { rawValue } }

    private(set) var threats: [Threat] = []
    private(set) var isScanning = false
    private(set) var scannedCount = 0
    var depth: Depth = .balanced
    var selection: Set<URL> = []
    var lastScan: Date? = UserDefaults.standard.object(forKey: "lastMalwareScan") as? Date
    private(set) var monitor: FolderWatcher?
    private(set) var liveAlerts: [Threat] = []

    var isMonitoring: Bool { monitor != nil }

    nonisolated static let knownPatterns = ["genio", "pirrit", "shlayer", "bundlore", "adload", "mackeeper", "macdefender",
                                "macprotector", "macguard", "maccleaner", "macshiny", "advancedmaccleaner",
                                "searchbaron", "searchmarquis", "searchmine", "crossrider", "operatormac", "cimpli",
                                "vsearch", "conduit", "installcore", "spigot", "geneio", "mughthesec", "smartsearch",
                                "chumsearch", "safefinder", "weknow", "anysearch", "searchpulse"]
    nonisolated static let suspiciousCommands = ["/tmp/", "/private/tmp/", "curl ", "wget ", "python -c", "base64 -d", "| sh", "| bash",
                                     "/users/shared/", "osascript -e"]

    func scan() async {
        isScanning = true
        scannedCount = 0
        selection = []
        let depth = self.depth
        let (found, count) = await Task.detached { MalwareModel.run(depth: depth) }.value
        threats = found
        scannedCount = count
        selection = Set(found.filter { $0.level == .known }.map(\.url))
        lastScan = .now
        UserDefaults.standard.set(lastScan, forKey: "lastMalwareScan")
        UserDefaults.standard.set(found.count, forKey: "lastMalwareThreats")
        isScanning = false
    }

    func forget(_ urls: Set<URL>) {
        threats.removeAll { urls.contains($0.url) && !FileManager.default.fileExists(atPath: $0.url.path) }
        selection.subtract(urls)
    }

    /// Watches launch agents, Downloads and Applications for new suspicious items.
    func setMonitoring(_ on: Bool) {
        if !on { monitor = nil; return }
        let home = NSHomeDirectory()
        let paths = [home + "/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons",
                     home + "/Downloads", "/Applications", home + "/Applications"]
        monitor = FolderWatcher(paths: paths) { [weak self] changed in
            Task { @MainActor in self?.inspect(changed) }
        }
    }

    private func inspect(_ paths: [String]) {
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path),
                  let threat = Self.check(url) else { continue }
            guard !liveAlerts.contains(threat) else { continue }
            liveAlerts.insert(threat, at: 0)
            let content = UNMutableNotificationContent()
            content.title = threat.level == .known ? "Possible malware detected" : "New suspicious item"
            content.body = "\(url.lastPathComponent): \(threat.reason)"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: path, content: content, trigger: nil))
        }
    }

    nonisolated static func run(depth: Depth) -> ([Threat], Int) {
        let home = NSHomeDirectory()
        var targets: [(String, Int)] = [   // (folder, recursion depth)
            (home + "/Library/LaunchAgents", 0), ("/Library/LaunchAgents", 0), ("/Library/LaunchDaemons", 0),
            (home + "/Library/Application Support/Google/Chrome/Default/Extensions", 0),
            (home + "/Library/Safari/Extensions", 0), ("/Applications", 0), (home + "/Applications", 0),
            ("/Library/Application Support", 0), (home + "/Library/Application Support", 0),
        ]
        if depth != .quick {
            targets += [(home + "/Library/Application Support", 2), ("/Users/Shared", 2), ("/Library/Internet Plug-Ins", 0),
                        (home + "/Library/Internet Plug-Ins", 0), ("/Library/PrivilegedHelperTools", 0)]
        }
        if depth == .deep { targets += [(home + "/Downloads", 3), (home + "/Desktop", 1)] }

        var seen = Set<String>()
        var threats: [Threat] = []
        var count = 0
        for (folder, maxDepth) in targets {
            for url in walk(URL(fileURLWithPath: folder), maxDepth: maxDepth) where seen.insert(url.path).inserted {
                count += 1
                if let threat = check(url) { threats.append(threat) }
            }
        }
        return (threats.sorted { ($0.level == .known ? 0 : 1, $0.url.path) < ($1.level == .known ? 0 : 1, $1.url.path) }, count)
    }

    nonisolated private static func walk(_ root: URL, maxDepth: Int) -> [URL] {
        let fm = FileManager.default
        guard let top = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        guard maxDepth > 0 else { return top }
        return top + top.filter { $0.pathExtension != "app" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .flatMap { walk($0, maxDepth: maxDepth - 1) }
    }

    /// Returns a threat if the item matches a known pattern or looks like an adware launcher.
    nonisolated static func check(_ url: URL) -> Threat? {
        let name = url.lastPathComponent.lowercased()
        func threat(_ level: Threat.Level, _ reason: String) -> Threat {
            Threat(url: url, level: level, reason: reason, size: FileOps.size(of: url))
        }
        if let pattern = knownPatterns.first(where: { name.contains($0) }) {
            return threat(.known, "Name matches known adware family “\(pattern)”")
        }
        guard url.pathExtension == "plist", url.path.contains("/Launch") else { return nil }
        guard let plist = NSDictionary(contentsOf: url) as? [String: Any] else { return nil }
        let args = (plist["ProgramArguments"] as? [String]) ?? [plist["Program"] as? String].compactMap { $0 }
        let joined = args.joined(separator: " ").lowercased()
        if let needle = suspiciousCommands.first(where: { joined.contains($0) }) {
            return threat(.suspicious, "Launch item runs a command containing “\(needle.trimmingCharacters(in: .whitespaces))”")
        }
        let label = (plist["Label"] as? String ?? "").lowercased()
        let trustedPrefixes = ["/opt/homebrew/", "/usr/local/opt/", "/usr/local/cellar/", "/usr/bin/", "/bin/", "/usr/sbin/", "/sbin/",
                               "/system/", "/library/apple/"]
        if let program = args.first, program.hasPrefix("/"),
           !label.hasPrefix("homebrew.mxcl.") && !label.hasPrefix("sh.brew."),
           !trustedPrefixes.contains(where: { program.lowercased().hasPrefix($0) }) {
            if !FileManager.default.fileExists(atPath: program) { return nil }   // broken, not malicious (System Junk handles it)
            let hidden = program.split(separator: "/").contains { $0.hasPrefix(".") }
            if hidden { return threat(.suspicious, "Launches a program hidden in a dot-folder: \(program)") }
            if isMachO(program) && !isSigned(program) { return threat(.suspicious, "Launches an unsigned program: \(program)") }
        }
        return nil
    }

    nonisolated static func isMachO(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path), let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        try? handle.close()
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        return [0xFEED_FACF, 0xCFFA_EDFE, 0xFEED_FACE, 0xCEFA_EDFE, 0xCAFE_BABE, 0xBEBA_FECA].contains(magic)
    }

    nonisolated static func isSigned(_ path: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return true }
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSBasicValidateOnly), nil)
        return status != errSecCSUnsigned
    }
}

/// FSEvents wrapper: reports created/renamed paths under the watched folders.
final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    init(paths: [String], handler: @escaping ([String]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, pathsPointer, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(pathsPointer, to: NSArray.self) as? [String] ?? []
            var changed: [String] = []
            for i in 0..<count {
                let f = flags[i]
                if f & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified) != 0 {
                    changed.append(paths[i])
                }
            }
            if !changed.isEmpty { watcher.handler(changed) }
        }
        stream = FSEventStreamCreate(nil, callback, &context, paths.filter { FileManager.default.fileExists(atPath: $0) } as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                     UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

// MARK: - Privacy

struct PrivacyItem: Identifiable, Hashable, Sendable {
    let id: String
    let app: String          // "Safari", "Chrome", "macOS"
    let kind: String         // "Browsing history"
    let detail: String
    let urls: [URL]
    let size: Int64
    let appBundleID: String?
    let risky: Bool          // signs you out / loses saved data
}

@MainActor
@Observable
final class PrivacyModel {
    enum Age: Int, CaseIterable, Identifiable {
        case all = 0, day = 1, week = 7, month = 30
        var id: Int { rawValue }
        var label: String { self == .all ? "Everything" : self == .day ? "Older than a day" : self == .week ? "Older than a week" : "Older than a month" }
    }

    private(set) var items: [PrivacyItem] = []
    private(set) var isScanning = false
    var selection: Set<String> = []
    var age: Age = .all

    var selectedBytes: Int64 { items.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.size } }

    func scan() async {
        isScanning = true
        let age = self.age
        items = await Task.detached { PrivacyModel.find(olderThanDays: age.rawValue) }.value
        selection = Set(items.filter { !$0.risky }.map(\.id))
        isScanning = false
    }

    func runningApps(for selection: Set<String>) -> [String] {
        let ids = Set(items.filter { selection.contains($0.id) }.compactMap(\.appBundleID))
        return NSWorkspace.shared.runningApplications.compactMap { app in
            app.bundleIdentifier.flatMap { ids.contains($0) ? app.localizedName : nil }
        }
    }

    func urls(for selection: Set<String>) -> [URL] {
        items.filter { selection.contains($0.id) }.flatMap(\.urls)
    }

    private struct Browser { let name: String; let bundleID: String; let profileRoot: String }

    nonisolated static func find(olderThanDays days: Int) -> [PrivacyItem] {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        let cutoff = Date.now.addingTimeInterval(-Double(days) * 86_400)
        func keep(_ url: URL) -> Bool {
            guard days > 0 else { return fm.fileExists(atPath: url.path) }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now
            return date < cutoff
        }
        func item(_ app: String, _ kind: String, _ detail: String, _ paths: [String], bundleID: String?, risky: Bool = false) -> PrivacyItem? {
            let urls = paths.map { URL(fileURLWithPath: $0) }.filter(keep)
            guard !urls.isEmpty else { return nil }
            let size = urls.reduce(0) { $0 + FileOps.size(of: $1) }
            guard size > 0 else { return nil }
            return PrivacyItem(id: "\(app)|\(kind)|\(urls.first!.path)", app: app, kind: kind, detail: detail, urls: urls,
                               size: size, appBundleID: bundleID, risky: risky)
        }
        func sqlite(_ base: String) -> [String] { [base, base + "-journal", base + "-wal", base + "-shm"] }

        var result: [PrivacyItem?] = []
        // Safari (needs Full Disk Access)
        result.append(item("Safari", "Browsing history", "Sites you visited. Bookmarks are kept.",
                           sqlite(home + "/Library/Safari/History.db"), bundleID: "com.apple.Safari"))
        result.append(item("Safari", "Cache", "Downloaded page data.",
                           [home + "/Library/Caches/com.apple.Safari"], bundleID: "com.apple.Safari"))

        // Chromium family
        let chromium = [
            Browser(name: "Chrome", bundleID: "com.google.Chrome", profileRoot: "Google/Chrome"),
            Browser(name: "Brave", bundleID: "com.brave.Browser", profileRoot: "BraveSoftware/Brave-Browser"),
            Browser(name: "Edge", bundleID: "com.microsoft.edgemac", profileRoot: "Microsoft Edge"),
            Browser(name: "Arc", bundleID: "company.thebrowser.Browser", profileRoot: "Arc/User Data"),
            Browser(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", profileRoot: "Vivaldi"),
            Browser(name: "Chromium", bundleID: "org.chromium.Chromium", profileRoot: "Chromium"),
        ]
        for browser in chromium {
            let root = home + "/Library/Application Support/" + browser.profileRoot
            let profiles = ((try? fm.contentsOfDirectory(atPath: root)) ?? [])
                .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            for profile in profiles {
                let base = root + "/" + profile
                let label = profile == "Default" ? browser.name : "\(browser.name) (\(profile))"
                result.append(item(label, "Browsing history", "History, visited links and top sites.",
                                   sqlite(base + "/History") + [base + "/Visited Links"] + sqlite(base + "/Top Sites"),
                                   bundleID: browser.bundleID))
                result.append(item(label, "Cache", "Page, code and GPU caches.",
                                   [base + "/Cache", base + "/Code Cache", base + "/GPUCache",
                                    home + "/Library/Caches/" + browser.profileRoot + "/" + profile],
                                   bundleID: browser.bundleID))
                result.append(item(label, "Cookies", "Signs you out of websites.",
                                   sqlite(base + "/Cookies") + sqlite(base + "/Network/Cookies"),
                                   bundleID: browser.bundleID, risky: true))
                result.append(item(label, "Autofill form data", "Saved form entries (not passwords).",
                                   sqlite(base + "/Web Data"), bundleID: browser.bundleID, risky: true))
            }
        }

        // Firefox (places.sqlite holds bookmarks too, so it's left alone)
        let firefoxRoot = home + "/Library/Application Support/Firefox/Profiles"
        for profile in (try? fm.contentsOfDirectory(atPath: firefoxRoot)) ?? [] {
            let base = firefoxRoot + "/" + profile
            let label = "Firefox (\(profile.split(separator: ".").last ?? Substring(profile)))"
            result.append(item(label, "Cache", "Page cache.", [home + "/Library/Caches/Firefox/Profiles/" + profile],
                               bundleID: "org.mozilla.firefox"))
            result.append(item(label, "Form history", "Things you typed into forms.", sqlite(base + "/formhistory.sqlite"),
                               bundleID: "org.mozilla.firefox"))
            result.append(item(label, "Cookies", "Signs you out of websites.", sqlite(base + "/cookies.sqlite"),
                               bundleID: "org.mozilla.firefox", risky: true))
        }

        // macOS traces
        let sfl = home + "/Library/Application Support/com.apple.sharedfilelist"
        let recents = ((fm.enumerator(atPath: sfl)?.allObjects as? [String]) ?? [])
            .filter { $0.hasSuffix(".sfl2") || $0.hasSuffix(".sfl3") }.map { sfl + "/" + $0 }
        result.append(item("macOS", "Recent items", "“Open Recent” lists for apps and documents.", recents, bundleID: nil))
        result.append(item("macOS", "Recent servers", "Servers you connected to in Finder.",
                           [home + "/Library/Recent Servers"], bundleID: nil))
        result.append(item("macOS", "Quick Look thumbnails", "Previews of files you looked at.",
                           [home + "/Library/Caches/com.apple.QuickLook.thumbnailcache"], bundleID: nil))
        return result.compactMap { $0 }
    }
}

// MARK: - Saved Wi-Fi

struct WiFiNetwork: Identifiable, Hashable { let device: String; let ssid: String; var id: String { device + "/" + ssid } }

@MainActor
@Observable
final class WiFiModel {
    private(set) var networks: [WiFiNetwork] = []
    private(set) var current: String?
    private(set) var isLoading = false
    private(set) var message: String?
    var selection: Set<String> = []

    func load() async {
        isLoading = true
        let (networks, current, message) = await Task.detached { () -> ([WiFiNetwork], String?, String?) in
            let ports = FileOps.run("/usr/sbin/networksetup -listallhardwareports", timeout: 10).output
            var devices: [String] = []
            var isWiFi = false
            for line in ports.split(whereSeparator: \.isNewline).map(String.init) {
                if line.hasPrefix("Hardware Port:") { isWiFi = line.lowercased().contains("wi-fi") || line.lowercased().contains("airport") }
                if isWiFi, line.hasPrefix("Device:") { devices.append(line.replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)); isWiFi = false }
            }
            guard let device = devices.first else { return ([], nil, "No Wi-Fi hardware found.") }
            let list = FileOps.run("/usr/sbin/networksetup -listpreferredwirelessnetworks \(device)", timeout: 10).output
            let networks = list.split(whereSeparator: \.isNewline).dropFirst()
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .map { WiFiNetwork(device: device, ssid: $0) }
            let currentLine = FileOps.run("/usr/sbin/networksetup -getairportnetwork \(device)", timeout: 10).output
            let current = currentLine.components(separatedBy: "Current Wi-Fi Network: ").dropFirst().first
            return (networks, current, nil)
        }.value
        self.networks = networks
        self.current = current
        self.message = message
        isLoading = false
    }

    /// Forgets networks with one admin prompt.
    func forget(_ ids: Set<String>) async -> Bool {
        let chosen = networks.filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { return true }
        let command = chosen.map { network in
            "/usr/sbin/networksetup -removepreferredwirelessnetwork \(network.device) '\(network.ssid.replacingOccurrences(of: "'", with: "'\\''"))'"
        }.joined(separator: " ; ")
        let ok = await Admin.run(command)
        await load()
        selection = []
        return ok
    }
}

/// Runs a shell command with one macOS admin password prompt.
enum Admin {
    static func run(_ command: String) async -> Bool {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return await Task.detached { () -> Bool in
            var error: NSDictionary?
            NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
            return error == nil
        }.value
    }
}

// MARK: - Permissions overview (read-only TCC)

enum PrivacyPermission: String, CaseIterable, Identifiable {
    case fullDiskAccess = "Full Disk Access", accessibility = "Accessibility", screenRecording = "Screen Recording",
         camera = "Camera", microphone = "Microphone", inputMonitoring = "Input Monitoring", automation = "Automation",
         files = "Files & Folders", contacts = "Contacts", calendars = "Calendars", photos = "Photos", bluetooth = "Bluetooth"

    var id: String { rawValue }

    var services: Set<String> {
        switch self {
        case .fullDiskAccess: ["kTCCServiceSystemPolicyAllFiles"]
        case .accessibility: ["kTCCServiceAccessibility"]
        case .screenRecording: ["kTCCServiceScreenCapture"]
        case .camera: ["kTCCServiceCamera"]
        case .microphone: ["kTCCServiceMicrophone"]
        case .inputMonitoring: ["kTCCServiceListenEvent", "kTCCServicePostEvent"]
        case .automation: ["kTCCServiceAppleEvents"]
        case .files: ["kTCCServiceSystemPolicyDesktopFolder", "kTCCServiceSystemPolicyDocumentsFolder",
                      "kTCCServiceSystemPolicyDownloadsFolder", "kTCCServiceSystemPolicyRemovableVolumes",
                      "kTCCServiceSystemPolicyNetworkVolumes"]
        case .contacts: ["kTCCServiceAddressBook"]
        case .calendars: ["kTCCServiceCalendar", "kTCCServiceReminders"]
        case .photos: ["kTCCServicePhotos", "kTCCServicePhotosAdd"]
        case .bluetooth: ["kTCCServiceBluetoothAlways"]
        }
    }

    var symbol: String {
        switch self {
        case .fullDiskAccess: "internaldrive"
        case .accessibility: "accessibility"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .camera: "camera"
        case .microphone: "mic"
        case .inputMonitoring: "keyboard"
        case .automation: "gearshape.2"
        case .files: "folder"
        case .contacts: "person.crop.circle"
        case .calendars: "calendar"
        case .photos: "photo"
        case .bluetooth: "dot.radiowaves.left.and.right"
        }
    }

    var settingsURL: URL {
        let anchor = switch self {
        case .fullDiskAccess: "Privacy_AllFiles"
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .camera: "Privacy_Camera"
        case .microphone: "Privacy_Microphone"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .automation: "Privacy_Automation"
        case .files: "Privacy_FilesAndFolders"
        case .contacts: "Privacy_Contacts"
        case .calendars: "Privacy_Calendars"
        case .photos: "Privacy_Photos"
        case .bluetooth: "Privacy_Bluetooth"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    static func matching(_ service: String) -> PrivacyPermission? { allCases.first { $0.services.contains(service) } }
}

struct PermissionApp: Identifiable, Hashable {
    let client: String          // bundle ID or path
    let name: String
    let appURL: URL?
    let permissions: [PrivacyPermission]
    var id: String { client }
}

@MainActor
@Observable
final class PermissionsModel {
    private(set) var apps: [PermissionApp] = []
    private(set) var needsFullDiskAccess = false
    private(set) var isLoading = false

    func load() async {
        isLoading = true
        let (apps, denied) = await Task.detached { () -> ([PermissionApp], Bool) in
            var grants: [String: Set<PrivacyPermission>] = [:]
            var anyRead = false
            for db in [NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
                       "/Library/Application Support/com.apple.TCC/TCC.db"] {
                guard let rows = PermissionsModel.readTCC(db) else { continue }
                anyRead = true
                for (service, client) in rows {
                    if let permission = PrivacyPermission.matching(service) { grants[client, default: []].insert(permission) }
                }
            }
            let apps = grants.map { client, permissions -> PermissionApp in
                var url: URL?
                if client.hasPrefix("/") {
                    url = URL(fileURLWithPath: client)
                } else {
                    url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: client)
                }
                let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? client
                return PermissionApp(client: client, name: name, appURL: url,
                                     permissions: PrivacyPermission.allCases.filter { permissions.contains($0) })
            }
            .sorted { ($0.permissions.count, $1.name) > ($1.permissions.count, $0.name) }
            return (apps, !anyRead)
        }.value
        self.apps = apps
        needsFullDiskAccess = denied
        isLoading = false
    }

    /// Allowed (auth_value 2) or limited (3) grants: (service, client).
    nonisolated static func readTCC(_ path: String) -> [(String, String)]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT service, client FROM access WHERE auth_value IN (2, 3)", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        var rows: [(String, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let s = sqlite3_column_text(statement, 0), let c = sqlite3_column_text(statement, 1) else { continue }
            rows.append((String(cString: s), String(cString: c)))
        }
        return rows
    }
}

// MARK: - Browser extensions

struct BrowserExtension: Identifiable, Hashable, Sendable {
    let browser: String
    let bundleID: String
    let profile: String
    let identifier: String
    let name: String
    let version: String
    let url: URL
    let suspicious: Bool
    let removable: Bool
    var id: String { "\(browser)|\(profile)|\(identifier)" }
}

@MainActor
@Observable
final class BrowserExtensionsModel {
    private(set) var extensions: [BrowserExtension] = []
    private(set) var isLoading = false

    func load() async {
        isLoading = true
        extensions = await Task.detached { BrowserExtensionsModel.find() }.value
        isLoading = false
    }

    func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    nonisolated static func find() -> [BrowserExtension] {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        var found: [BrowserExtension] = []
        let chromium: [(String, String, String)] = [
            ("Chrome", "com.google.Chrome", "Google/Chrome"), ("Brave", "com.brave.Browser", "BraveSoftware/Brave-Browser"),
            ("Edge", "com.microsoft.edgemac", "Microsoft Edge"), ("Arc", "company.thebrowser.Browser", "Arc/User Data"),
            ("Vivaldi", "com.vivaldi.Vivaldi", "Vivaldi"),
        ]
        for (browser, bundleID, relative) in chromium {
            let root = home + "/Library/Application Support/" + relative
            for profile in ((try? fm.contentsOfDirectory(atPath: root)) ?? []) where profile == "Default" || profile.hasPrefix("Profile ") {
                let extRoot = root + "/" + profile + "/Extensions"
                for id in (try? fm.contentsOfDirectory(atPath: extRoot)) ?? [] where id.count == 32 {
                    let versions = ((try? fm.contentsOfDirectory(atPath: extRoot + "/" + id)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
                    guard let version = versions.last,
                          let data = fm.contents(atPath: "\(extRoot)/\(id)/\(version)/manifest.json"),
                          let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    var name = manifest["name"] as? String ?? id
                    if name.hasPrefix("__MSG_") {
                        let key = String(name.dropFirst(6).dropLast(2))
                        let locale = manifest["default_locale"] as? String ?? "en"
                        for candidate in [locale, "en", "en_US"] {
                            if let msgData = fm.contents(atPath: "\(extRoot)/\(id)/\(version)/_locales/\(candidate)/messages.json"),
                               let messages = try? JSONSerialization.jsonObject(with: msgData) as? [String: Any],
                               let entry = (messages[key] ?? messages.first { $0.key.lowercased() == key.lowercased() }?.value) as? [String: Any],
                               let message = entry["message"] as? String {
                                name = message
                                break
                            }
                        }
                    }
                    found.append(BrowserExtension(browser: browser, bundleID: bundleID, profile: profile, identifier: id, name: name,
                                                  version: manifest["version"] as? String ?? version,
                                                  url: URL(fileURLWithPath: extRoot + "/" + id),
                                                  suspicious: MalwareModel.knownPatterns.contains { name.lowercased().contains($0) },
                                                  removable: true))
                }
            }
        }
        // Firefox
        let ffRoot = home + "/Library/Application Support/Firefox/Profiles"
        for profile in (try? fm.contentsOfDirectory(atPath: ffRoot)) ?? [] {
            guard let data = fm.contents(atPath: ffRoot + "/" + profile + "/extensions.json"),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let addons = json["addons"] as? [[String: Any]] else { continue }
            for addon in addons where (addon["type"] as? String ?? "extension") == "extension" && addon["location"] as? String == "app-profile" {
                let name = (addon["defaultLocale"] as? [String: Any])?["name"] as? String ?? addon["id"] as? String ?? "?"
                guard let path = addon["path"] as? String else { continue }
                found.append(BrowserExtension(browser: "Firefox", bundleID: "org.mozilla.firefox", profile: profile,
                                              identifier: addon["id"] as? String ?? path, name: name,
                                              version: addon["version"] as? String ?? "", url: URL(fileURLWithPath: path),
                                              suspicious: MalwareModel.knownPatterns.contains { name.lowercased().contains($0) },
                                              removable: true))
            }
        }
        // Safari app extensions (managed in Safari Settings)
        let pluginkit = FileOps.run("/usr/bin/pluginkit -m -v -p com.apple.Safari.web-extension,com.apple.Safari.extension,com.apple.Safari.content-blocker", timeout: 10).output
        for line in pluginkit.split(whereSeparator: \.isNewline) {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: "\t").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard let first = parts.first, !first.hasPrefix("com.apple.") else { continue }
            let id = first.trimmingCharacters(in: CharacterSet(charactersIn: "+-!= ")).components(separatedBy: "(").first ?? first
            let path = parts.last { $0.hasPrefix("/") } ?? ""
            let name = path.isEmpty ? id : URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            found.append(BrowserExtension(browser: "Safari", bundleID: "com.apple.Safari", profile: "", identifier: id, name: name,
                                          version: parts.first { $0.hasPrefix("(") }?.trimmingCharacters(in: CharacterSet(charactersIn: "()")) ?? "",
                                          url: URL(fileURLWithPath: path.isEmpty ? "/" : path),
                                          suspicious: MalwareModel.knownPatterns.contains { name.lowercased().contains($0) },
                                          removable: false))
        }
        return found.sorted { ($0.suspicious ? 0 : 1, $0.browser, $0.name) < ($1.suspicious ? 0 : 1, $1.browser, $1.name) }
    }
}
