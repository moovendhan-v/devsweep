import Foundation

/// Disk work that runs off the main actor.
enum FileOps {
    static func size(of url: URL) -> Int64 {
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]),
           values.isDirectory == false {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        var count = 0
        for case let file as URL in enumerator {
            count += 1
            if count % 1000 == 0, Task.isCancelled { break }
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Immediate children of a folder; directory sizes are left nil for the caller to fill in.
    /// Returns nil when the folder can't be read (usually missing Full Disk Access).
    static func list(_ url: URL, showHidden: Bool) -> [FolderItem]? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
                                      .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: showHidden ? [] : [.skipsHiddenFiles]
        ) else { return nil }

        return urls.map { child in
            let values = try? child.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory == true && values?.isSymbolicLink != true
            let fileSize = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            return FolderItem(url: child, name: child.lastPathComponent, isDirectory: isDirectory,
                              isPackage: values?.isPackage == true,
                              size: isDirectory ? nil : fileSize, modified: values?.contentModificationDate)
        }
    }

    static func size(of urls: [URL]) -> Int64 {
        urls.reduce(0) { $0 + size(of: $1) }
    }

    /// Removes everything *inside* `url`, keeping the folder itself.
    static func clearContents(of url: URL, toTrash: Bool) -> [String] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            return ["Could not read \(url.path)"]
        }
        return children.compactMap { remove($0, toTrash: toTrash) }
    }

    /// Returns an error message, or nil on success.
    static func remove(_ url: URL, toTrash: Bool) -> String? {
        do {
            try SafetyGuard.validate(url)
            if toTrash {
                let bytes = size(of: url)
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                if let trashed = resulting as URL? { CleanHistory.note(original: url, trashed: trashed, bytes: bytes) }
            } else {
                try FileManager.default.removeItem(at: url)
            }
            return nil
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return nil
        } catch {
            return "\(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Runs a command through a login shell so Homebrew / nvm / Docker paths resolve.
    /// Killed after `timeout` seconds. Runs from $HOME with corepack downloads disabled so
    /// probing never installs anything.
    static func run(_ command: String, timeout: TimeInterval = 600) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        var env = ProcessInfo.processInfo.environment
        env["COREPACK_ENABLE_NETWORK"] = "0"
        env["COREPACK_ENABLE_DOWNLOAD_PROMPT"] = "0"
        env["NO_COLOR"] = "1"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let collector = OutputCollector()
        pipe.fileHandleForReading.readabilityHandler = { handle in collector.append(handle.availableData) }
        do {
            try process.run()
        } catch {
            return (false, error.localizedDescription)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        collector.append(pipe.fileHandleForReading.readDataToEndOfFile())
        let output = collector.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus == 0, output)
    }

    private final class OutputCollector: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    /// Size of a list of folders, or of items themselves for `.items` targets.
    static func size(of target: CleanTarget) -> Int64 {
        if let reported = target.reportedSize { return reported }
        return size(of: target.existingURLs)
    }

    static func clean(_ target: CleanTarget, toTrash: Bool) -> [String] {
        switch target.mode {
        case .contents: target.existingURLs.flatMap { clearContents(of: $0, toTrash: toTrash) }
        case .items: target.existingURLs.compactMap { remove($0, toTrash: toTrash) }
        case .thin: target.existingURLs.compactMap { AppSlimming.thin($0) }
        }
    }

    static func diskSpace() -> (free: Int64, total: Int64) {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return (values?.volumeAvailableCapacityForImportantUsage ?? 0,
                Int64(values?.volumeTotalCapacity ?? 0))
    }
}

/// Walks a folder tree looking for rebuildable project artifacts.
enum ProjectScanner {
    /// folder name -> (marker file in the parent that confirms it, label)
    private static let rules: [String: (markers: [String], kind: String)] = [
        "node_modules": (["package.json"], "node_modules"),
        ".build": (["Package.swift"], "SwiftPM .build"),
        "Pods": (["Podfile"], "CocoaPods"),
        "DerivedData": ([], "DerivedData"),
        "target": (["Cargo.toml", "pom.xml"], "Rust / Maven target"),
        "build": (["build.gradle", "build.gradle.kts", "CMakeLists.txt", "pubspec.yaml"], "Build output"),
        ".gradle": (["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"], "Gradle project cache"),
        ".next": (["package.json"], "Next.js .next"),
        ".nuxt": (["package.json"], "Nuxt .nuxt"),
        ".turbo": (["package.json"], "Turborepo cache"),
        ".parcel-cache": (["package.json"], "Parcel cache"),
        ".dart_tool": (["pubspec.yaml"], "Dart tool"),
        "venv": (["requirements.txt", "pyproject.toml", "setup.py"], "Python venv"),
        ".venv": (["requirements.txt", "pyproject.toml", "setup.py", "uv.lock"], "Python venv"),
        "__pycache__": ([], "Python bytecode"),
        ".pytest_cache": ([], "pytest cache"),
        ".mypy_cache": ([], "mypy cache"),
        ".ruff_cache": ([], "Ruff cache"),
        ".terraform": ([".terraform.lock.hcl", "main.tf", "versions.tf", "providers.tf"], "Terraform providers"),
        ".aws-sam": (["template.yaml", "template.yml", "samconfig.toml"], "AWS SAM build"),
        ".serverless": (["serverless.yml", "serverless.yaml", "serverless.ts"], "Serverless build"),
        ".angular": (["angular.json"], "Angular cache"),
        ".svelte-kit": (["svelte.config.js", "package.json"], "SvelteKit output"),
    ]

    /// The junk label for a folder if it matches a rule (and its project marker exists).
    static func kind(forFolderAt url: URL) -> String? {
        guard let rule = rules[url.lastPathComponent] else { return nil }
        let parent = url.deletingLastPathComponent()
        let confirmed = rule.markers.isEmpty
            || rule.markers.contains { FileManager.default.fileExists(atPath: parent.appendingPathComponent($0).path) }
        return confirmed ? rule.kind : nil
    }

    private static let neverDescend: Set<String> = [".git", ".hg", ".svn", "Library", ".Trash"]

    static func scan(root: URL, progress: @escaping @Sendable (String) -> Void) -> [ProjectJunk] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var found: [ProjectJunk] = []
        var visited = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }

            let name = url.lastPathComponent
            if neverDescend.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            visited += 1
            if visited % 200 == 0 { progress(url.path) }

            guard let kind = kind(forFolderAt: url) else { continue }

            enumerator.skipDescendants()
            found.append(ProjectJunk(url: url, kind: kind, size: FileOps.size(of: url),
                                     modified: values?.contentModificationDate))
        }
        return found.sorted { $0.size > $1.size }
    }
}
