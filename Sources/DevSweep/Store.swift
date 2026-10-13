import AppKit
import Foundation
import Observation
import SwiftUI

enum SidebarItem: String, Hashable, CaseIterable {
    case smartCare = "Smart Care"
    case overview = "Dashboard"
    case junk = "System Junk"
    case caches = "Developer Caches"
    case projects = "Project Folders"
    case largeFiles = "Large & Old Files"
    case duplicates = "Duplicates"
    case apps = "Uninstaller"
    case performance = "Performance"
    case explorer = "Space Lens"
    case activity = "Activity"

    var symbol: String {
        switch self {
        case .smartCare: "sparkles"
        case .overview: "gauge.with.dots.needle.67percent"
        case .junk: "trash.circle"
        case .caches: "hammer.circle"
        case .projects: "folder.badge.gearshape"
        case .largeFiles: "doc.badge.ellipsis"
        case .duplicates: "square.on.square"
        case .apps: "app.badge.checkmark"
        case .performance: "bolt.circle"
        case .explorer: "circle.hexagongrid"
        case .activity: "clock.arrow.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .smartCare: .pink
        case .overview: .indigo
        case .junk: .green
        case .caches: .blue
        case .projects: .pink
        case .largeFiles: .orange
        case .duplicates: .teal
        case .apps: .cyan
        case .performance: .yellow
        case .explorer: .purple
        case .activity: .gray
        }
    }
}

@MainActor
@Observable
final class Store {
    // Navigation
    var section: SidebarItem = .smartCare
    var cacheFocus: TargetGroup?
    let explorer = Explorer()

    // Modules
    let largeFiles = LargeFilesModel()
    let duplicates = DuplicatesModel()
    let apps = AppsModel()
    let performance = PerformanceModel()
    let trash = TrashModel()

    // Cache targets (built-in + discovered at runtime)
    var targets: [CleanTarget] = Catalog.targets
    var sizes: [String: Int64] = [:]
    var pathSizes: [URL: Int64] = [:]
    var scanning: Set<String> = []
    var isDiscovering = false
    var lastScan: Date?
    /// Whole targets selected.
    var selected: Set<String> = []
    /// Individual sub-folders selected inside a target (e.g. one DerivedData project).
    var childSelection: [String: Set<URL>] = [:]
    var hideMissing = true

    // Project junk
    var projectRoot: URL? {
        didSet { UserDefaults.standard.set(projectRoot?.path, forKey: "lastProjectRoot") }
    }
    var projectJunk: [ProjectJunk] = []
    var selectedJunk: Set<URL> = []
    var projectScanStatus: String?

    // Smart Care
    var smartStage: String?
    var smartProgress: Double = 0
    var smartDone = false

    // Shared
    var moveToTrash = true
    var isCleaning = false
    var log: [String] = []
    var disk = FileOps.diskSpace()
    var hasFullDiskAccess = Store.checkFullDiskAccess()

    init() {
        if let path = UserDefaults.standard.string(forKey: "lastProjectRoot"),
           FileManager.default.fileExists(atPath: path) {
            projectRoot = URL(fileURLWithPath: path)
        }
    }

    // MARK: Derived values

    var isScanningCaches: Bool { isDiscovering || !scanning.isEmpty }
    var devTargets: [CleanTarget] { targets.filter(\.group.isDeveloper) }
    var junkTargets: [CleanTarget] { targets.filter { !$0.group.isDeveloper } }
    var cacheTotal: Int64 { bytes(of: devTargets) }
    var junkTotal: Int64 { bytes(of: junkTargets) }
    var projectTotal: Int64 { projectJunk.reduce(0) { $0 + $1.size } }
    var reclaimable: Int64 { cacheTotal + junkTotal + projectTotal + trash.size }
    var isDiskLow: Bool { disk.free < 10_000_000_000 || Double(disk.free) < Double(disk.total) * 0.05 }

    func bytes(of targets: [CleanTarget]) -> Int64 { targets.reduce(0) { $0 + (sizes[$1.id] ?? 0) } }

    func safeTargets(in groups: [TargetGroup]) -> [CleanTarget] {
        targets.filter { groups.contains($0.group) && $0.risk == .safe && $0.command == nil && (sizes[$0.id] ?? 0) > 0 }
    }

    var safeTargets: [CleanTarget] { safeTargets(in: TargetGroup.allCases) }

    func selectedBytes(in groups: [TargetGroup]) -> Int64 {
        targets.filter { groups.contains($0.group) }.reduce(0) { total, target in
            if selected.contains(target.id) { return total + (sizes[target.id] ?? 0) }
            return total + (childSelection[target.id] ?? []).reduce(0) { $0 + (pathSizes[$1] ?? 0) }
        }
    }

    func selectionCount(in groups: [TargetGroup]) -> Int {
        targets.filter { groups.contains($0.group) }.reduce(0) { count, target in
            selected.contains(target.id) ? count + 1 : count + (childSelection[target.id]?.count ?? 0)
        }
    }

