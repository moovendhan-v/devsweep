import AppKit
import Foundation

/// Builds the cache list at runtime instead of relying only on hard-coded paths:
///  1. asks installed tools where their caches live (`npm config get cache`, `uv cache dir`, …),
///  2. asks Docker how much it can reclaim,
///  3. scans ~/Library/Caches, ~/Library/Application Support (Electron/Chromium caches),
///     ~/.cache and ~/.<tool> folders for anything cache-shaped,
///  4. looks for unfinished downloads and old installers.
/// Anything already covered by another target is skipped, so nothing is counted twice.
enum Discovery {
    static let home = URL(fileURLWithPath: NSHomeDirectory())

    static func targets() async -> [CleanTarget] {
        async let probed = probeTools()
        async let docker = dockerTargets()
        async let hasGo = toolExists("go")
        async let hasSimctl = FileOps.run("xcrun simctl help >/dev/null 2>&1", timeout: 8).ok

        var targets = Catalog.targets
        for probe in await probed {
            if let index = targets.firstIndex(where: { $0.id == probe.id }) {
                var target = targets[index]
                target.paths = unique(probe.paths + target.urls.map(\.path))
                target.source = probe.source
                targets[index] = target
            } else {
                targets.append(probe)
            }
        }
        if await !hasGo { targets.removeAll { $0.id == "go-mod" } }
        if await !hasSimctl { targets.removeAll { $0.id == "unavailable-sims" } }
        targets += await docker

        let known = targets
        let discovered = await Task.detached { discoverOnDisk(excluding: known) }.value
        return targets + discovered
    }

    // MARK: - Tool probes

    private struct Probe: Sendable {
        let id: String
        let name: String
        let detail: String
        let group: TargetGroup
        let tool: String
        let query: String
        var risk: Risk = .safe
        var command: String? = nil
        /// Turns the tool's answer into the folders to clean.
        var paths: @Sendable (String) -> [String] = { [$0] }
    }

