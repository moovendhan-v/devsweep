// Junk categories (mail attachments, iOS backups, old updates, broken preferences / login items, orphans,
// deleted users, language files, universal-binary thinning, simulators) adapted from Mac Sai
// (https://github.com/iliyami/MacSai), Copyright (c) 2026, Mac Sai Contributors, BSD 3-Clause License.
import AppKit
import Foundation

enum DiscoveryExtra {
    private static let home = NSHomeDirectory()
    private static let fm = FileManager.default

    static func targets() -> [CleanTarget] {
        var result: [CleanTarget] = []
        result += mail()
        result += backupsAndInstallers()
        result += broken()
        result += simulators()
        result += slimming()
        return result
    }

    // MARK: Mail

    private static func mail() -> [CleanTarget] {
        let paths = [home + "/Library/Mail Downloads",
                     home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
                     home + "/Library/Containers/com.microsoft.Outlook/Data/Library/Caches",
                     home + "/Library/Containers/com.readdle.smartemail-Mac/Data/Library/Caches",
                     home + "/Library/Group Containers/UBF8T346G9.Office/Outlook/Outlook 15 Profiles/Main Profile/Files/S0/1/Attachments"]
            .filter { fm.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return [] }
        return [CleanTarget(id: "mail-attachments", name: "Mail Attachment Copies",
                            detail: "Attachments Mail, Outlook and Spark saved on disk. IMAP/Exchange mail re-downloads them; POP accounts can't.",
                            group: .mail, paths: paths, risk: .caution, source: .discovered,
                            appURL: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail"))]
    }

    // MARK: Backups, old installers, temp

    private static func backupsAndInstallers() -> [CleanTarget] {
        var result: [CleanTarget] = []
        let month = Date.now.addingTimeInterval(-30 * 86_400)
        let week = Date.now.addingTimeInterval(-7 * 86_400)
        let day = Date.now.addingTimeInterval(-86_400)

        let backups = children(home + "/Library/Application Support/MobileSync/Backup").filter { modified($0) < month }
        if !backups.isEmpty {
            result.append(CleanTarget(id: "ios-backups", name: "Old iPhone & iPad Backups",
                                      detail: "\(backups.count) local backup\(backups.count == 1 ? "" : "s") older than 30 days. Keep one if it's a device's only backup.",
                                      group: .downloads, paths: backups.map(\.path), risk: .caution, source: .discovered, mode: .items))
        }

        var packages: [URL] = []
        if let enumerator = fm.enumerator(at: URL(fileURLWithPath: home + "/Library/Application Support"),
                                          includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                if enumerator.level > 3 { enumerator.skipDescendants(); continue }
                if ["pkg", "mpkg"].contains(url.pathExtension.lowercased()), modified(url) < week { packages.append(url) }
            }
        }
        if !packages.isEmpty {
            result.append(CleanTarget(id: "old-updates", name: "Old Update Packages",
                                      detail: "\(packages.count) installer package\(packages.count == 1 ? "" : "s") apps downloaded over a week ago.",
                                      group: .downloads, paths: packages.map(\.path), source: .discovered, mode: .items))
        }

        let temp = children(NSTemporaryDirectory()).filter { modified($0) < day && !$0.lastPathComponent.hasPrefix("com.apple") }
        if !temp.isEmpty {
            result.append(CleanTarget(id: "temp-files", name: "Old Temporary Files",
                                      detail: "Your temporary folder's items untouched for over a day.",
                                      group: .downloads, paths: temp.map(\.path), source: .discovered, mode: .items))
        }
        return result
    }

    // MARK: Broken & orphaned

    private static func broken() -> [CleanTarget] {
        var result: [CleanTarget] = []

        let prefs = children(home + "/Library/Preferences").filter { url in
            url.pathExtension == "plist" && !url.lastPathComponent.hasPrefix("com.apple.") && !url.lastPathComponent.hasPrefix(".GlobalPreferences")
                && (try? PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)) == nil
        }
        if !prefs.isEmpty {
            result.append(CleanTarget(id: "broken-prefs", name: "Corrupt Preference Files",
                                      detail: "Settings files that can't be read. Their apps recreate fresh ones.",
                                      group: .broken, paths: prefs.map(\.path), source: .discovered, mode: .items))
        }

        let agents = children(home + "/Library/LaunchAgents").filter { url in
            guard url.pathExtension == "plist" else { return false }
            guard let plist = NSDictionary(contentsOf: url) else { return true }
            let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
            guard let program else { return false }
            let resolved = program.hasPrefix("/") ? program : ["/usr/bin", "/bin", "/usr/sbin", "/sbin"].map { "\($0)/\(program)" }.first { fm.fileExists(atPath: $0) } ?? "/missing"
            return !fm.fileExists(atPath: resolved)
        }
        if !agents.isEmpty {
            result.append(CleanTarget(id: "broken-login-items", name: "Broken Login Items",
                                      detail: "Launch agents pointing at apps or tools that no longer exist.",
                                      group: .broken, paths: agents.map(\.path), source: .discovered, mode: .items))
        }

        let installed = installedBundleIDs()
        var orphans: [URL] = []
        for root in ["Caches", "Logs", "HTTPStorages", "Saved Application State", "WebKit"] {
            for url in children(home + "/Library/" + root) {
                let id = url.lastPathComponent.replacingOccurrences(of: ".savedState", with: "").lowercased()
                if isOrphan(id, installed: installed) { orphans.append(url) }
            }
        }
        if !orphans.isEmpty {
            result.append(CleanTarget(id: "app-leftovers", name: "Leftovers from Deleted Apps",
                                      detail: "\(orphans.count) cache/log folders named after apps that aren't installed any more.",
                                      group: .broken, paths: orphans.map(\.path), risk: .caution, source: .discovered, mode: .items))
        }

        let active = Set(FileOps.run("/usr/bin/dscl . -list /Users", timeout: 10).output
            .split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("_") })
        if !active.isEmpty {
            let residual = children("/Users").filter { url in
                let name = url.lastPathComponent
                return !["Shared", "Guest", ".localized", NSUserName()].contains(name) && !name.hasPrefix(".") && !active.contains(name)
            }
            if !residual.isEmpty {
                result.append(CleanTarget(id: "deleted-users", name: "Deleted Users' Folders",
                                          detail: "Home folders of accounts no longer on this Mac. Check each name. Removing them needs admin rights.",
                                          group: .broken, paths: residual.map(\.path), risk: .caution, source: .discovered, mode: .items))
            }
        }
        return result
    }

    static func installedBundleIDs() -> Set<String> {
        var ids = Set<String>()
        for root in ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities", home + "/Applications"] {
            for app in children(root) where app.pathExtension == "app" {
                if let id = Bundle(url: app)?.bundleIdentifier { ids.insert(id.lowercased()) }
            }
            for folder in children(root) where folder.pathExtension.isEmpty {
                for app in children(folder.path) where app.pathExtension == "app" {
                    if let id = Bundle(url: app)?.bundleIdentifier { ids.insert(id.lowercased()) }
                }
            }
        }
        return ids
    }

    /// A bundle-ID-shaped name with no installed app sharing its lineage (helpers count as the app).
    static func isOrphan(_ id: String, installed: Set<String>) -> Bool {
        let parts = id.split(separator: ".")
        guard parts.count >= 3, id.allSatisfy({ $0.isLetter || $0.isNumber || ".-_".contains($0) }) else { return false }
        let never = ["com.apple.", "org.chromium.", "com.google.keystone", "org.qt-project.", "com.github.electron", "com.electron.",
                     "com.teamnova."]
        if never.contains(where: { id.hasPrefix($0) }) { return false }
        var base = id
        for suffix in [".helper", ".agent", ".daemon", ".launcher", ".updater", ".shipit", ".loginitem", ".xpc", ".service"] where base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
        }
        return !installed.contains { $0 == id || $0 == base || $0.hasPrefix(base + ".") || base.hasPrefix($0 + ".") }
    }

    // MARK: Simulators

    private static func simulators() -> [CleanTarget] {
        let check = FileOps.run("xcrun simctl help >/dev/null 2>&1 && xcrun simctl runtime list -j 2>/dev/null", timeout: 15)
        guard check.ok, let data = check.output.data(using: .utf8),
              let runtimes = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [] }
        var newest: [String: String] = [:]
        for runtime in runtimes.values {
            guard let platform = runtime["platformIdentifier"] as? String, let version = runtime["version"] as? String else { continue }
            if let current = newest[platform], !Version.isNewer(version, than: current) { continue }
            newest[platform] = version
        }
        return runtimes.compactMap { key, runtime in
            guard runtime["deletable"] as? Bool == true, let platform = runtime["platformIdentifier"] as? String,
                  let version = runtime["version"] as? String, let top = newest[platform], Version.isNewer(top, than: version),
                  UUID(uuidString: runtime["identifier"] as? String ?? key) != nil else { return nil }
            let id = runtime["identifier"] as? String ?? key
            let name = (platform.components(separatedBy: ".").last ?? platform).replacingOccurrences(of: "simulator", with: "")
            return CleanTarget(id: "sim-runtime-" + id, name: "Old \(name) \(version) Simulator Runtime",
                               detail: "Superseded by \(top). Re-download from Xcode if you need to test on it.",
                               group: .apple, risk: .caution, command: "xcrun simctl runtime delete \(id)",
                               source: .tool("xcrun simctl runtime list"),
                               reportedSize: (runtime["sizeBytes"] as? NSNumber)?.int64Value ?? 0)
        }
    }

    // MARK: App slimming (language files, universal binaries)

    private static func slimming() -> [CleanTarget] {
        var result: [CleanTarget] = []
        let apps = (children("/Applications") + children(home + "/Applications")).filter { app in
            guard app.pathExtension == "app", let bundle = Bundle(url: app), let id = bundle.bundleIdentifier else { return false }
            return !id.hasPrefix("com.apple.") && !fm.fileExists(atPath: app.appendingPathComponent("Contents/_MASReceipt").path)
                && fm.isWritableFile(atPath: app.path)
        }

        // Unused languages
        let keep = Set(Locale.preferredLanguages.flatMap { code -> [String] in
            let base = String(code.split(separator: "-").first ?? Substring(code))
            return [code, base, code.replacingOccurrences(of: "-", with: "_")]
        } + ["Base", "en", "English", "en_US", "en_GB"])
        var lproj: [URL] = []
        for app in apps {
            for url in children(app.appendingPathComponent("Contents/Resources").path) where url.pathExtension == "lproj" {
                if !keep.contains(url.deletingPathExtension().lastPathComponent) { lproj.append(url) }
            }
        }
        if !lproj.isEmpty {
            result.append(CleanTarget(id: "language-files", name: "Unused App Languages",
                                      detail: "\(lproj.count) translations you don't use, inside \(Set(lproj.map { $0.pathComponents.prefix(3).joined(separator: "/") }).count) apps. Modifies apps; reinstall to undo. Some apps refuse to launch after their bundle changes.",
                                      group: .slimming, paths: lproj.map(\.path), risk: .caution, source: .discovered, mode: .items))
        }

        // Universal binaries
        var fat: [String] = []
        var savings: Int64 = 0
        for app in apps {
            guard let exec = Bundle(url: app)?.executableURL else { continue }
            let archs = AppSlimming.architectures(exec)
            guard archs.count > 1, archs.contains(AppSlimming.hostArch), !archs.contains("arm64e") else { continue }
            let size = FileOps.size(of: exec)
            savings += size * Int64(archs.count - 1) / Int64(archs.count)
            fat.append(app.path)
        }
        if !fat.isEmpty {
            result.append(CleanTarget(id: "universal-binaries", name: "Universal Apps (strip \(AppSlimming.hostArch == "arm64" ? "Intel" : "Apple Silicon") code)",
                                      detail: "\(fat.count) apps carry code for both chip types. Thinning removes the half this Mac never runs. Changes apps in place; reinstall to undo.",
                                      group: .slimming, paths: fat, risk: .caution, source: .discovered, mode: .thin, reportedSize: savings))
        }
        return result
    }

    // MARK: Helpers

    static func children(_ path: String) -> [URL] {
        (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.contentModificationDateKey],
                                     options: [.skipsHiddenFiles])) ?? []
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now
    }
}