    var selectedJunkBytes: Int64 {
        projectJunk.filter { selectedJunk.contains($0.url) }.reduce(0) { $0 + $1.size }
    }

    func locationCount(_ group: TargetGroup) -> Int {
        targets.filter { $0.group == group && (sizes[$0.id] ?? 0) > 0 }.count
    }

    func groupBytes(_ group: TargetGroup) -> Int64 { bytes(of: targets.filter { $0.group == group }) }

    func isAvailable(_ target: CleanTarget) -> Bool {
        target.command != nil || !target.existingURLs.isEmpty
    }

    func target(_ id: String) -> CleanTarget? { targets.first { $0.id == id } }

    /// Short label for folders DevSweep knows are safe to rebuild.
    func hint(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        if targets.contains(where: { $0.urls.contains { $0.standardizedFileURL.path == path } }) {
            return "Cache"
        }
        return ProjectScanner.kind(forFolderAt: url)
    }

    // MARK: Selection

    func toggle(_ target: CleanTarget) {
        if selected.contains(target.id) || childSelection[target.id]?.isEmpty == false {
            selected.remove(target.id)
            childSelection[target.id] = nil
        } else {
            selected.insert(target.id)
        }
    }

    func toggleChild(_ url: URL, of target: CleanTarget, siblings: [URL]) {
        var children = childSelection[target.id] ?? []
        if selected.contains(target.id) {
            // Turning one child off from a fully selected target: select all others.
            selected.remove(target.id)
            children = Set(siblings)
        }
        if children.contains(url) { children.remove(url) } else { children.insert(url) }
        if !siblings.isEmpty && Set(siblings).isSubset(of: children) {
            selected.insert(target.id)
            children = []
        }
        childSelection[target.id] = children.isEmpty ? nil : children
    }

    func checkState(_ target: CleanTarget) -> Checkbox.Value {
        if selected.contains(target.id) { return .on }
        return childSelection[target.id]?.isEmpty == false ? .mixed : .off
    }

    /// Sub-folders of a target, sized, for drill-down.
    func children(of target: CleanTarget) async -> [FolderItem] {
        let urls = target.existingURLs
        let items = await Task.detached { () -> [FolderItem] in
            urls.flatMap { url in
                (FileOps.list(url, showHidden: true) ?? []).map { item in
                    var item = item
                    if item.size == nil { item.size = FileOps.size(of: item.url) }
                    return item
                }
            }
        }.value
        for item in items { pathSizes[item.url] = item.size }
        return items.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
    }

    // MARK: Navigation

    func browse(_ url: URL) {
        explorer.open(url)
        section = .explorer
    }

    func focus(_ group: TargetGroup?) {
        cacheFocus = group
        section = (group?.isDeveloper ?? true) ? .caches : .junk
    }

    // MARK: Scanning

    func scanCaches() async {
        guard !isDiscovering else { return }
        isDiscovering = true
        disk = FileOps.diskSpace()
        hasFullDiskAccess = Store.checkFullDiskAccess()
        targets = await Discovery.targets()
        let ids = Set(targets.map(\.id))
        sizes = sizes.filter { ids.contains($0.key) }
        childSelection = childSelection.filter { ids.contains($0.key) }
        isDiscovering = false

        let measurable = targets.filter { $0.reportedSize != nil || !$0.existingURLs.isEmpty }
        scanning = Set(measurable.map(\.id))
        await withTaskGroup(of: (String, [(URL, Int64)], Int64?).self) { group in
            for target in measurable {
                let urls = target.existingURLs
                let reported = target.reportedSize
                group.addTask {
                    if let reported { return (target.id, [], reported) }
                    return (target.id, urls.map { ($0, FileOps.size(of: $0)) }, nil)
                }
            }
            for await (id, results, reported) in group {
                for (url, bytes) in results { pathSizes[url] = bytes }
                sizes[id] = reported ?? results.reduce(0) { $0 + $1.1 }
                scanning.remove(id)
            }
        }
        selected = Set(safeTargets.map(\.id))
        lastScan = .now
    }

    func scanProjects(at root: URL) async {
        projectRoot = root
        projectJunk = []
        selectedJunk = []
        projectScanStatus = "Starting…"
        let found = await Task.detached {
            ProjectScanner.scan(root: root) { path in
                Task { @MainActor [weak self] in
                    if self?.projectScanStatus != nil { self?.projectScanStatus = path }
                }
            }
        }.value
        projectJunk = found
        projectScanStatus = nil
    }