    private static let probes: [Probe] = [
        Probe(id: "npm", name: "npm Cache", detail: "Package tarball cache.", group: .javascript,
              tool: "npm", query: "npm config get cache", paths: { ["\($0)/_cacache"] }),
        Probe(id: "npx", name: "npx Cache & npm Logs", detail: "Packages downloaded by `npx` and old npm debug logs.",
              group: .javascript, tool: "npm", query: "npm config get cache", paths: { ["\($0)/_npx", "\($0)/_logs"] }),
        Probe(id: "yarn", name: "Yarn Cache", detail: "Yarn package cache.", group: .javascript,
              tool: "yarn", query: "yarn cache dir"),
        Probe(id: "pnpm", name: "pnpm Store", detail: "Content-addressable store. Projects re-link on next install.",
              group: .javascript, tool: "pnpm", query: "pnpm store path", risk: .caution),
        Probe(id: "deno", name: "Deno Cache", detail: "Remote modules and compiled cache. Re-fetched on next run.",
              group: .javascript, tool: "deno",
              query: #"deno info --json 2>/dev/null | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["denoDir"])'"#),
        Probe(id: "pip", name: "pip Cache", detail: "Python wheel and HTTP cache.", group: .languages,
              tool: "pip3", query: "pip3 cache dir"),
        Probe(id: "uv", name: "uv Cache", detail: "uv Python package cache.", group: .languages,
              tool: "uv", query: "uv cache dir"),
        Probe(id: "homebrew", name: "Homebrew Downloads", detail: "Cached bottles and source downloads.",
              group: .languages, tool: "brew", query: "brew --cache"),
        Probe(id: "composer", name: "Composer Cache", detail: "PHP package cache.", group: .languages,
              tool: "composer", query: "composer config --global cache-dir"),
        Probe(id: "conda", name: "Conda Package Cache", detail: "Downloaded conda packages. Cleaned with `conda clean --all -y`.",
              group: .languages, tool: "conda", query: "conda info --base", command: "conda clean --all -y",
              paths: { ["\($0)/pkgs"] }),
        Probe(id: "go-build", name: "Go Build Cache", detail: "Compiled package cache.", group: .languages,
              tool: "go", query: "go env GOCACHE"),
        Probe(id: "go-mod", name: "Go Module Cache", detail: "Downloaded modules. Removed with `go clean -modcache`.",
              group: .languages, tool: "go", query: "go env GOMODCACHE", risk: .caution, command: "go clean -modcache"),
        Probe(id: "cargo", name: "Cargo Registry Cache", detail: "Downloaded crate archives.", group: .languages,
              tool: "cargo", query: #"echo "${CARGO_HOME:-$HOME/.cargo}""#, paths: { ["\($0)/registry/cache"] }),
        Probe(id: "gradle", name: "Gradle Caches", detail: "Dependency and build caches. Next build re-downloads.",
              group: .jvm, tool: "gradle", query: #"echo "${GRADLE_USER_HOME:-$HOME/.gradle}""#, risk: .caution,
              paths: { ["\($0)/caches"] }),
    ]

    private static func probeTools() async -> [CleanTarget] {
        await withTaskGroup(of: CleanTarget?.self) { group in
            for probe in probes {
                group.addTask {
                    let result = FileOps.run("command -v \(probe.tool) >/dev/null 2>&1 || exit 3; \(probe.query)", timeout: 12)
                    guard result.ok, let answer = lastPath(in: result.output) else { return nil }
                    let paths = probe.paths(answer).filter { FileManager.default.fileExists(atPath: $0) }
                    guard !paths.isEmpty else { return nil }
                    return CleanTarget(id: probe.id, name: probe.name, detail: probe.detail, group: probe.group,
                                       paths: paths, risk: probe.risk, command: probe.command,
                                       source: .tool(probe.query.components(separatedBy: " 2>").first ?? probe.query))
                }
            }
            var results: [CleanTarget] = []
            for await target in group { if let target { results.append(target) } }
            return results
        }
    }

    private static func toolExists(_ tool: String) async -> Bool {
        FileOps.run("command -v \(tool) >/dev/null 2>&1", timeout: 8).ok
    }

    private static func lastPath(in output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
    }

    // MARK: - Docker

    private static func dockerTargets() async -> [CleanTarget] {
        let result = FileOps.run(
            "command -v docker >/dev/null 2>&1 || exit 3; docker system df --format '{{.Type}}|{{.Reclaimable}}'",
            timeout: 10)
        guard result.ok else { return [] }
        var reclaimable: [String: Int64] = [:]
        for line in result.output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            reclaimable[parts[0]] = parseDockerSize(parts[1])
        }
        guard !reclaimable.isEmpty else { return [] }

        func target(_ id: String, _ type: String, _ name: String, _ detail: String, _ command: String, _ risk: Risk) -> CleanTarget {
            CleanTarget(id: id, name: name, detail: detail, group: .system, risk: risk, command: command,
                        source: .tool("docker system df"), reportedSize: reclaimable[type] ?? 0)
        }
        return [
            target("docker-build", "Build Cache", "Docker Build Cache", "Layers cached by `docker build`.",
                   "docker builder prune -f", .safe),
            target("docker-containers", "Containers", "Stopped Docker Containers", "Containers that have exited.",
                   "docker container prune -f", .caution),
            target("docker-images", "Images", "Unused Docker Images", "Images no container uses. Pulled again when needed.",
                   "docker image prune -a -f", .caution),
            target("docker-volumes", "Local Volumes", "Unused Docker Volumes",
                   "Anonymous volumes not attached to a container. May contain old database data.",
                   "docker volume prune -f", .caution),
        ]
    }

    /// "822.5MB (36%)" → bytes (Docker uses decimal units).
    static func parseDockerSize(_ text: String) -> Int64 {
        let token = text.split(separator: " ").first.map(String.init) ?? ""
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (unit, factor) in units where token.hasSuffix(unit) {
            return Int64((Double(token.dropLast(unit.count)) ?? 0) * factor)
        }
        return 0
    }

    // MARK: - Disk discovery

    /// Caches that hold big downloads (browsers, ML models) — listed but not pre-selected.
    private static let heavyWords = ["playwright", "puppeteer", "cypress", "huggingface", "torch", "lm-studio",
                                     "whisper", "selenium", "ollama"]

    private static let skippedCaches: Set<String> = [
        "CloudKit", "GeoServices", "GameKit", "PassKit", "FamilyCircle", "INSTALLATION", "Caches",
        "com.teamnova.DevSweep",
    ]
    /// Folders that hold several products; each child becomes its own row.
    private static let vendorFolders: Set<String> = ["Google", "JetBrains", "Microsoft", "Mozilla", "BraveSoftware"]

    private static let electronCacheDirs = [
        "Cache", "Code Cache", "GPUCache", "CachedData", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
        "GrShaderCache", "ShaderCache", "CachedExtensionVSIXs", "Crashpad/completed", "logs",
        "Service Worker/CacheStorage", "Service Worker/ScriptCache", "component_crx_cache",
    ]
    private static let profileRoots = ["", "Default", "User Data/Default", "Partitions"]

    private static let dotFolderSkips: Set<String> = [
        ".Trash", ".ssh", ".gnupg", ".git", ".config", ".local", ".cache", ".docker", ".kube", ".aws",
        ".colima", ".lima", ".orbstack", ".vscode", ".cursor", ".zsh_sessions", ".oh-my-zsh", ".nvm", ".pyenv",
        ".rustup", ".m2", ".ollama", ".lmstudio",
    ]
    private static let dotCacheNames = ["cache", "caches", "_cacache", "logs", "log", "tmp", "temp"]

    static func discoverOnDisk(excluding known: [CleanTarget]) -> [CleanTarget] {
        // APFS is case-insensitive by default, so compare lowercased paths ("cache" == "Cache").
        var claimed = known.flatMap { $0.urls.map { $0.standardizedFileURL.path.lowercased() } }
        var result: [CleanTarget] = []

        func overlaps(_ path: String) -> Bool {
            claimed.contains { $0 == path || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
        }
        func add(_ target: CleanTarget) {
            var free: [String] = []
            for path in target.urls.map({ $0.standardizedFileURL.path }) where !overlaps(path.lowercased()) {
                free.append(path)
                claimed.append(path.lowercased())
            }
            guard !free.isEmpty else { return }
            var target = target
            target.paths = free
            result.append(target)
        }

        // 1. ~/Library/Caches/<app>
        let caches = home.appendingPathComponent("Library/Caches")
        for child in directories(in: caches) {
            let name = child.lastPathComponent
            guard !skippedCaches.contains(name), !name.hasPrefix("com.apple.") else { continue }
            let entries = vendorFolders.contains(name) ? directories(in: child).map { ($0, name) } : [(child, nil)]
            for (folder, vendor) in entries {
                let app = appInfo(for: folder.lastPathComponent, vendor: vendor)
                let group = classify(app.name + " " + folder.lastPathComponent) ?? .appCaches
                let heavy = heavyWords.contains { folder.lastPathComponent.lowercased().contains($0) }
                add(CleanTarget(id: "cache:" + folder.path, name: app.name,
                                detail: heavy ? "Downloaded browsers/models. Slow to download again · \(folder.tildePath)"
                                              : "Cache folder · \(folder.tildePath)",
                                group: group, paths: [folder.path], risk: heavy ? .caution : .safe,
                                source: .discovered, appURL: app.url))
            }
        }

        // 2. ~/Library/Application Support/<app>/{Cache, Code Cache, GPUCache, …}
        let support = home.appendingPathComponent("Library/Application Support")
        for child in directories(in: support) {
            let name = child.lastPathComponent
            guard !name.hasPrefix("com.apple."), !["CrashReporter", "Caches", "DevSweep"].contains(name) else { continue }
            let entries = vendorFolders.contains(name) ? directories(in: child).map { ($0, name) } : [(child, nil)]
            for (folder, vendor) in entries {
                let found = electronCaches(in: folder)
                guard !found.isEmpty else { continue }
                let app = appInfo(for: folder.lastPathComponent, vendor: vendor)
                let group = classify(app.name + " " + folder.lastPathComponent) ?? .webCaches
                add(CleanTarget(id: "support:" + folder.path, name: app.name,
                                detail: "\(found.count) web cache folder\(found.count == 1 ? "" : "s") · \(folder.tildePath)",
                                group: group, paths: found.map(\.path), source: .discovered, appURL: app.url))
            }
        }

        // 3. ~/.cache/<tool> (XDG)
        for child in directories(in: home.appendingPathComponent(".cache")) {
            let name = child.lastPathComponent
            let heavy = heavyWords.contains { name.lowercased().contains($0) }
            add(CleanTarget(id: "xdg:" + child.path, name: pretty(name) + " Cache",
                            detail: heavy ? "Downloaded models/data. Large to re-download." : "Tool cache · \(child.tildePath)",
                            group: classify(name) ?? .editors, paths: [child.path],
                            risk: heavy ? .caution : .safe, source: .discovered))
        }

        // 4. ~/.<tool>/{cache, logs, tmp} and one level deeper
        for dot in directories(in: home, includeHidden: true) where dot.lastPathComponent.hasPrefix(".") {
            let name = dot.lastPathComponent
            guard !dotFolderSkips.contains(name) else { continue }
            var found: [URL] = []
            for cacheName in dotCacheNames {
                let direct = dot.appendingPathComponent(cacheName)
                if isDirectory(direct) { found.append(direct) }
            }
            for sub in directories(in: dot, includeHidden: true) {
                for cacheName in dotCacheNames {
                    let nested = sub.appendingPathComponent(cacheName)
                    if isDirectory(nested) { found.append(nested) }
                }
            }
            for folder in found {
                let isLogs = ["logs", "log"].contains(folder.lastPathComponent)
                add(CleanTarget(id: "dot:" + folder.path,
                                name: "\(pretty(name)) \(isLogs ? "Logs" : folder.lastPathComponent.hasPrefix("t") ? "Temp Files" : "Cache")",
                                detail: "Auto-detected · \(folder.tildePath)",
                                group: classify(name) ?? .editors, paths: [folder.path],
                                risk: isLogs ? .safe : .caution, source: .discovered))
            }
        }

        // 5. ~/Downloads: unfinished downloads and installers
        let downloads = home.appendingPathComponent("Downloads")
        let files = (try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil)) ?? []
        let partial = files.filter { ["crdownload", "download", "part", "partial", "opdownload"].contains($0.pathExtension.lowercased()) }
        let installers = files.filter { ["dmg", "pkg", "mpkg", "xip", "iso"].contains($0.pathExtension.lowercased()) }
        if !partial.isEmpty {
            add(CleanTarget(id: "downloads-partial", name: "Unfinished Downloads",
                            detail: "\(partial.count) broken or abandoned download\(partial.count == 1 ? "" : "s").",
                            group: .downloads, paths: partial.map(\.path), source: .discovered, mode: .items))
        }
        if !installers.isEmpty {
            add(CleanTarget(id: "downloads-installers", name: "Installers & Disk Images",
                            detail: "\(installers.count) .dmg/.pkg file\(installers.count == 1 ? "" : "s") in Downloads you've probably already installed.",
                            group: .downloads, paths: installers.map(\.path), risk: .caution,
                            source: .discovered, mode: .items))
        }
        return result
    }

    // MARK: - Helpers

    private static func electronCaches(in folder: URL) -> [URL] {
        var found: [URL] = []
        for root in profileRoots {
            let base = root.isEmpty ? folder : folder.appendingPathComponent(root)
            if root == "Partitions" {
                for partition in directories(in: base) {
                    found += electronCacheDirs.map { partition.appendingPathComponent($0) }.filter(isDirectory)
                }
            } else {
                found += electronCacheDirs.map { base.appendingPathComponent($0) }.filter(isDirectory)
            }
        }
        return found
    }

    private static func directories(in url: URL, includeHidden: Bool = false) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: includeHidden ? [] : [.skipsHiddenFiles])) ?? []
        return items.filter { item in
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path }
            .filter { seen.insert($0).inserted }
    }

    /// Resolves a cache folder name ("com.tinyspeck.slackmacgap", "Chrome") to an app name and icon.
    static func appInfo(for folderName: String, vendor: String?) -> (name: String, url: URL?) {
        let workspace = NSWorkspace.shared
        let bundleID = folderName.replacingOccurrences(of: ".ShipIt", with: "")
        if bundleID.split(separator: ".").count >= 3, let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            return (FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                    + (folderName.hasSuffix(".ShipIt") ? " Updates" : ""), url)
        }
        let spaced = folderName.replacingOccurrences(of: "-", with: " ")
        let candidates = [folderName, spaced, vendor.map { "\($0) \(folderName)" }, vendor.map { "\(pretty($0)) \(spaced)" }]
            .compactMap { $0 }
        for candidate in candidates {
            for dir in ["/Applications", home.path + "/Applications"] {
                let url = URL(fileURLWithPath: "\(dir)/\(candidate).app")
                if FileManager.default.fileExists(atPath: url.path) { return (candidate, url) }
            }
        }
        let display = vendor.map { "\(pretty($0)) \(pretty(folderName))" } ?? pretty(folderName)
        return (display, nil)
    }

    private static let friendlyNames: [String: String] = [
        "ms-playwright": "Playwright Browsers", "node-gyp": "node-gyp Headers", "pnpm": "pnpm Metadata",
        "typescript": "TypeScript", "Cypress": "Cypress Binaries", "puppeteer": "Puppeteer Browsers",
        "electron": "Electron Downloads", "electron-builder": "electron-builder Cache", "vscode-ripgrep": "VS Code ripgrep",
    ]

    static func pretty(_ name: String) -> String {
        if let friendly = friendlyNames[name] { return friendly }
        var text = name
        if text.hasPrefix(".") { text.removeFirst() }
        let parts = text.split(separator: ".")
        if parts.count >= 3 {
            // "io.branch.network.cache" → "Branch": skip generic trailing words.
            let generic: Set<String> = ["cache", "caches", "network", "client", "app", "mac", "macos", "desktop", "helper"]
            text = String(parts.dropFirst().last { !generic.contains($0.lowercased()) } ?? parts.last!)
        }
        if text == "BraveSoftware" { return "Brave" }
        text = text.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private static let browserWords = ["chrome", "chromium", "brave", "firefox", "mozilla", "arc", "edge", "vivaldi",
                                       "opera", "comet", "safari", "duckduckgo", "orion", "zen", "thebrowser"]
    private static let groupWords: [(TargetGroup, [String])] = [
        (.system, ["docker", "colima", "podman", "orbstack", "lima", "vagrant", "virtualbox", "utm", "parallels",
                   "minikube", "rancher", "kube"]),
        (.apple, ["xcode", "swift", "swiftpm", "cocoapods", "carthage", "simulator", "instruments"]),
        (.jvm, ["gradle", "maven", "androidstudio", "android", "kotlin", "java", "jdk", "sbt", "coursier", "flutter", "dart"]),
        (.javascript, ["node", "nodejs", "npm", "yarn", "pnpm", "bun", "deno", "typescript", "prisma", "cypress",
                       "playwright", "puppeteer", "electron", "vite", "swc", "turbo", "webpack", "esbuild", "corepack", "next"]),
        (.languages, ["pip", "pypoetry", "poetry", "uv", "conda", "pyenv", "jupyter", "ipython", "cargo", "rust",
                      "go", "golang", "composer", "php", "ruby", "gem", "bundler", "huggingface", "torch", "matplotlib",
                      "pre", "ccache", "sccache", "bazel", "homebrew", "pylint", "mypy", "ruff", "black"]),
        (.editors, ["code", "vscode", "cursor", "windsurf", "zed", "jetbrains", "intellij", "pycharm", "webstorm",
                    "goland", "rider", "clion", "datagrip", "fleet", "sublime", "postman", "insomnia", "bruno",
                    "apidog", "github", "gitkraken", "gitahead", "sourcetree", "tower", "fork", "iterm", "warp", "kiro",
                    "trae", "qoder", "antigravity", "codex", "claude", "copilot", "codeium", "tabnine", "devin",
                    "opencode", "amazon", "codewhisperer", "ollama", "lmstudio", "lm studio", "pgadmin", "obsidian", "mongodb", "redis", "redisinsight",
                    "dbeaver", "tableplus", "aws", "gcloud", "azure", "terraform", "sentry", "devsense", "act",
                    "gemini", "anthropic", "openai", "cline", "continue", "aider"]),
    ]

    /// Maps a folder/app name to a developer group, a browser group, or nil (plain app cache).
    static func classify(_ text: String) -> TargetGroup? {
        let tokens = Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
        let joined = text.lowercased()
        func matches(_ word: String) -> Bool {
            word.count <= 4 ? tokens.contains(word) : joined.contains(word)
        }
        if browserWords.contains(where: matches) { return .webCaches }
        for (group, words) in groupWords where words.contains(where: matches) { return group }
        return nil
    }
}