/// Thins universal app bundles to this Mac's architecture with `lipo` (keeps per-slice signatures).
enum AppSlimming {
    static var hostArch: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    static func architectures(_ binary: URL) -> [String] {
        let output = FileOps.run("/usr/bin/lipo -archs '\(binary.path.replacingOccurrences(of: "'", with: "'\\''"))'", timeout: 10)
        return output.ok ? output.output.split(separator: " ").map(String.init) : []
    }

    /// Thins every fat Mach-O inside the bundle. Returns an error message or nil.
    static func thin(_ app: URL) -> String? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: app.appendingPathComponent("Contents"),
                                             includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return "Can't read \(app.lastPathComponent)" }
        var failures: [String] = []
        var thinned = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, isFat(url) else { continue }
            let archs = architectures(url)
            guard archs.count > 1, archs.contains(hostArch), !archs.contains("arm64e") else { continue }
            let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).thin-\(UUID().uuidString)")
            let quoted = { (u: URL) in "'\(u.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
            let result = FileOps.run("/usr/bin/lipo -thin \(hostArch) \(quoted(url)) -output \(quoted(temp))", timeout: 120)
            guard result.ok else { failures.append(url.lastPathComponent); try? fm.removeItem(at: temp); continue }
            let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) ?? 0o755
            try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: temp.path)
            if rename(temp.path, url.path) == 0 { thinned += 1 } else { failures.append(url.lastPathComponent); try? fm.removeItem(at: temp) }
        }
        return failures.isEmpty ? nil : "\(app.lastPathComponent): couldn't thin \(failures.prefix(3).joined(separator: ", "))"
    }

    private static func isFat(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        return [0xCAFE_BABE, 0xBEBA_FECA, 0xCAFE_BABF, 0xBFBA_FECA].contains(magic)
    }
}