    /// One-click 360° checkup across every module.
    func smartScan() async {
        smartDone = false
        smartProgress = 0
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let projectRoot = self.projectRoot ?? [home.appendingPathComponent("Developer"), home.appendingPathComponent("Desktop")]
            .first { FileManager.default.fileExists(atPath: $0.path) }

        smartStage = "Looking for system junk and developer caches…"
        await scanCaches()
        smartProgress = 0.35

        smartStage = "Checking the Trash…"
        await trash.refresh()
        smartProgress = 0.4

        smartStage = "Finding node_modules, build output and other project junk…"
        if let projectRoot { await scanProjects(at: projectRoot) }
        smartProgress = 0.6

        smartStage = "Looking for large and old files…"
        await largeFiles.scan(root: home)
        smartProgress = 0.85

        smartStage = "Reviewing your apps…"
        await apps.scan()
        performance.refresh()
        smartProgress = 1
        smartStage = nil
        smartDone = true
        selectedJunk = Set(projectJunk.filter(\.isStale).map(\.url))
    }

    /// Cleans what Smart Care recommends: safe caches, the Trash (optional) and stale project folders.
    func runSmartCare(includeTrash: Bool, includeProjects: Bool) async {
        selected = Set(safeTargets.map(\.id))
        childSelection = [:]
        await cleanSelectedCaches(in: TargetGroup.allCases)
        if includeProjects && !selectedJunk.isEmpty { await cleanSelectedJunk() }
        if includeTrash { await emptyTrash() }
        smartDone = false
    }

    // MARK: Cleaning

    func cleanSelectedCaches(in groups: [TargetGroup]) async {
        let chosen = targets.filter { groups.contains($0.group) && selected.contains($0.id) }
        let partial = targets.filter { groups.contains($0.group) && !selected.contains($0.id) }
            .compactMap { target in childSelection[target.id].map { (target, Array($0)) } }
        await clean { [moveToTrash] in
            var lines: [String] = []
            for target in chosen {
                if let command = target.command {
                    let result = FileOps.run(command)
                    lines.append("\(result.ok ? "✓" : "✗") \(target.name): \(result.output.isEmpty ? "done" : String(result.output.suffix(200)))")
                    continue
                }
                let errors = FileOps.clean(target, toTrash: moveToTrash)
                lines.append(errors.isEmpty ? "✓ \(target.name)" : "⚠︎ \(target.name): \(errors.prefix(3).joined(separator: "; "))")
            }
            for (target, urls) in partial {
                let errors = urls.compactMap { FileOps.remove($0, toTrash: moveToTrash) }
                lines.append(errors.isEmpty ? "✓ \(target.name): \(urls.count) folder(s)"
                                            : "⚠︎ \(target.name): \(errors.prefix(3).joined(separator: "; "))")
            }
            return lines
        }
        for (target, _) in partial { childSelection[target.id] = nil }
        await scanCaches()
    }

    func cleanSelectedJunk() async {
        let items = projectJunk.filter { selectedJunk.contains($0.url) }
        await clean { [moveToTrash] in
            items.map { item in
                if let error = FileOps.remove(item.url, toTrash: moveToTrash) { return "✗ \(error)" }
                return "✓ \(item.projectName)/\(item.url.lastPathComponent) (\(item.size.byteString))"
            }
        }
        projectJunk.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
        selectedJunk = []
    }

    func trashFiles(_ urls: [URL], label: String) async {
        await clean {
            urls.map { url in
                FileOps.remove(url, toTrash: true).map { "✗ \($0)" } ?? "✓ \(label): \(url.lastPathComponent)"
            }
        }
    }

    func trashFromExplorer(_ urls: [URL]) async {
        await trashFiles(urls, label: "Moved to Trash")
        explorer.invalidateAndReload()
    }

    func emptyTrash() async {
        let before = trash.size
        let result = await trash.empty()
        log.insert(result ? "✓ Emptied the Trash (\(before.byteString))" : "✗ Couldn't empty the Trash. Allow DevSweep to control Finder in System Settings › Privacy & Security › Automation.", at: 0)
        disk = FileOps.diskSpace()
    }

    func clean(_ work: @escaping @Sendable () -> [String]) async {
        isCleaning = true
        let before = FileOps.diskSpace().free
        let lines = await Task.detached(operation: work).value
        disk = FileOps.diskSpace()
        let freed = max(0, disk.free - before)
        let summary = "— \(Date().formatted(date: .abbreviated, time: .shortened)): " +
            (moveToTrash ? "moved to Trash (empty Trash to reclaim space)" : "freed ~\(freed.byteString)")
        log.insert(contentsOf: [summary] + lines, at: 0)
        isCleaning = false
        await trash.refresh()
    }

    // MARK: Permissions

    static func checkFullDiskAccess() -> Bool {
        let probe = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Safari")
        return (try? FileManager.default.contentsOfDirectory(atPath: probe.path)) != nil
    }

    static func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}

extension ProjectJunk {
    /// Not touched for 30+ days.
    var isStale: Bool { (modified ?? .distantPast) < Date.now.addingTimeInterval(-30 * 86_400) }
}
