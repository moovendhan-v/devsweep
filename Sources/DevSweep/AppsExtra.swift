// Appcast parsing, extension catalog, Launch Services handler editing and app-reset rules adapted from
// Mac Sai (https://github.com/iliyami/MacSai), Copyright (c) 2026, Mac Sai Contributors, BSD 3-Clause License.
import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

// MARK: - Updater

struct AppUpdate: Identifiable, Hashable, Sendable {
    enum Source: String, Sendable { case sparkle = "App's update feed", homebrew = "Homebrew", appStore = "App Store" }
    let name: String
    let appURL: URL?
    let current: String
    let available: String
    let source: Source
    let downloadURL: URL?
    let caskToken: String?
    var id: String { "\(source.rawValue)|\(name)" }
}

@MainActor
@Observable
final class UpdaterModel {
    private(set) var updates: [AppUpdate] = []
    private(set) var isChecking = false
    private(set) var status = ""
    private(set) var checkedApps = 0
    private(set) var lastCheck: Date?
    var updatingCask: String?

    func check() async {
        isChecking = true
        updates = []
        status = "Reading update feeds…"
        async let sparkle = Self.sparkleUpdates()
        async let brew = Self.brewUpdates()
        let (feedUpdates, count) = await sparkle
        checkedApps = count
        status = "Asking Homebrew…"
        let caskUpdates = await brew
        let caskNames = Set(caskUpdates.map { $0.name.lowercased() })
        updates = (caskUpdates + feedUpdates.filter { !caskNames.contains($0.name.lowercased()) })
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        lastCheck = .now
        status = ""
        isChecking = false
    }

    func install(_ update: AppUpdate) async -> String {
        switch update.source {
        case .homebrew:
            guard let token = update.caskToken else { return "No cask name" }
            updatingCask = token
            let result = await Task.detached { FileOps.run("brew upgrade --cask \(token)", timeout: 1800) }.value
            updatingCask = nil
            if result.ok { updates.removeAll { $0.id == update.id } }
            return result.ok ? "✓ Updated \(update.name) to \(update.available)" : "✗ \(update.name): \(result.output.suffix(300))"
        case .appStore:
            NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!)
            return "Opened the App Store"
        case .sparkle:
            if let url = update.downloadURL, url.scheme == "https" {
                NSWorkspace.shared.open(url)
                return "Downloading \(update.name) \(update.available) in your browser"
            }
            if let app = update.appURL { _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: .init()) }
            return "Opened \(update.name). Use its “Check for Updates…” menu."
        }
    }

    /// Reads each third-party app's Sparkle feed (version info only).
    nonisolated static func sparkleUpdates() async -> ([AppUpdate], Int) {
        let apps = AppsModel.findApps()
        var candidates: [(InstalledApp, URL, Bool)] = []
        for app in apps {
            guard let bundle = Bundle(url: app.url) else { continue }
            let mas = FileManager.default.fileExists(atPath: app.url.appendingPathComponent("Contents/_MASReceipt/receipt").path)
            if let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String, let url = URL(string: feed), url.scheme == "https" {
                candidates.append((app, url, mas))
            }
        }
        let results = await withTaskGroup(of: AppUpdate?.self) { group in
            for (app, feed, _) in candidates {
                group.addTask {
                    var request = URLRequest(url: feed, timeoutInterval: 15)
                    request.setValue("DevSweep update check", forHTTPHeaderField: "User-Agent")
                    guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
                    let parsed = AppcastParser().latest(from: data)
                    guard let latest = parsed.version, let current = app.version,
                          Version.isNewer(latest, than: current) else { return nil }
                    return AppUpdate(name: app.name, appURL: app.url, current: current, available: latest,
                                     source: .sparkle, downloadURL: parsed.url, caskToken: nil)
                }
            }
            var found: [AppUpdate] = []
            for await update in group { if let update { found.append(update) } }
            return found
        }
        return (results, candidates.count)
    }

    /// `brew outdated --cask --greedy`: catches apps that auto-update themselves too.
    nonisolated static func brewUpdates() async -> [AppUpdate] {
        let result = FileOps.run("command -v brew >/dev/null || exit 3; brew outdated --cask --greedy --json=v2", timeout: 180)
        guard result.ok, let start = result.output.firstIndex(of: "{"),
              let data = String(result.output[start...]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = json["casks"] as? [[String: Any]] else { return [] }
        return casks.compactMap { cask in
            guard let token = cask["name"] as? String else { return nil }
            func clean(_ v: String) -> String { String(v.split(separator: ",").first ?? Substring(v)) }
            let installed = clean((cask["installed_versions"] as? [String])?.last ?? "?")
            let current = clean(cask["current_version"] as? String ?? "?")
            guard installed != current, current != "latest" else { return nil }
            return AppUpdate(name: token, appURL: nil, current: installed, available: current,
                             source: .homebrew, downloadURL: nil, caskToken: token)
        }
    }
}

