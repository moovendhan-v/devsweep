import AppKit
import SwiftUI

struct ExplorerView: View {
    @Environment(Store.self) private var store
    @State private var confirming = false
    @AppStorage("spaceLensMode") private var mode = "map"

    private var explorer: Explorer { store.explorer }

    var body: some View {
        @Bindable var explorer = store.explorer
        VStack(spacing: 0) {
            PathBar(url: explorer.current) { explorer.open($0) }
            Divider()
            if explorer.unreadable {
                ContentUnavailableView {
                    Label("Can't read this folder", systemImage: "lock")
                } description: {
                    Text("macOS protects this location. Give DevSweep Full Disk Access in System Settings › Privacy & Security to look inside.")
                } actions: {
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                if mode == "map" {
                    TreemapView(explorer: explorer, hint: store.hint(for:)) { url in explorer.open(url) }
                } else {
                    table(selection: $explorer.selection)
                }
            }
        }
        .navigationTitle(explorer.current.path == NSHomeDirectory() ? "Home" : explorer.current.lastPathComponent)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .task { if explorer.items.isEmpty { explorer.reload() } }
        .confirmationDialog("Move \(explorer.selection.count) item(s) to the Trash?", isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) {
                Task { await store.trashFromExplorer(Array(explorer.selection)) }
            }
        } message: {
            Text(explorer.items.filter { explorer.selection.contains($0.url) }.map(\.name).prefix(8).joined(separator: ", ")
                 + "\n\nYou can put them back from the Trash.")
        }
    }

    private func table(selection: Binding<Set<URL>>) -> some View {
        Table(explorer.items, selection: selection) {
            TableColumn("Name") { item in
                HStack(spacing: 8) {
                    FileIcon(url: item.url, size: 22)
                    Text(item.name).lineLimit(1)
                    if let hint = store.hint(for: item.url) {
                        Tag(text: hint, color: .green)
                    }
                    if item.canOpen {
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            TableColumn("Size") { item in
                HStack(spacing: 10) {
                    SizeBar(fraction: Double(item.size ?? 0) / Double(explorer.largest),
                            color: barColor(for: item))
                    Group {
                        if let size = item.size {
                            Text(size.byteString)
                        } else {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .monospacedDigit()
                    .frame(width: 70, alignment: .trailing)
                }
            }
            .width(min: 180, ideal: 240)
            TableColumn("Share") { item in
                let total = max(explorer.total, 1)
                Text(item.size.map { "\(Int((Double($0) / Double(total) * 100).rounded()))%" } ?? "")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .width(50)
            TableColumn("Modified") { item in
                Text(item.modified.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 110)
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            if urls.count == 1, let url = urls.first, explorer.items.first(where: { $0.url == url })?.canOpen == true {
                Button("Open") { explorer.open(url) }
            }
            Button("Reveal in Finder") { NSWorkspace.shared.reveal(Array(urls)) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                explorer.selection = urls
                confirming = true
            }
        } primaryAction: { urls in
            guard urls.count == 1, let url = urls.first else { return }
            if explorer.items.first(where: { $0.url == url })?.canOpen == true {
                explorer.open(url)
            } else {
                NSWorkspace.shared.reveal([url])
            }
        }
        .onKeyPress(.delete) {
            guard !explorer.selection.isEmpty else { return .ignored }
            confirming = true
            return .handled
        }
    }

    private func barColor(for item: FolderItem) -> Color {
        if store.hint(for: item.url) != nil { return .green }
        return item.isDirectory ? .accentColor : .gray
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: explorer.back) { Label("Back", systemImage: "chevron.left") }
                .disabled(!explorer.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
            Button(action: explorer.forward) { Label("Forward", systemImage: "chevron.right") }
                .disabled(!explorer.canGoForward)
                .keyboardShortcut("]", modifiers: .command)
        }
        ToolbarItem {
            Picker("View", selection: $mode) {
                Label("Map", systemImage: "square.grid.3x3.square").tag("map")
                Label("List", systemImage: "list.bullet").tag("list")
            }
            .pickerStyle(.segmented)
            .help("Switch between the bubble map and the list")
        }
        ToolbarItemGroup {
            Button(action: explorer.up) { Label("Enclosing Folder", systemImage: "arrow.up") }
                .disabled(!explorer.canGoUp)
                .keyboardShortcut(.upArrow, modifiers: .command)
            Menu {
                ForEach(places, id: \.0) { name, path in
                    Button(name) { explorer.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) }
                }
                Divider()
                Button("Choose Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.directoryURL = explorer.current
                    if panel.runModal() == .OK, let url = panel.url { explorer.open(url) }
                }
            } label: {
                Label("Go to", systemImage: "location")
            }
            Toggle(isOn: Bindable(explorer).showHidden) {
                Label("Show Hidden Files", systemImage: "eye")
            }
            .help("Show hidden folders like .npm, .gradle and .cache")
            Button(action: explorer.invalidateAndReload) { Label("Refresh", systemImage: "arrow.clockwise") }
        }
    }

    private var places: [(String, String)] {
        [("Home", "~"), ("Desktop", "~/Desktop"), ("Downloads", "~/Downloads"), ("Documents", "~/Documents"),
         ("Library › Caches", "~/Library/Caches"), ("Library › Developer", "~/Library/Developer"),
         ("Library › Application Support", "~/Library/Application Support"), ("Applications", "/Applications")]
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if explorer.isMeasuring {
                ProgressView().controlSize(.small)
                Text("Measuring \(explorer.pending) folder\(explorer.pending == 1 ? "" : "s")…").foregroundStyle(.secondary)
            } else {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text(mode == "map" ? "Click a block to open it. Right-click for more. Green = safe-to-rebuild cache." : "Double-click a folder to open it. Green items are safe-to-rebuild developer folders.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(explorer.items.count) items · \(explorer.total.byteString)").foregroundStyle(.secondary).monospacedDigit()
            Button {
                confirming = true
            } label: {
                Label(explorer.selection.isEmpty ? "Move to Trash" : "Move \(explorer.selectedBytes.byteString) to Trash",
                      systemImage: "trash")
            }
            .disabled(explorer.selection.isEmpty || store.isCleaning)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Clickable breadcrumb trail: Macintosh HD › Users › you › Library …
private struct PathBar: View {
    let url: URL
    let open: (URL) -> Void

    private var crumbs: [URL] {
        var result: [URL] = []
        var current = url.standardizedFileURL
        while current.path != "/" {
            result.insert(current, at: 0)
            current = current.deletingLastPathComponent()
        }
        return [URL(fileURLWithPath: "/")] + result
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(crumbs.enumerated()), id: \.element) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                        }
                        let isLast = index == crumbs.count - 1
                        Button { open(crumb) } label: {
                            HStack(spacing: 5) {
                                FileIcon(url: crumb, size: 16)
                                Text(crumb.path == "/" ? "Macintosh HD" : crumb.lastPathComponent)
                                    .fontWeight(isLast ? .semibold : .regular)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(isLast ? AnyShapeStyle(.quaternary.opacity(0.7)) : AnyShapeStyle(.clear),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(crumb)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            .onChange(of: url) { proxy.scrollTo(crumbs.last, anchor: .trailing) }
        }
    }
}
