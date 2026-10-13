import AppKit
import CryptoKit
import Darwin
import Foundation
import Observation
import UniformTypeIdentifiers

// MARK: - Trash

@MainActor
@Observable
final class TrashModel {
    private(set) var size: Int64 = 0
    private(set) var count = 0
    private(set) var readable = true

    private var url: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash") }

    func refresh() async {
        let url = self.url
        let result = await Task.detached { () -> (Int64, Int, Bool) in
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return (0, 0, false) }
            return (FileOps.size(of: url), items.filter { $0 != ".DS_Store" }.count, true)
        }.value
        (size, count, readable) = result
    }

    /// Asks Finder to empty the Trash (needs the one-time Automation permission).
    func empty() async -> Bool {
        let ok = await Task.detached { () -> Bool in
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
            return error == nil
        }.value
        await refresh()
        return ok
    }
}

// MARK: - Large & old files

struct LargeFile: Identifiable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case all = "All", video = "Videos", archive = "Archives", diskImage = "Disk Images & Installers",
             audio = "Audio", image = "Images", document = "Documents", vm = "VMs & Containers", other = "Other"

        var symbol: String {
            switch self {
            case .all: "square.grid.2x2"
            case .video: "film"
            case .archive: "doc.zipper"
            case .diskImage: "externaldrive.badge.plus"
            case .audio: "waveform"
            case .image: "photo"
            case .document: "doc.richtext"
            case .vm: "cube.transparent"
            case .other: "doc"
            }
        }
    }

    let url: URL
    let size: Int64
    let modified: Date?
    let accessed: Date?
    let kind: Kind
    var id: URL { url }
    var lastUsed: Date? { [modified, accessed].compactMap { $0 }.max() }
    var isHidden: Bool { url.pathComponents.contains { $0.hasPrefix(".") } }

    static func kind(for url: URL) -> Kind {
        let ext = url.pathExtension.lowercased()
        if ["dmg", "pkg", "mpkg", "iso", "xip", "img"].contains(ext) { return .diskImage }
        if ["raw", "qcow2", "vmdk", "vdi", "vhd", "vhdx", "utm", "pvm", "sparseimage", "sparsebundle"].contains(ext)
            || url.lastPathComponent.contains("datadisk") || url.path.contains("/.colima/") { return .vm }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .archive) || ["zip", "gz", "tgz", "xz", "7z", "rar", "bz2", "zst", "tar"].contains(ext) { return .archive }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .pdf) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet)
            || type.conforms(to: .text) { return .document }
        return .other
    }
}

@MainActor
@Observable
final class LargeFilesModel {
    private(set) var files: [LargeFile] = []
    private(set) var isScanning = false
    private(set) var scannedRoot: URL?
    var selection: Set<URL> = []
    /// Files smaller than this are ignored during the scan.
    let minimumSize: Int64 = 50_000_000

    var total: Int64 { files.reduce(0) { $0 + $1.size } }

    func scan(root: URL) async {
        isScanning = true
        selection = []
        let minimum = minimumSize
        files = await Task.detached { LargeFilesModel.find(in: root, minimum: minimum) }.value
        scannedRoot = root
        isScanning = false
    }

    func remove(_ urls: Set<URL>) {
        files.removeAll { urls.contains($0.url) && !FileManager.default.fileExists(atPath: $0.url.path) }
        selection.subtract(urls)
    }

    nonisolated static func find(in root: URL, minimum: Int64) -> [LargeFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .totalFileAllocatedSizeKey,
                                      .fileAllocatedSizeKey, .contentModificationDateKey, .contentAccessDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [], errorHandler: { _, _ in true })
        else { return [] }
        let skip: Set<String> = ["Library", ".Trash", ".git", "node_modules", ".build", "DerivedData", "Pods",
                                 ".gradle", ".npm", ".cargo", ".rustup", ".pyenv", ".nvm", "site-packages", ".venv", "venv"]
        var found: [LargeFile] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                if skip.contains(name) || (values.isPackage == true && url.pathExtension == "app") {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            guard size >= minimum else { continue }
            found.append(LargeFile(url: url, size: size, modified: values.contentModificationDate,
                                   accessed: values.contentAccessDate, kind: LargeFile.kind(for: url)))
        }
        return found.sorted { $0.size > $1.size }
    }
}

// MARK: - Duplicates

struct DuplicateGroup: Identifiable, Hashable, Sendable {
    let id: String
    let size: Int64
    let files: [DuplicateFile]
    var wasted: Int64 { size * Int64(files.count - 1) }
}