/// Picks the newest item in a Sparkle appcast (ignores delta updates).
final class AppcastParser: NSObject, XMLParserDelegate {
    private var best: (version: String, url: URL?)?
    private var inItem = false, inDeltas = false
    private var itemVersion: String?, itemShort: String?, itemURL: URL?
    private var capture: String?, text = ""

    func latest(from data: Data) -> (version: String?, url: URL?) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return (best?.version, best?.url)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch name {
        case "item": inItem = true; itemVersion = nil; itemShort = nil; itemURL = nil
        case "sparkle:deltas": inDeltas = true
        case "enclosure" where inItem && !inDeltas:
            itemURL = itemURL ?? attributes["url"].flatMap(URL.init(string:))
            itemShort = itemShort ?? attributes["sparkle:shortVersionString"]
            itemVersion = itemVersion ?? attributes["sparkle:version"]
        case "sparkle:shortVersionString", "sparkle:version": if inItem && !inDeltas { capture = name; text = "" }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if capture != nil { text += string } }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == capture {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "sparkle:shortVersionString" { itemShort = value } else { itemVersion = value }
            capture = nil
        }
        if name == "sparkle:deltas" { inDeltas = false }
        if name == "item" {
            inItem = false
            if let version = itemShort ?? itemVersion, best == nil || Version.isNewer(version, than: best!.version) {
                best = (version, itemURL)
            }
        }
    }
}

enum Version {
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
        let y = b.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

// MARK: - Extensions (preference panes, plug-ins, Safari, Quick Look, Spotlight, system extensions)

struct ManagedExtension: Identifiable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case preferencePane = "Preference Panes", internetPlugin = "Internet Plug-Ins", quickLook = "Quick Look Plug-ins",
             spotlight = "Spotlight Importers", appExtension = "App Extensions", audio = "Audio Plug-ins"
        var symbol: String {
            switch self {
            case .preferencePane: "gearshape.2"
            case .internetPlugin: "globe"
            case .quickLook: "eye"
            case .spotlight: "magnifyingglass"
            case .appExtension: "puzzlepiece.extension"
            case .audio: "waveform"
            }
        }
    }
    let kind: Kind
    let name: String
    let bundleID: String
    let url: URL
    let enabled: Bool?
    let canTrash: Bool
    var id: String { url.path + bundleID }
}

@MainActor
@Observable
final class ExtensionsModel {
    private(set) var items: [ManagedExtension] = []
    private(set) var isLoading = false

    func load() async {
        isLoading = true
        items = await Task.detached { ExtensionsModel.find() }.value
        isLoading = false
    }

    /// Enables or disables an app extension through pluginkit.
    func setEnabled(_ item: ManagedExtension, _ on: Bool) async {
        _ = await Task.detached { FileOps.run("/usr/bin/pluginkit -e \(on ? "use" : "ignore") -i '\(item.bundleID)'", timeout: 10) }.value
        await load()
    }

    nonisolated static func find() -> [ManagedExtension] {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        var found: [ManagedExtension] = []
        func bundleItems(_ kind: ManagedExtension.Kind, _ dirs: [String], _ exts: Set<String>) {
            for dir in dirs {
                for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where exts.contains((name as NSString).pathExtension.lowercased()) {
                    let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
                    let bundle = Bundle(url: url)
                    let id = bundle?.bundleIdentifier ?? ""
                    guard !id.hasPrefix("com.apple.") else { continue }
                    let display = (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
                    found.append(ManagedExtension(kind: kind, name: display, bundleID: id, url: url, enabled: nil,
                                                  canTrash: dir.hasPrefix(home)))
                }
            }
        }
        bundleItems(.preferencePane, [home + "/Library/PreferencePanes", "/Library/PreferencePanes"], ["prefpane"])
        bundleItems(.internetPlugin, [home + "/Library/Internet Plug-Ins", "/Library/Internet Plug-Ins"], ["plugin", "webplugin"])
        bundleItems(.quickLook, [home + "/Library/QuickLook", "/Library/QuickLook"], ["qlgenerator"])
        bundleItems(.spotlight, [home + "/Library/Spotlight", "/Library/Spotlight"], ["mdimporter"])
        bundleItems(.audio, [home + "/Library/Audio/Plug-Ins/Components", "/Library/Audio/Plug-Ins/Components",
                             home + "/Library/Audio/Plug-Ins/HAL", "/Library/Audio/Plug-Ins/HAL"], ["component", "driver", "vst", "vst3"])

        // App extensions registered with pluginkit (Finder Sync, Share, Widgets, Quick Look previews…)
        let output = FileOps.run("/usr/bin/pluginkit -m -v -A", timeout: 15).output
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let flag = trimmed.first else { continue }
            let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            let columns = rest.split(separator: "\t").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard let idColumn = columns.first else { continue }
            let id = idColumn.components(separatedBy: "(").first?.trimmingCharacters(in: .whitespaces) ?? idColumn
            guard !id.hasPrefix("com.apple."), let path = columns.last(where: { $0.hasPrefix("/") }),
                  path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") else { continue }
            let url = URL(fileURLWithPath: path)
            let name = (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            found.append(ManagedExtension(kind: .appExtension, name: name, bundleID: id, url: url,
                                          enabled: flag == "-" ? false : flag == "+" ? true : nil, canTrash: false))
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.id).inserted }.sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
    }
}

