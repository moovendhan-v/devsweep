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
        let months = max(UserDefaults.standard.integer(forKey: "unusedMonths"), 3)
        return lastUsed < Calendar.current.date(byAdding: .month, value: -months, to: .now)!
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
    private(set) var launchItems: [LaunchItem] = []
    private(set) var startupItems: [StartupItem] = []
    private(set) var cpuProcesses: [ProcessCPU] = []
    var runningTask: String?
    var results: [String: String] = [:]

    let tasks = Maintenance.all.filter(\.isAvailable)

    func refresh() {
        Task {
            async let launch = Task.detached { PerformanceModel.findLaunchItems() }.value
            async let startup = Task.detached { PerformanceModel.findStartupItems() }.value
            launchItems = await launch
            startupItems = await startup
        }
    }

    func refreshCPU() async {
        cpuProcesses = await Task.detached { PerformanceModel.sampleCPU() }.value
    }

    func setEnabled(_ item: StartupItem, _ on: Bool) async -> String {
        let message = await Task.detached { PerformanceModel.setEnabled(item, on) }.value
        refresh()
        return message
    }

    func run(_ task: Maintenance) async -> Bool {
        runningTask = task.id
        let ok: Bool
        if task.admin {
            ok = await Admin.run(task.command)
        } else {
            let command = task.command
            let result = await Task.detached { FileOps.run(command, timeout: 3600) }.value
            ok = result.ok
            if !result.output.isEmpty { results[task.id] = String(result.output.suffix(400)) }
        }
        results[task.id] = (ok ? "✓ Done " : "✗ Failed or cancelled ") + Date().formatted(date: .omitted, time: .shortened)
        runningTask = nil
        return ok
    }

    /// Runs every safe task in order with a single admin password prompt.
    func runSafeTasks() async -> Bool {
        let safe = tasks.filter { $0.severity == .safe }
        runningTask = "safe"
        let user = safe.filter { !$0.admin }
        for task in user { _ = await run(task) }
        runningTask = "safe"
        let combined = safe.filter(\.admin).map(\.command).joined(separator: " ; ")
        let ok = combined.isEmpty ? true : await Admin.run(combined)
        for task in safe where task.admin {
            results[task.id] = (ok ? "✓ Done " : "✗ Cancelled ") + Date().formatted(date: .omitted, time: .shortened)
        }
        runningTask = nil
        return ok
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

// MARK: - Shredder & duplicate consolidation
// Secure-erase modes and APFS clone consolidation adapted from Mac Sai (https://github.com/iliyami/MacSai),
// Copyright (c) 2026, Mac Sai Contributors, BSD 3-Clause License.

@MainActor
@Observable
final class ShredderModel {
    enum Mode: String, CaseIterable, Identifiable {
        case trash = "Move to Trash", delete = "Delete Permanently", overwrite = "Overwrite, then Delete"
        var id: String { rawValue }
        var detail: String {
            switch self {
            case .trash: "Recoverable from the Trash."
            case .delete: "Removed immediately. Not recoverable from the Trash."
            case .overwrite: "Each file is overwritten with zeros before deletion. On SSDs this is best-effort: the drive may keep old copies internally, so FileVault is the real protection."
            }
        }
    }

    var files: [URL] = []
    var mode: Mode = .delete
    private(set) var isRunning = false

    var total: Int64 { files.reduce(0) { $0 + FileOps.size(of: $1) } }

    func add(_ urls: [URL]) {
        let existing = Set(files)
        files += urls.filter { !existing.contains($0) }
    }

    func shred() async -> [String] {
        isRunning = true
        let files = self.files, mode = self.mode
        let lines = await Task.detached { () -> [String] in
            files.map { url in
                do {
                    try SafetyGuard.validate(url)
                    switch mode {
                    case .trash:
                        if let error = FileOps.remove(url, toTrash: true) { return "✗ \(error)" }
                    case .delete:
                        try FileManager.default.removeItem(at: url)
                    case .overwrite:
                        try ShredderModel.overwrite(url)
                        try FileManager.default.removeItem(at: url)
                    }
                    return "✓ Shredded \(url.lastPathComponent)"
                } catch {
                    return "✗ \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }.value
        self.files.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        isRunning = false
        return lines
    }

    nonisolated static func overwrite(_ url: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            for child in (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] { try overwrite(child) }
            return
        }
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { return }
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > 0 else { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let chunk = Data(count: min(size, 1 << 20))
        var remaining = size
        while remaining > 0 {
            let n = min(remaining, chunk.count)
            try handle.write(contentsOf: chunk.prefix(n))
            remaining -= n
        }
        try handle.synchronize()
    }
}

extension DuplicatesModel {
    /// Replaces each selected duplicate with an APFS clone of the copy being kept: every path stays,
    /// the data is stored once. Returns (bytes reclaimed, problems).
    func consolidateSelected() async -> (Int64, [String]) {
        let plan: [(keep: URL, copies: [URL])] = groups.compactMap { group in
            let copies = group.files.map(\.url).filter { selection.contains($0) }
            guard let keep = group.files.map(\.url).first(where: { !selection.contains($0) }), !copies.isEmpty else { return nil }
            return (keep, copies)
        }
        let result = await Task.detached { () -> (Int64, [String]) in
            var reclaimed: Int64 = 0
            var problems: [String] = []
            for (keep, copies) in plan {
                for copy in copies {
                    do {
                        try SafetyGuard.validate(copy)
                        let values = try copy.resourceValues(forKeys: [.volumeSupportsFileCloningKey, .totalFileAllocatedSizeKey])
                        guard values.volumeSupportsFileCloning == true else { problems.append("\(copy.lastPathComponent): volume can't clone"); continue }
                        guard FileManager.default.contentsEqual(atPath: keep.path, andPath: copy.path) else {
                            problems.append("\(copy.lastPathComponent): changed since the scan, skipped")
                            continue
                        }
                        let temp = copy.deletingLastPathComponent().appendingPathComponent(".\(copy.lastPathComponent).clone-\(UUID().uuidString)")
                        guard clonefile(keep.path, temp.path, 0) == 0 else { problems.append("\(copy.lastPathComponent): clone failed"); continue }
                        if let attrs = try? FileManager.default.attributesOfItem(atPath: copy.path) {
                            try? FileManager.default.setAttributes([.posixPermissions: attrs[.posixPermissions] ?? 0o644,
                                                                    .modificationDate: attrs[.modificationDate] ?? Date()], ofItemAtPath: temp.path)
                        }
                        guard rename(temp.path, copy.path) == 0 else {
                            try? FileManager.default.removeItem(at: temp)
                            problems.append("\(copy.lastPathComponent): couldn't swap")
                            continue
                        }
                        reclaimed += Int64(values.totalFileAllocatedSize ?? 0)
                    } catch {
                        problems.append("\(copy.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
            return (reclaimed, problems)
        }.value
        selection = []
        return result
    }
}
