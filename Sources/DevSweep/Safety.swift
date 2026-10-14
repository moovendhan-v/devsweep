// Portions of the safety rules and restore logic are adapted from Mac Sai
// (https://github.com/iliyami/MacSai), Copyright (c) 2026, Mac Sai Contributors, BSD 3-Clause License.
import Foundation

/// Every deletion goes through here: refuses system paths, SIP, user-excluded folders and
/// symlinks that redirect somewhere unexpected.
enum SafetyGuard {
    enum Refusal: LocalizedError {
        case protected(String), excluded(String), redirect(String), invalid(String)

        var errorDescription: String? {
            switch self {
            case .protected(let p): "Protected system location: \(p)"
            case .excluded(let p): "Inside a folder you excluded in Settings: \(p)"
            case .redirect(let p): "Symlink points somewhere unexpected: \(p)"
            case .invalid(let p): "Invalid path: \(p)"
            }
        }
    }

    static let protectedPrefixes = ["/System", "/usr", "/bin", "/sbin", "/Library/Apple", "/private/var/db", "/var/db",
                                    "/Applications/Safari.app", "/Applications/Utilities"]

    /// Never delete these themselves (their contents are fine).
    static let protectedExact: Set<String> = [
        "/", "/Applications", "/Library", "/Users", "/Volumes", NSHomeDirectory(),
        NSHomeDirectory() + "/Library", NSHomeDirectory() + "/Desktop", NSHomeDirectory() + "/Documents",
        NSHomeDirectory() + "/Downloads", NSHomeDirectory() + "/Library/Caches",
        NSHomeDirectory() + "/Library/Application Support", NSHomeDirectory() + "/Library/Preferences",
    ]

    static func canonical(_ path: String) -> String {
        for link in ["var", "tmp", "etc"] {
            let prefix = "/private/\(link)"
            if path == prefix { return "/\(link)" }
            if path.hasPrefix(prefix + "/") { return "/\(link)" + path.dropFirst(prefix.count) }
        }
        return path
    }

    static func validate(_ url: URL) throws {
        let original = url.standardizedFileURL.path
        guard !original.isEmpty, !original.contains("\0") else { throw Refusal.invalid(original) }
        let resolved = canonical(url.resolvingSymlinksInPath().path)
        let originalCanonical = canonical(original)

        if protectedExact.contains(originalCanonical) || protectedExact.contains(resolved) {
            throw Refusal.protected(original)
        }
        for prefix in protectedPrefixes where resolved == prefix || resolved.hasPrefix(prefix + "/") {
            throw Refusal.protected(resolved)
        }
        for folder in ExcludedFolders.paths where isInside(resolved, folder) || isInside(originalCanonical, folder) {
            throw Refusal.excluded(original)
        }
        if originalCanonical != resolved,
           originalCanonical.split(separator: "/").prefix(2) != resolved.split(separator: "/").prefix(2) {
            throw Refusal.redirect(resolved)
        }
    }

    static func isInside(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

/// Folders the user never wants scanned or cleaned.
enum ExcludedFolders {
    private static let key = "excludedFolders"

    static var paths: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(Array(Set(newValue)).sorted(), forKey: key) }
    }

    static func contains(_ url: URL) -> Bool {
        let path = SafetyGuard.canonical(url.standardizedFileURL.path)
        return paths.contains { SafetyGuard.isInside(path, $0) }
    }
}

/// Remembers what went to the Trash so it can be put back with one click.
struct CleanSession: Codable, Identifiable, Hashable {
    struct Item: Codable, Hashable {
        let original: String
        let trashed: String
        let bytes: Int64
    }

    var id = UUID()
    let date: Date
    let label: String
    var items: [Item]

    var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    var restorable: [Item] { items.filter { FileManager.default.fileExists(atPath: $0.trashed) } }
}

enum CleanHistory {
    private static let lock = NSLock()
    private static var pending: [CleanSession.Item] = []

    static var fileURL: URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/DevSweep")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("clean-history.json")
    }

    static func note(original: URL, trashed: URL, bytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        pending.append(.init(original: original.path, trashed: trashed.path, bytes: bytes))
    }

    /// Turns everything trashed since the last commit into one history session.
    static func commit(label: String) {
        lock.lock()
        let items = pending
        pending = []
        lock.unlock()
        guard !items.isEmpty else { return }
        var sessions = load()
        sessions.insert(CleanSession(date: .now, label: label, items: Array(items.prefix(5000))), at: 0)
        save(sessions)
    }

    static func load() -> [CleanSession] {
        guard let data = try? Data(contentsOf: fileURL),
              let sessions = try? JSONDecoder().decode([CleanSession].self, from: data) else { return [] }
        let cutoff = Date.now.addingTimeInterval(-30 * 86_400)
        return sessions.filter { $0.date > cutoff }
    }

    static func save(_ sessions: [CleanSession]) {
        let pruned = Array(sessions.filter { !$0.restorable.isEmpty }.prefix(30))
        if let data = try? JSONEncoder().encode(pruned) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// Moves items back from the Trash to where they were. Skips anything that came back or was emptied.
    static func restore(_ session: CleanSession) -> (restored: Int, skipped: Int) {
        let fm = FileManager.default
        var restored = 0, skipped = 0
        var remaining: [CleanSession.Item] = []
        for item in session.items {
            guard fm.fileExists(atPath: item.trashed), !fm.fileExists(atPath: item.original),
                  SafetyGuard.isInside(item.trashed, NSHomeDirectory() + "/.Trash") || item.trashed.contains("/.Trashes/")
            else { skipped += 1; continue }
            do {
                try fm.createDirectory(at: URL(fileURLWithPath: item.original).deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.moveItem(atPath: item.trashed, toPath: item.original)
                restored += 1
            } catch {
                skipped += 1
                remaining.append(item)
            }
        }
        var sessions = load()
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index].items = remaining
        }
        save(sessions)
        return (restored, skipped)
    }
}