// MARK: - Default apps (Launch Services handlers)

struct HandlerEntry: Identifiable, Hashable {
    let id = UUID()
    let raw: [String: String]
    var urlScheme: String? { raw["LSHandlerURLScheme"] }
    var contentType: String? { raw["LSHandlerContentType"] }
    var contentTag: String? { raw["LSHandlerContentTag"] }
    var bundleID: String? { raw["LSHandlerRoleAll"] ?? raw["LSHandlerRoleViewer"] ?? raw["LSHandlerRoleEditor"] }

    var title: String {
        if let scheme = urlScheme { return "\(scheme)://" }
        if let tag = contentTag { return ".\(tag)" }
        if let type = contentType {
            return UTTypeDescription(type) ?? type
        }
        return "?"
    }

    var subtitle: String { urlScheme != nil ? "Links" : contentType ?? contentTag ?? "" }

    var appURL: URL? { bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } }

    private func UTTypeDescription(_ identifier: String) -> String? {
        let description = UTType(identifier)?.localizedDescription ?? ""
        return description.isEmpty ? nil : description
    }
}

@MainActor
@Observable
final class DefaultAppsModel {
    private(set) var handlers: [HandlerEntry] = []
    private(set) var backups: [URL] = []

    private var plistPath: String {
        NSHomeDirectory() + "/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist"
    }

    private var backupDir: URL {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/DevSweep/LaunchServicesBackups")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func load() {
        let entries = (NSDictionary(contentsOfFile: plistPath)?["LSHandlers"] as? [[String: Any]]) ?? []
        handlers = entries.map { HandlerEntry(raw: $0.compactMapValues { $0 as? String }) }
            .filter { $0.bundleID != nil && ($0.urlScheme != nil || $0.contentType != nil || $0.contentTag != nil) }
            .sorted { ($0.urlScheme == nil ? 1 : 0, $0.title) < ($1.urlScheme == nil ? 1 : 0, $1.title) }
        backups = ((try? FileManager.default.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "plist" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Removes a custom "open with" rule (backs up the plist first); macOS falls back to its default app.
    func remove(_ entry: HandlerEntry) -> String {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        try? fm.copyItem(atPath: plistPath, toPath: backupDir.appendingPathComponent("launchservices-\(stamp).plist").path)
        guard let plist = NSMutableDictionary(contentsOfFile: plistPath),
              let list = plist["LSHandlers"] as? [[String: Any]] else { return "✗ Couldn't read Launch Services settings" }
        let filtered = list.filter { ($0.compactMapValues { $0 as? String }) != entry.raw }
        plist["LSHandlers"] = filtered
        guard plist.write(toFile: plistPath, atomically: true) else { return "✗ Couldn't save Launch Services settings" }
        _ = FileOps.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -gc", timeout: 30)
        load()
        return "✓ Removed default app for \(entry.title). Log out and back in if Finder still uses the old app."
    }

    func restore(_ backup: URL) -> String {
        do {
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: plistPath), withItemAt: copyToTemp(backup))
            load()
            return "✓ Restored default apps from \(backup.lastPathComponent)"
        } catch {
            return "✗ Restore failed: \(error.localizedDescription)"
        }
    }

    private func copyToTemp(_ url: URL) throws -> URL {
        let temp = URL(fileURLWithPath: plistPath).deletingLastPathComponent().appendingPathComponent(".restore-\(UUID().uuidString).plist")
        try FileManager.default.copyItem(at: url, to: temp)
        return temp
    }
}

// MARK: - Reset an app to defaults

enum AppReset {
    /// Library folders whose app-owned items are safe to delete while keeping the app (settings & caches).
    static let resettableRoots = ["Caches", "Preferences", "Saved Application State", "Logs", "Cookies", "HTTPStorages", "WebKit"]

    static func isResettable(_ url: URL) -> Bool {
        let library = NSHomeDirectory() + "/Library/"
        return resettableRoots.contains { SafetyGuard.isInside(url.path, library + $0) }
    }
}