struct DuplicateFile: Identifiable, Hashable, Sendable {
    let url: URL
    let modified: Date?
    var id: URL { url }
}

@MainActor
@Observable
final class DuplicatesModel {
    private(set) var groups: [DuplicateGroup] = []
    private(set) var isScanning = false
    private(set) var status = ""
    private(set) var scannedRoot: URL?
    var selection: Set<URL> = []

    var wasted: Int64 { groups.reduce(0) { $0 + $1.wasted } }
    var selectedBytes: Int64 {
        groups.reduce(0) { total, group in
            total + Int64(group.files.filter { selection.contains($0.url) }.count) * group.size
        }
    }

    func scan(root: URL) async {
        isScanning = true
        selection = []
        groups = []
        status = "Listing files…"
        let found = await Task.detached {
            DuplicatesModel.find(in: root) { message in
                Task { @MainActor [weak self] in self?.status = message }
            }
        }.value
        groups = found
        scannedRoot = root
        isScanning = false
        selectAllButNewest()
    }

    /// Keeps the most recently modified copy in each group.
    func selectAllButNewest() {
        selection = Set(groups.flatMap { group in
            group.files.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }.dropFirst().map(\.url)
        })
    }

    func remove(_ urls: Set<URL>) {
        groups = groups.compactMap { group in
            let files = group.files.filter { FileManager.default.fileExists(atPath: $0.url.path) }
            return files.count > 1 ? DuplicateGroup(id: group.id, size: group.size, files: files) : nil
        }
        selection.subtract(urls)
    }

    nonisolated static func find(in root: URL, minimum: Int64 = 1_000_000,
                                 progress: @escaping @Sendable (String) -> Void) -> [DuplicateGroup] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
                                      .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles], errorHandler: { _, _ in true })
        else { return [] }
        let skip: Set<String> = ["Library", "node_modules", ".build", "DerivedData", "Pods", "venv", "site-packages", "target"]

        // 1. Group by exact size.
        var bySize: [Int64: [DuplicateFile]] = [:]
        var count = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                if skip.contains(url.lastPathComponent) || values.isPackage == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, Int64(size) >= minimum else { continue }
            bySize[Int64(size), default: []].append(DuplicateFile(url: url, modified: values.contentModificationDate))
            count += 1
            if count % 500 == 0 { progress("Looked at \(count) files…") }
        }

        // 2. Same size → compare a quick hash of the first 64 KB, then a full SHA-256.
        let candidates = bySize.filter { $0.value.count > 1 }
        var groups: [DuplicateGroup] = []
        var checked = 0
        for (size, files) in candidates {
            checked += 1
            if checked % 20 == 0 { progress("Comparing \(checked) of \(candidates.count) size matches…") }
            let quick = Dictionary(grouping: files) { hash($0.url, limit: 65_536) ?? UUID().uuidString }
            for (_, sameStart) in quick where sameStart.count > 1 {
                let full = Dictionary(grouping: sameStart) { hash($0.url, limit: nil) ?? UUID().uuidString }
                for (digest, same) in full where same.count > 1 {
                    groups.append(DuplicateGroup(id: digest, size: size, files: same))
                }
            }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }

    nonisolated private static func hash(_ url: URL, limit: Int?) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit ?? Int.max
        while remaining > 0 {
            let chunk = (try? handle.read(upToCount: min(1_048_576, remaining))) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Applications

struct InstalledApp: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let bundleID: String?
    let version: String?
    let size: Int64
    let lastUsed: Date?
    var id: URL { url }

    /// Only flagged when we actually know the last-used date.
    var isUnused: Bool {
        guard let lastUsed else { return false }
        return lastUsed < Date.now.addingTimeInterval(-90 * 86_400)
    }
}

/// Settings, caches and support files left behind in ~/Library by an app.
struct Leftover: Identifiable, Hashable, Sendable {
    let url: URL
    let size: Int64
    var id: URL { url }
}

@MainActor
@Observable
final class AppsModel {
    private(set) var apps: [InstalledApp] = []
    private(set) var orphans: [Leftover] = []
    private(set) var isScanning = false
    var selection: Set<URL> = []

    var unused: [InstalledApp] { apps.filter(\.isUnused) }
    var orphanBytes: Int64 { orphans.reduce(0) { $0 + $1.size } }

    func scan() async {
        isScanning = true
        let (apps, orphans) = await Task.detached { (AppsModel.findApps(), AppsModel.findOrphans()) }.value
        self.apps = apps
        self.orphans = orphans
        isScanning = false
    }

