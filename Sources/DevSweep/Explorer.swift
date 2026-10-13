import Foundation
import Observation

/// Folder-by-folder disk browser. Lists a folder instantly, then fills in
/// sub-folder sizes in the background (largest first once known).
@MainActor
@Observable
final class Explorer {
    private(set) var current = URL(fileURLWithPath: NSHomeDirectory())
    private(set) var items: [FolderItem] = []
    private(set) var pending = 0
    private(set) var unreadable = false
    var selection: Set<URL> = []
    var showHidden = true { didSet { reload() } }

    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var sizeCache: [URL: Int64] = [:]
    private var loadTask: Task<Void, Never>?

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { current.path != "/" }
    var isMeasuring: Bool { pending > 0 }
    var total: Int64 { items.compactMap(\.size).reduce(0, +) }
    var largest: Int64 { max(items.compactMap(\.size).max() ?? 0, 1) }
    var selectedBytes: Int64 {
        items.filter { selection.contains($0.url) }.compactMap(\.size).reduce(0, +)
    }

    func open(_ url: URL) {
        guard url.standardizedFileURL != current.standardizedFileURL else { return reload() }
        backStack.append(current)
        forwardStack = []
        current = url
        reload()
    }

    func back() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(current)
        current = previous
        reload()
    }

    func forward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(current)
        current = next
        reload()
    }

    func up() { if canGoUp { open(current.deletingLastPathComponent()) } }

    /// Drops cached sizes for this folder and everything above/below it, then reloads.
    func invalidateAndReload() {
        let path = current.path
        sizeCache = sizeCache.filter { !$0.key.path.hasPrefix(path) && !path.hasPrefix($0.key.path) }
        reload()
    }

    func reload() {
        loadTask?.cancel()
        selection = []
        let url = current
        let hidden = showHidden
        loadTask = Task {
            let listed = await Task.detached { FileOps.list(url, showHidden: hidden) }.value
            guard !Task.isCancelled else { return }
            unreadable = listed == nil
            items = (listed ?? []).map { item in
                var item = item
                if item.isDirectory { item.size = sizeCache[item.url] }
                return item
            }
            sortItems()

            var queue = items.filter { $0.isDirectory && $0.size == nil }.map(\.url)[...]
            pending = queue.count
            await withTaskGroup(of: (URL, Int64).self) { group in
                for _ in 0..<6 {
                    guard let next = queue.popFirst() else { break }
                    group.addTask { (next, FileOps.size(of: next)) }
                }
                for await (folder, bytes) in group {
                    guard !Task.isCancelled else { group.cancelAll(); break }
                    sizeCache[folder] = bytes
                    if let index = items.firstIndex(where: { $0.url == folder }) { items[index].size = bytes }
                    pending -= 1
                    sortItems()
                    if let next = queue.popFirst() {
                        group.addTask { (next, FileOps.size(of: next)) }
                    }
                }
            }
            if !Task.isCancelled { pending = 0 }
        }
    }

    private func sortItems() {
        items.sort { ($0.size ?? -1, $1.name) > ($1.size ?? -1, $0.name) }
    }
}
