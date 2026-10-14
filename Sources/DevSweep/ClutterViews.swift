import AppKit
import SwiftUI

// MARK: - Large & Old Files

struct LargeFilesView: View {
    @Environment(Store.self) private var store
    @State private var kind: LargeFile.Kind = .all
    @State private var minimum: Int64 = 100_000_000
    @State private var age = 0
    @State private var hiddenOnly = false
    @State private var confirming = false
    @State private var sortOrder = [KeyPathComparator(\LargeFile.size, order: .reverse)]

    private var model: LargeFilesModel { store.largeFiles }

    private var visible: [LargeFile] {
        let cutoff = Date.now.addingTimeInterval(-Double(age) * 86_400)
        return model.files
            .filter { $0.size >= minimum }
            .filter { kind == .all || $0.kind == kind }
            .filter { age == 0 || ($0.lastUsed ?? .distantPast) < cutoff }
            .filter { !hiddenOnly || $0.isHidden }
            .sorted(using: sortOrder)
    }

    var body: some View {
        let files = visible
        VStack(spacing: 0) {
            ModuleHeader(item: .largeFiles,
                         subtitle: "Big files in your home folder, including hidden ones such as VM disks and old archives.",
                         value: files.reduce(0) { $0 + $1.size }, loading: model.isScanning)
            filters
            Divider()
            if model.isScanning {
                ScanningPlaceholder(text: "Looking through your files…")
            } else if model.scannedRoot == nil {
                ContentUnavailableView {
                    Label("Find big files you forgot about", systemImage: "doc.badge.ellipsis")
                } actions: {
                    Button("Scan Home Folder") { Task { await model.scan(root: URL(fileURLWithPath: NSHomeDirectory())) } }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxHeight: .infinity)
            } else if files.isEmpty {
                ContentUnavailableView("Nothing matches", systemImage: "checkmark.seal",
                                       description: Text("Try a smaller size or a different type."))
                    .frame(maxHeight: .infinity)
            } else {
                table(files)
            }
        }
        .navigationTitle("Large & Old Files")
        .toolbar {
            Button { Task { await model.scan(root: URL(fileURLWithPath: NSHomeDirectory())) } } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(model.isScanning)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TrashBar(count: model.selection.count,
                     bytes: files.filter { model.selection.contains($0.url) }.reduce(0) { $0 + $1.size },
                     disabled: store.isCleaning) { confirming = true }
        }
        .confirmationDialog("Move \(model.selection.count) file(s) to the Trash?", isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) {
                let urls = model.selection
                Task {
                    await store.trashFiles(Array(urls), label: "Large file")
                    model.remove(urls)
                }
            }
        }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Picker("Type", selection: $kind) {
                    ForEach(LargeFile.Kind.allCases, id: \.self) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                }
                .frame(width: 230)
                Picker("Size", selection: $minimum) {
                    Text("50 MB+").tag(Int64(50_000_000))
                    Text("100 MB+").tag(Int64(100_000_000))
                    Text("500 MB+").tag(Int64(500_000_000))
                    Text("1 GB+").tag(Int64(1_000_000_000))
                    Text("5 GB+").tag(Int64(5_000_000_000))
                }
                .frame(width: 150)
                Picker("Not used for", selection: $age) {
                    Text("Any time").tag(0)
                    Text("1 month").tag(30)
                    Text("6 months").tag(180)
                    Text("1 year").tag(365)
                }
                .frame(width: 190)
                Toggle("Hidden files only", isOn: $hiddenOnly).toggleStyle(.checkbox)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    private func table(_ files: [LargeFile]) -> some View {
        Table(files, selection: Bindable(model).selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.url.lastPathComponent) { file in
                HStack(spacing: 8) {
                    FileIcon(url: file.url, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(file.url.lastPathComponent).lineLimit(1)
                            if file.isHidden { Tag(text: "Hidden", color: .purple) }
                        }
                        Text(file.url.deletingLastPathComponent().tildePath)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            TableColumn("Kind") { file in Label(file.kind.rawValue, systemImage: file.kind.symbol).foregroundStyle(.secondary) }
                .width(150)
            TableColumn("Last Used") { file in
                Text(file.lastUsed.map { $0.formatted(.relative(presentation: .named)) } ?? "—").foregroundStyle(.secondary)
            }
            .width(110)
            TableColumn("Size", value: \.size) { file in
                Text(file.size.byteString).monospacedDigit().fontWeight(file.size > 1_000_000_000 ? .semibold : .regular)
            }
            .width(90)
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            Button("Reveal in Finder") { NSWorkspace.shared.reveal(Array(urls)) }
            Button("Quick Look") { if let url = urls.first { NSWorkspace.shared.open(url) } }
        } primaryAction: { urls in NSWorkspace.shared.reveal(Array(urls)) }
    }
}

// MARK: - Duplicates

struct DuplicatesView: View {
    @Environment(Store.self) private var store
    @State private var confirming = false
    @State private var confirmingConsolidate = false