    func leftovers(for app: InstalledApp) async -> [Leftover] {
        await Task.detached { AppsModel.findLeftovers(for: app) }.value
    }

    func forget(_ urls: Set<URL>) {
        apps.removeAll { urls.contains($0.url) && !FileManager.default.fileExists(atPath: $0.url.path) }
        orphans.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
        selection.subtract(urls)
    }

    nonisolated static func findApps() -> [InstalledApp] {
        let roots = ["/Applications", NSHomeDirectory() + "/Applications"]
        var urls: [URL] = []
        for root in roots {
            let items = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil)) ?? []
            for item in items {
                if item.pathExtension == "app" {
                    urls.append(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    // One level of folders, e.g. /Applications/Utilities-style vendor folders.
                    let nested = (try? FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
                    urls += nested.filter { $0.pathExtension == "app" }
                }
            }
        }
        // Metadata lookups (Bundle, Spotlight) run one at a time; only disk measuring is parallel.
        struct Info { let url: URL; let name: String; let bundleID: String?; let version: String?; let lastUsed: Date? }
        let infos: [Info] = urls.compactMap { url in
            let bundle = Bundle(url: url)
            let bundleID = bundle?.bundleIdentifier
            guard bundleID?.hasPrefix("com.apple.") != true else { return nil }
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            // Spotlight's last-used date, falling back to when the app's executable was last read
            // (Spotlight data is missing when indexing is off).
            let spotlight = NSMetadataItem(url: url)?.value(forAttribute: "kMDItemLastUsedDate") as? Date
            let executable = bundle?.executableURL
                .flatMap { try? $0.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate }
            return Info(url: url, name: name, bundleID: bundleID,
                        version: bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                        lastUsed: [spotlight, executable].compactMap { $0 }.max())
        }
        let sizes = infos.map(\.url).concurrentMap { FileOps.size(of: $0) }
        return zip(infos, sizes).map { info, size in
            InstalledApp(url: info.url, name: info.name, bundleID: info.bundleID, version: info.version,
                         size: size, lastUsed: info.lastUsed)
        }
        .sorted { $0.size > $1.size }
    }

    nonisolated static func findLeftovers(for app: InstalledApp) -> [Leftover] {
        let library = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        var keys = [app.url.deletingPathExtension().lastPathComponent, app.name]
        if let bundleID = app.bundleID { keys.insert(bundleID, at: 0) }
        let keySet = Set(keys.map { $0.lowercased() })

        var candidates: [URL] = []
        for folder in ["Application Support", "Caches", "Containers", "HTTPStorages", "WebKit", "Logs",
                       "Saved Application State", "Application Scripts", "Cookies"] {
            let dir = library.appendingPathComponent(folder)
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            candidates += items.filter { item in
                let name = item.lastPathComponent.lowercased()
                    .replacingOccurrences(of: ".savedstate", with: "")
                    .replacingOccurrences(of: ".binarycookies", with: "")
                return keySet.contains(name)
            }
        }
        if let bundleID = app.bundleID {
            for folder in ["Preferences", "LaunchAgents"] {
                let dir = library.appendingPathComponent(folder)
                let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                candidates += items.filter { $0.lastPathComponent.lowercased().hasPrefix(bundleID.lowercased()) }
            }
            let groups = library.appendingPathComponent("Group Containers")
            let items = (try? FileManager.default.contentsOfDirectory(at: groups, includingPropertiesForKeys: nil)) ?? []
            candidates += items.filter { $0.lastPathComponent.lowercased().hasSuffix(bundleID.lowercased()) }
        }
        return candidates.map { Leftover(url: $0, size: FileOps.size(of: $0)) }.sorted { $0.size > $1.size }
    }

    /// Support files named after a bundle ID whose app is no longer installed.
    nonisolated static func findOrphans() -> [Leftover] {
        let library = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        var found: [Leftover] = []
        for folder in ["Application Support", "Saved Application State", "HTTPStorages", "WebKit"] {
            let dir = library.appendingPathComponent(folder)
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for item in items {
                let id = item.lastPathComponent.replacingOccurrences(of: ".savedState", with: "")
                let parts = id.split(separator: ".")
                guard parts.count >= 3, parts.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }),
                      !id.hasPrefix("com.apple."), id != "com.teamnova.DevSweep",
                      NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) == nil else { continue }
                found.append(Leftover(url: item, size: FileOps.size(of: item)))
            }
        }
        return found.filter { $0.size > 0 }.sorted { $0.size > $1.size }
    }
}

