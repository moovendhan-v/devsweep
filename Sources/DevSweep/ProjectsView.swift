import AppKit
import SwiftUI

struct ProjectsView: View {
    @Environment(Store.self) private var store
    @State private var confirming = false
    @State private var mode: Mode = .tree
    @State private var age: Age = .any

    enum Mode: String, CaseIterable { case tree = "Folders", list = "Largest" }

    enum Age: Int, CaseIterable, Identifiable {
        case any = 0, month = 30, quarter = 90, year = 365
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .any: "Any age"
            case .month: "Untouched 30+ days"
            case .quarter: "Untouched 90+ days"
            case .year: "Untouched 1+ year"
            }
        }
    }

    private var visibleJunk: [ProjectJunk] {
        guard age != .any else { return store.projectJunk }
        let cutoff = Date.now.addingTimeInterval(-Double(age.rawValue) * 86_400)
        return store.projectJunk.filter { ($0.modified ?? .distantPast) < cutoff }
    }

    var body: some View {
        Group {
            if let status = store.projectScanStatus {
                scanningView(status)
            } else if store.projectRoot == nil || (store.projectJunk.isEmpty && !hasScanned) {
                startView
            } else {
                content
            }
        }
        .navigationTitle("Project Folders")
        .navigationSubtitle(store.projectRoot?.tildePath ?? "")
        .toolbar {
            ToolbarItemGroup {
                if store.projectRoot != nil && store.projectScanStatus == nil {
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Age", selection: $age) {
                        ForEach(Age.allCases) { Text($0.label).tag($0) }
                    }
                    .help("Only show folders in projects you haven't touched for a while")
                    Button { if let root = store.projectRoot { Task { await store.scanProjects(at: root) } } } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                }
                Button(action: pickFolder) { Label("Choose Folder…", systemImage: "folder.badge.plus") }
                    .disabled(store.projectScanStatus != nil)
            }
        }
    }

    @State private var hasScanned = false

    // MARK: States

    private var startView: some View {
        VStack(spacing: 22) {
            IconBadge(symbol: "folder.badge.gearshape", color: Palette.projects, size: 72)
            VStack(spacing: 6) {
                Text("Find space hiding in your projects").font(.title2.weight(.semibold))
                Text("DevSweep looks for node_modules, .build, Pods, target, build, .next, .venv and more. It only picks folders that sit next to a matching project file, so your own files stay safe.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            }
            HStack(spacing: 12) {
                ForEach(quickFolders, id: \.self) { url in
                    Button { scan(url) } label: {
                        VStack(spacing: 8) {
                            FileIcon(url: url, size: 44)
                            Text(url.lastPathComponent).font(.callout.weight(.medium))
                        }
                        .frame(width: 110, height: 96)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
                Button(action: pickFolder) {
                    VStack(spacing: 8) {
                        Image(systemName: "ellipsis.circle").font(.system(size: 32)).foregroundStyle(.secondary)
                            .frame(height: 44)
                        Text("Other…").font(.callout.weight(.medium))
                    }
                    .frame(width: 110, height: 96)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            if let root = store.projectRoot {
                Button("Rescan \(root.tildePath)") { scan(root) }.buttonStyle(.link)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scanningView(_ status: String) -> some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Scanning \(store.projectRoot?.lastPathComponent ?? "")…").font(.headline)
            Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 520)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        let junk = visibleJunk
        let total = junk.reduce(0) { $0 + $1.size }
        return VStack(spacing: 0) {
            summaryStrip(junk: junk, total: total)
            Divider()
            if junk.isEmpty {
                ContentUnavailableView("Nothing to clean here", systemImage: "checkmark.seal",
                                       description: Text("No rebuildable folders match this filter."))
                    .frame(maxHeight: .infinity)
            } else if mode == .tree {
                List(ProjectNode.tree(root: store.projectRoot!, items: junk), children: \.children) { node in
                    ProjectRow(node: node, total: max(total, 1))
                }
                .listStyle(.inset)
            } else {
                List(junk) { item in
                    ProjectRow(node: ProjectNode(url: item.url, junk: item, children: nil, size: item.size, junkURLs: [item.url]),
                               total: max(junk.first?.size ?? 1, 1), showPath: true)
                }
                .listStyle(.inset)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CleanBar(title: store.selectedJunk.isEmpty ? "Clean" : "Clean \(store.selectedJunkBytes.byteString)", disabled: store.selectedJunk.isEmpty) {
                HStack(spacing: 10) {
                    Text("\(store.selectedJunk.count) selected").foregroundStyle(.secondary)
                    Button("Select All") { store.selectedJunk = Set(junk.map(\.url)) }.buttonStyle(.link)
                    Button("Clear") { store.selectedJunk = [] }.buttonStyle(.link)
                }
            } action: {
                confirming = true
            }
        }
        .confirmationDialog("Remove \(store.selectedJunk.count) folder(s) · \(store.selectedJunkBytes.byteString)?",
                            isPresented: $confirming) {
            Button(store.moveToTrash ? "Move to Trash" : "Delete Permanently", role: .destructive) {
                Task { await store.cleanSelectedJunk() }
            }
        } message: {
            Text("Get them back any time by running npm install, swift build, pod install, cargo build, etc.")
        }
    }

    private func summaryStrip(junk: [ProjectJunk], total: Int64) -> some View {
        let byKind = Dictionary(grouping: junk, by: \.kind)
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.size }, $0.value.count) }
            .sorted { $0.1 > $1.1 }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(total.byteString).font(.title2.weight(.bold)).monospacedDigit()
                    Text("\(junk.count) folders · \(Set(junk.map { $0.url.deletingLastPathComponent() }).count) projects")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.trailing, 8)
                ForEach(byKind, id: \.0) { kind, bytes, count in
                    Button {
                        let urls = junk.filter { $0.kind == kind }.map(\.url)
                        store.selectedJunk.formUnion(urls)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind).font(.caption.weight(.semibold))
                            Text("\(bytes.byteString) · \(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("Select all \(kind) folders")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    // MARK: Helpers

    private var quickFolders: [URL] {
        ["Desktop", "Developer", "Documents", "Projects", "code", "src"]
            .map { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .prefix(4).map { $0 }
    }

    private func scan(_ url: URL) {
        hasScanned = true
        Task { await store.scanProjects(at: url) }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Scan"
        panel.message = "Choose the folder where you keep your code"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        if panel.runModal() == .OK, let url = panel.url { scan(url) }
    }
}

private struct ProjectRow: View {
    @Environment(Store.self) private var store
    let node: ProjectNode
    let total: Int64
    var showPath = false

    var body: some View {
        let chosen = node.junkURLs.filter { store.selectedJunk.contains($0) }.count
        HStack(spacing: 10) {
            Checkbox(value: chosen == 0 ? .off : chosen == node.junkURLs.count ? .on : .mixed) {
                if chosen == node.junkURLs.count {
                    store.selectedJunk.subtract(node.junkURLs)
                } else {
                    store.selectedJunk.formUnion(node.junkURLs)
                }
            }

            if let junk = node.junk {
                IconBadge(symbol: symbol(for: junk.kind), color: Palette.projects, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(showPath ? "\(junk.projectName) › \(node.name)" : node.name).fontWeight(.medium)
                        Tag(text: junk.kind, color: Palette.projects)
                    }
                    if showPath {
                        Text(node.url.tildePath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    } else if let modified = junk.modified {
                        Text("Modified \(modified.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                FileIcon(url: node.url, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name).fontWeight(.medium)
                    Text("\(node.junkURLs.count) cleanable folder\(node.junkURLs.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)
            SizeBar(fraction: Double(node.size) / Double(total), color: Palette.projects).frame(width: 120)
            Text(node.size.byteString).monospacedDigit().frame(width: 76, alignment: .trailing)
                .fontWeight(node.size > 1_000_000_000 ? .semibold : .regular)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Browse in Space Explorer") { store.browse(node.url) }
            Button("Reveal in Finder") { NSWorkspace.shared.reveal([node.url]) }
        }
    }

    private func symbol(for kind: String) -> String {
        switch kind {
        case let k where k.contains("node") || k.contains("Next") || k.contains("Nuxt"): "shippingbox.fill"
        case let k where k.contains("Swift") || k.contains("Cocoa") || k.contains("Derived"): "swift"
        case let k where k.contains("Python"): "chevron.left.forwardslash.chevron.right"
        default: "hammer.fill"
        }
    }
}
