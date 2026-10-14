import Foundation

enum TargetGroup: String, CaseIterable, Identifiable, Sendable {
    // Developer
    case apple = "Xcode & Apple"
    case javascript = "JavaScript"
    case languages = "Languages & Package Managers"
    case jvm = "JVM & Android"
    case editors = "Editors & Dev Tools"
    case system = "Containers & VMs"
    // System junk
    case appCaches = "App Caches"
    case webCaches = "Browser & Electron Caches"
    case logs = "Logs & Crash Reports"
    case mail = "Mail Attachments"
    case downloads = "Downloads, Backups & Installers"
    case broken = "Broken & Orphaned Files"
    case slimming = "App Slimming"

    var id: String { rawValue }

    var isDeveloper: Bool {
        switch self {
        case .apple, .javascript, .languages, .jvm, .editors, .system: true
        default: false
        }
    }

    static var developer: [TargetGroup] { allCases.filter(\.isDeveloper) }
    static var junk: [TargetGroup] { allCases.filter { !$0.isDeveloper } }

    var symbol: String {
        switch self {
        case .apple: "hammer"
        case .javascript: "curlybraces"
        case .languages: "shippingbox"
        case .jvm: "cup.and.saucer"
        case .editors: "chevron.left.forwardslash.chevron.right"
        case .system: "cube.transparent"
        case .appCaches: "square.stack.3d.up"
        case .webCaches: "globe"
        case .logs: "doc.text.magnifyingglass"
        case .downloads: "arrow.down.circle"
        case .mail: "paperclip"
        case .broken: "bandage"
        case .slimming: "scissors"
        }
    }
}

enum Risk: Sendable {
    /// Fully regenerated on next build / install.
    case safe
    /// Regenerable, but expensive to rebuild or occasionally useful (archives, dSYMs, big repos).
    case caution
}

/// Where a target came from — shown as a tag so users know why it's listed.
enum TargetSource: Hashable, Sendable {
    case builtIn
    /// Path reported by the tool itself, e.g. `npm config get cache`.
    case tool(String)
    /// Found by scanning the disk (app caches, Electron caches, dot-folder caches).
    case discovered
}

struct CleanTarget: Identifiable, Hashable, Sendable {
    enum Mode: Sendable {
        /// Empty the folder but keep it (default for cache dirs).
        case contents
        /// Remove the listed paths themselves (stray files such as broken downloads).
        case items
        /// Strip CPU architectures this Mac can't run from the listed app bundles (`lipo -thin`).
        case thin
    }

    let id: String
    var name: String
    var detail: String
    var group: TargetGroup
    var paths: [String] = []
    var risk: Risk = .safe
    /// Shell command used to clean instead of deleting files (e.g. `docker builder prune -f`).
    var command: String? = nil
    var source: TargetSource = .builtIn
    var mode: Mode = .contents
    /// App bundle to borrow an icon from.
    var appURL: URL? = nil
    /// Size reported by a tool when there's no folder to measure (Docker).
    var reportedSize: Int64? = nil

    var urls: [URL] {
        paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }

    var existingURLs: [URL] {
        urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Whether the user can drill into individual sub-folders.
    var supportsChildren: Bool { mode == .contents && command == nil }
}

/// A rebuildable folder found inside a user project (node_modules, .build, target, ...).
struct ProjectJunk: Identifiable, Hashable {
    let url: URL
    let kind: String
    let size: Int64
    let modified: Date?

    var id: URL { url }
    var projectName: String { url.deletingLastPathComponent().lastPathComponent }
}

/// One row in the Space Explorer.
struct FolderItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    var size: Int64?
    let modified: Date?

    var id: URL { url }
    var canOpen: Bool { isDirectory && !isPackage }
}

/// Folder tree of the project scan: intermediate folders lead down to junk leaves.
struct ProjectNode: Identifiable, Hashable {
    let url: URL
    let junk: ProjectJunk?
    let children: [ProjectNode]?
    let size: Int64
    let junkURLs: [URL]

    var id: URL { url }
    var name: String { url.lastPathComponent }

    static func tree(root: URL, items: [ProjectJunk]) -> [ProjectNode] {
        final class Trie {
            var children: [String: Trie] = [:]
            var junk: ProjectJunk?
        }
        let rootTrie = Trie()
        let baseCount = root.standardizedFileURL.pathComponents.count
        for item in items {
            var node = rootTrie
            for component in item.url.standardizedFileURL.pathComponents.dropFirst(baseCount) {
                if let next = node.children[component] {
                    node = next
                } else {
                    let next = Trie()
                    node.children[component] = next
                    node = next
                }
            }
            node.junk = item
        }

        func convert(_ trie: Trie, url: URL) -> ProjectNode {
            let kids = trie.children
                .map { convert($0.value, url: url.appendingPathComponent($0.key)) }
                .sorted { $0.size > $1.size }
            if let junk = trie.junk {
                return ProjectNode(url: url, junk: junk, children: nil, size: junk.size, junkURLs: [junk.url])
            }
            return ProjectNode(url: url, junk: nil, children: kids.isEmpty ? nil : kids,
                               size: kids.reduce(0) { $0 + $1.size }, junkURLs: kids.flatMap(\.junkURLs))
        }
        return convert(rootTrie, url: root).children ?? []
    }
}

extension Int64 {
    var byteString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

extension URL {
    var tildePath: String { (path as NSString).abbreviatingWithTildeInPath }
}