extension Array {
    /// Simple parallel map for CPU/disk-bound work.
    func concurrentMap<T>(_ transform: (Element) -> T) -> [T] {
        var results = [T?](repeating: nil, count: count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: count) { index in
            let value = transform(self[index])
            lock.lock(); results[index] = value; lock.unlock()
        }
        return results.map { $0! }
    }
}

// MARK: - Performance

struct RunningApp: Identifiable, Hashable {
    let pid: pid_t
    let name: String
    let bundleURL: URL?
    let memory: Int64
    var id: pid_t { pid }
}

struct LaunchItem: Identifiable, Hashable, Sendable {
    let url: URL
    let label: String
    let program: String
    let scope: String
    var id: URL { url }
    var isUser: Bool { scope == "You" }
}

struct MaintenanceTask: Identifiable {
    let id: String
    let name: String
    let detail: String
    let symbol: String
    let script: String
}

@MainActor
@Observable
final class PerformanceModel {
    private(set) var memoryUsed: Int64 = 0
    private(set) var memoryTotal: Int64 = Int64(ProcessInfo.processInfo.physicalMemory)
    private(set) var memoryCompressed: Int64 = 0
    private(set) var swapUsed: Int64 = 0
    private(set) var topApps: [RunningApp] = []
    private(set) var launchItems: [LaunchItem] = []
    var runningTask: String?

    let tasks: [MaintenanceTask] = [
        MaintenanceTask(id: "ram", name: "Free Up RAM", detail: "Purges inactive memory so apps that need RAM get it.",
                        symbol: "memorychip", script: "/usr/sbin/purge"),
        MaintenanceTask(id: "dns", name: "Flush DNS Cache", detail: "Fixes sites that won't load after network or DNS changes.",
                        symbol: "network", script: "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"),
        MaintenanceTask(id: "spotlight", name: "Reindex Spotlight", detail: "Rebuilds the search index when Spotlight results are wrong. Takes a while.",
                        symbol: "magnifyingglass", script: "/usr/bin/mdutil -E /"),
        MaintenanceTask(id: "launchservices", name: "Rebuild Launch Services", detail: "Fixes duplicate apps in “Open With” menus.",
                        symbol: "list.bullet.rectangle",
                        script: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user"),
    ]

    var memoryPressure: Double { Double(memoryUsed) / Double(max(memoryTotal, 1)) }

    func refresh() {
        readMemory()
        topApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .map { RunningApp(pid: $0.processIdentifier, name: $0.localizedName ?? "App",
                              bundleURL: $0.bundleURL, memory: Self.footprint(of: $0.processIdentifier)) }
            .sorted { $0.memory > $1.memory }
        Task {
            launchItems = await Task.detached { PerformanceModel.findLaunchItems() }.value
        }
    }

    func quit(_ app: RunningApp) {
        NSRunningApplication(processIdentifier: app.pid)?.terminate()
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            refresh()
        }
    }

    /// Runs a maintenance task with an admin password prompt from macOS.
    func run(_ task: MaintenanceTask) async -> Bool {
        runningTask = task.id
        let script = task.script.replacingOccurrences(of: "\"", with: "\\\"")
        let ok = await Task.detached { () -> Bool in
            var error: NSDictionary?
            NSAppleScript(source: "do shell script \"\(script)\" with administrator privileges")?.executeAndReturnError(&error)
            return error == nil
        }.value
        runningTask = nil
        refresh()
        return ok
    }

    private func readMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let page = Int64(vm_kernel_page_size)
        let app = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
        memoryUsed = (app + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page
        memoryCompressed = Int64(stats.compressor_page_count) * page

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { swapUsed = Int64(swap.xsu_used) }
    }

    private static func footprint(of pid: pid_t) -> Int64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? Int64(info.ri_phys_footprint) : 0
    }

    nonisolated static func findLaunchItems() -> [LaunchItem] {
        let scopes = [(NSHomeDirectory() + "/Library/LaunchAgents", "You"),
                      ("/Library/LaunchAgents", "All Users"),
                      ("/Library/LaunchDaemons", "System")]
        var items: [LaunchItem] = []
        for (dir, scope) in scopes {
            let files = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "plist" {
                let plist = NSDictionary(contentsOf: file)
                let label = plist?["Label"] as? String ?? file.deletingPathExtension().lastPathComponent
                let program = plist?["Program"] as? String
                    ?? (plist?["ProgramArguments"] as? [String])?.first ?? ""
                items.append(LaunchItem(url: file, label: label, program: program, scope: scope))
            }
        }
        return items.sorted { ($0.scope, $0.label) < ($1.scope, $1.label) }
    }
}