    private var model: DuplicatesModel { store.duplicates }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(item: .duplicates,
                         subtitle: "Identical files (matched by content, not name) taking up space more than once.",
                         value: model.wasted, loading: model.isScanning)
            Divider()
            if model.isScanning {
                ScanningPlaceholder(text: model.status)
            } else if model.scannedRoot == nil {
                FolderPicker(title: "Find duplicate files",
                             subtitle: "Pick a folder. Files are compared by their contents, so renamed copies are found too.",
                             symbol: "square.on.square", color: SidebarItem.duplicates.tint,
                             folders: ["Downloads", "Documents", "Desktop", "Pictures"]) { url in
                    Task { await model.scan(root: url) }
                }
            } else if model.groups.isEmpty {
                ContentUnavailableView("No duplicates", systemImage: "checkmark.seal.fill",
                                       description: Text("Every file in \(model.scannedRoot?.lastPathComponent ?? "this folder") is unique."))
                    .frame(maxHeight: .infinity)
            } else {
                list
            }
        }
        .navigationTitle("Duplicates")
        .navigationSubtitle(model.scannedRoot?.tildePath ?? "")
        .toolbar {
            if model.scannedRoot != nil {
                Button("Consolidate…") { confirmingConsolidate = true }
                    .help("Keep every path, but store identical files only once using APFS clones")
                    .disabled(model.selection.isEmpty)
                Button("Keep Newest") { model.selectAllButNewest() }
                    .help("Select every copy except the most recently modified one")
                Button("Choose Folder…", systemImage: "folder") { pick() }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TrashBar(count: model.selection.count, bytes: model.selectedBytes, disabled: store.isCleaning) { confirming = true }
        }
        .confirmationDialog("Consolidate \(model.selection.count) duplicate(s)?", isPresented: $confirmingConsolidate) {
            Button("Consolidate") {
                Task {
                    let (bytes, problems) = await model.consolidateSelected()
                    store.log.insert("✓ Consolidated duplicates: reclaimed \(bytes.byteString)" + (problems.isEmpty ? "" : " (\(problems.count) skipped)"), at: 0)
                    store.disk = FileOps.diskSpace()
                }
            }
        } message: {
            Text("Every file stays where it is. Selected copies become APFS clones of the copy you keep, so the data is stored once. Editing one later doesn't change the others.")
        }
        .confirmationDialog("Move \(model.selection.count) duplicate(s) to the Trash?", isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) {
                let urls = model.selection
                Task {
                    await store.trashFiles(Array(urls), label: "Duplicate")
                    model.remove(urls)
                }
            }
        } message: {
            Text("At least one copy of each file is always kept.")
        }
    }

    private var list: some View {
        List {
            ForEach(model.groups) { group in
                SwiftUI.Section {
                    ForEach(group.files) { file in
                        let isOn = model.selection.contains(file.url)
                        let keepsOne = group.files.contains { !model.selection.contains($0.url) && $0.url != file.url }
                        HStack(spacing: 10) {
                            Checkbox(value: isOn ? .on : .off) {
                                if isOn { model.selection.remove(file.url) } else if keepsOne { model.selection.insert(file.url) }
                            }
                            .help(keepsOne || isOn ? "" : "Keep at least one copy")
                            FileIcon(url: file.url, size: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.url.lastPathComponent).lineLimit(1)
                                Text(file.url.deletingLastPathComponent().tildePath)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if !isOn { Tag(text: "Keep", color: .green) }
                            Text(file.modified?.formatted(date: .abbreviated, time: .omitted) ?? "").foregroundStyle(.secondary)
                            Button { NSWorkspace.shared.reveal([file.url]) } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    HStack {
                        FileIcon(url: group.files[0].url, size: 18)
                        Text(group.files[0].url.lastPathComponent).font(.headline).lineLimit(1)
                        Text("\(group.files.count) copies · \(group.size.byteString) each").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(group.wasted.byteString) wasted").font(.headline).foregroundStyle(.teal)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url { Task { await model.scan(root: url) } }
    }
}

// MARK: - Shared pieces

struct ScanningPlaceholder: View {
    let text: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(text).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "Pick a folder" start screen with quick shortcuts to common folders.
struct FolderPicker: View {
    let title: String
    let subtitle: String
    let symbol: String
    let color: Color
    let folders: [String]
    let choose: (URL) -> Void

    private var quick: [URL] {
        folders.map { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var body: some View {
        VStack(spacing: 22) {
            IconBadge(symbol: symbol, color: color, size: 72)
            VStack(spacing: 6) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            }
            HStack(spacing: 12) {
                ForEach(quick, id: \.self) { url in
                    Button { choose(url) } label: { tile(FileIcon(url: url, size: 44), url.lastPathComponent) }
                        .buttonStyle(.plain)
                }
                Button(action: pickOther) {
                    tile(Image(systemName: "ellipsis.circle").font(.system(size: 32)).foregroundStyle(.secondary).frame(height: 44), "Other…")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tile(_ icon: some View, _ label: String) -> some View {
        VStack(spacing: 8) {
            icon
            Text(label).font(.callout.weight(.medium))
        }
        .frame(width: 110, height: 96)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func pickOther() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Scan"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        if panel.runModal() == .OK, let url = panel.url { choose(url) }
    }
}

/// Bottom bar for screens that always move to the Trash.
struct TrashBar: View {
    let count: Int
    let bytes: Int64
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Text(count == 0 ? "Select files to remove" : "\(count) selected · \(bytes.byteString)")
                .foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Button(action: action) {
                Label("Move to Trash", systemImage: "trash").padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(count == 0 || disabled)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Clean history

struct HistoryView: View {
    @Environment(Store.self) private var store
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(item: .history, subtitle: "Everything DevSweep moved to the Trash in the last 30 days. Put any clean back with one click.",
                         value: store.history.reduce(0) { $0 + $1.bytes })
            if let message { Text(message).font(.callout).padding(8).frame(maxWidth: .infinity).background(.quaternary.opacity(0.4)) }
            if store.history.isEmpty {
                ContentUnavailableView("Nothing to restore", systemImage: "arrow.uturn.backward.circle",
                                       description: Text("Cleans that go to the Trash show up here."))
            } else {
                List(store.history) { session in
                    DisclosureGroup {
                        ForEach(session.items.prefix(50), id: \.self) { item in
                            HStack {
                                FileIcon(url: URL(fileURLWithPath: FileManager.default.fileExists(atPath: item.trashed) ? item.trashed : "/"), size: 16)
                                Text((item.original as NSString).abbreviatingWithTildeInPath).font(.caption).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if !FileManager.default.fileExists(atPath: item.trashed) { Tag(text: "Trash emptied", color: .secondary) }
                                Text(item.bytes.byteString).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        if session.items.count > 50 { Text("+ \(session.items.count - 50) more").font(.caption).foregroundStyle(.secondary) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.label).fontWeight(.medium).lineLimit(1)
                                Text("\(session.date.formatted(date: .abbreviated, time: .shortened)) · \(session.items.count) items · \(session.restorable.count) still in Trash")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(session.bytes.byteString).monospacedDigit()
                            Button("Restore") {
                                let result = CleanHistory.restore(session)
                                message = "Restored \(result.restored) item(s)" + (result.skipped > 0 ? ", skipped \(result.skipped) (already back or emptied)" : "")
                                store.history = CleanHistory.load()
                            }
                            .disabled(session.restorable.isEmpty)
                        }
                    }
                }
            }
        }
        .navigationTitle("Clean History")
        .onAppear { store.history = CleanHistory.load() }
    }
}

// MARK: - Shredder

struct ShredderView: View {
    @Environment(Store.self) private var store
    @State private var confirming = false
    @State private var targeted = false
    private var model: ShredderModel { store.shredder }

    var body: some View {
        @Bindable var model = store.shredder
        VStack(spacing: 0) {
            ModuleHeader(item: .shredder, subtitle: "Erase files so they don't go to the Trash. Drop files or folders below.", value: model.files.isEmpty ? nil : model.total)
            Picker("Mode", selection: $model.mode) {
                ForEach(ShredderModel.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).padding(.horizontal, 16).padding(.top, 10)
            Text(model.mode.detail).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            Group {
                if model.files.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "scissors").font(.system(size: 48)).foregroundStyle(.secondary)
                        Text("Drop files here").font(.title3.weight(.semibold))
                        Button("Choose Files…", action: pick)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(targeted ? Color.accentColor.opacity(0.08) : .clear)
                } else {
                    List {
                        ForEach(model.files, id: \.self) { url in
                            HStack {
                                FileIcon(url: url, size: 22)
                                Text(url.lastPathComponent)
                                Text(url.deletingLastPathComponent().tildePath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                Text(FileOps.size(of: url).byteString).foregroundStyle(.secondary).monospacedDigit()
                                Button { model.files.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in store.shredder.add([url]) } }
                    }
                }
                return true
            }
        }
        .navigationTitle("Shredder")
        .toolbar { Button("Add Files…", systemImage: "plus", action: pick) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Text("\(model.files.count) item(s) · \(model.total.byteString)").foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) { confirming = true } label: { Label("Shred", systemImage: "scissors").padding(.horizontal, 6) }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                    .disabled(model.files.isEmpty || model.isRunning)
            }
            .padding(14).background(.bar)
        }
        .confirmationDialog("Shred \(model.files.count) item(s)?", isPresented: $confirming) {
            Button(model.mode.rawValue, role: .destructive) {
                Task { store.log.insert(contentsOf: await model.shred(), at: 0) }
            }
        } message: {
            Text(model.mode == .trash ? "They go to the Trash." : "This can't be undone.")
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { model.add(panel.urls) }
    }
}
