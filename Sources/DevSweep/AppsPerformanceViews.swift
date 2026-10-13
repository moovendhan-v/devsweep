import AppKit
import SwiftUI

// MARK: - Uninstaller

struct AppsView: View {
    @Environment(Store.self) private var store
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var focused: InstalledApp?
    @State private var leftovers: [Leftover] = []
    @State private var leftoverSelection: Set<URL> = []
    @State private var confirming = false
    @State private var confirmingOrphans = false

    enum Filter: String, CaseIterable { case all = "All Apps", unused = "Unused 90+ days", leftovers = "Leftovers" }

    private var model: AppsModel { store.apps }

    private var apps: [InstalledApp] {
        let base = filter == .unused ? model.unused : model.apps
        return search.isEmpty ? base : base.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(item: .apps,
                         subtitle: "Remove apps completely, including the settings and support files they leave in your Library.",
                         value: model.apps.reduce(0) { $0 + $1.size }, loading: model.isScanning)
            Picker("", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text(label(for: $0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if model.isScanning && model.apps.isEmpty {
                ScanningPlaceholder(text: "Reading your Applications folder…")
            } else if filter == .leftovers {
                orphanList
            } else {
                HStack(spacing: 0) {
                    appList.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    detail.frame(width: 360).frame(maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .navigationTitle("Uninstaller")
        .searchable(text: $search, placement: .toolbar, prompt: "Search apps")
        .toolbar {
            Button { Task { await model.scan() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .disabled(model.isScanning)
        }
        .task { if model.apps.isEmpty { await model.scan() } }
        .confirmationDialog("Uninstall \(focused?.name ?? "app")?", isPresented: $confirming) {
            Button("Move App & \(leftoverSelection.count) Leftovers to Trash", role: .destructive) { uninstall() }
        } message: {
            Text("The app and its selected support files go to the Trash. If it's running, DevSweep quits it first.")
        }
        .confirmationDialog("Remove \(model.selection.count) leftover item(s)?", isPresented: $confirmingOrphans) {
            Button("Move to Trash", role: .destructive) {
                let urls = model.selection
                Task {
                    await store.trashFiles(Array(urls), label: "Leftover")
                    model.forget(urls)
                }
            }
        }
    }

    private func label(for filter: Filter) -> String {
        switch filter {
        case .all: "All Apps (\(model.apps.count))"
        case .unused: "Unused 90+ days (\(model.unused.count))"
        case .leftovers: "Leftovers (\(model.orphanBytes.byteString))"
        }
    }

    private var appList: some View {
        let maxSize = Double(max(model.apps.first?.size ?? 1, 1))
        return List(apps, selection: Binding(get: { focused?.url }, set: { url in select(apps.first { $0.url == url }) })) { app in
            HStack(spacing: 10) {
                FileIcon(url: app.url, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(app.name).fontWeight(.medium).lineLimit(1)
                        if app.isUnused { Tag(text: "Unused", color: .orange) }
                    }
                    Text(app.lastUsed.map { "Opened \($0.formatted(.relative(presentation: .named)))" } ?? "Last use unknown")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                SizeBar(fraction: Double(app.size) / maxSize, color: SidebarItem.apps.tint).frame(width: 70)
                Text(app.size.byteString).monospacedDigit().frame(width: 74, alignment: .trailing)
            }
            .padding(.vertical, 3)
            .tag(app.url)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let app = focused {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    FileIcon(url: app.url, size: 72)
                    Text(app.name).font(.title2.weight(.semibold))
                    Text([app.version.map { "Version \($0)" }, app.bundleID].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .padding(20)
                Divider()
                List {
                    SwiftUI.Section("Application") {
                        HStack {
                            FileIcon(url: app.url, size: 18)
                            Text(app.url.tildePath).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(app.size.byteString).monospacedDigit()
                        }
                    }
                    SwiftUI.Section("Leftovers in your Library (\(leftovers.reduce(0) { $0 + $1.size }.byteString))") {
                        if leftovers.isEmpty {
                            Text("None found").foregroundStyle(.secondary)
                        }
                        ForEach(leftovers) { item in
                            HStack(spacing: 8) {
                                Checkbox(value: leftoverSelection.contains(item.url) ? .on : .off) {
                                    if leftoverSelection.contains(item.url) { leftoverSelection.remove(item.url) }
                                    else { leftoverSelection.insert(item.url) }
                                }
                                FileIcon(url: item.url, size: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.url.lastPathComponent).lineLimit(1)
                                    Text(item.url.deletingLastPathComponent().tildePath).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(item.size.byteString).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Divider()
                HStack {
                    Button("Reveal") { NSWorkspace.shared.reveal([app.url]) }
                    Spacer()
                    Button(role: .destructive) { confirming = true } label: {
                        Label("Uninstall \(totalForFocused.byteString)", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(store.isCleaning)
                }
                .padding(14)
            }
        } else {
            ContentUnavailableView("Select an app", systemImage: "app.dashed",
                                   description: Text("See its size and the files it leaves behind."))
        }
    }

    private var totalForFocused: Int64 {
        (focused?.size ?? 0) + leftovers.filter { leftoverSelection.contains($0.url) }.reduce(0) { $0 + $1.size }
    }

    private var orphanList: some View {
        VStack(spacing: 0) {
            if model.orphans.isEmpty {
                ContentUnavailableView("No leftovers", systemImage: "checkmark.seal.fill",
                                       description: Text("No support files from deleted apps were found."))
                    .frame(maxHeight: .infinity)
            } else {
                List(model.orphans, selection: Bindable(model).selection) { item in
                    HStack(spacing: 10) {
                        FileIcon(url: item.url, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.url.lastPathComponent).lineLimit(1)
                            Text("From an app that's no longer installed · \(item.url.deletingLastPathComponent().tildePath)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(item.size.byteString).monospacedDigit()
                    }
                    .tag(item.url)
                }
                TrashBar(count: model.selection.count,
                         bytes: model.orphans.filter { model.selection.contains($0.url) }.reduce(0) { $0 + $1.size },
                         disabled: store.isCleaning) { confirmingOrphans = true }
            }
        }
    }

    private func select(_ app: InstalledApp?) {
        focused = app
        leftovers = []
        leftoverSelection = []
        guard let app else { return }
        Task {
            let found = await model.leftovers(for: app)
            guard focused?.url == app.url else { return }
            leftovers = found
            leftoverSelection = Set(found.map(\.url))
        }
    }

    private func uninstall() {
        guard let app = focused else { return }
        let urls = [app.url] + Array(leftoverSelection)
        Task {
            if let bundleID = app.bundleID {
                for running in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) { running.terminate() }
                try? await Task.sleep(for: .seconds(1))
            }
            await store.trashFiles(urls, label: "Uninstalled \(app.name)")
            if FileManager.default.fileExists(atPath: app.url.path) {
                store.log.insert("⚠︎ \(app.name) needs admin rights: drag it to the Trash in Finder.", at: 0)
            }
            model.forget(Set(urls))
            focused = nil
        }
    }
}

// MARK: - Performance

struct PerformanceView: View {
    @Environment(Store.self) private var store
    @State private var taskResult: String?
    @State private var confirmRemove: LaunchItem?

    private var model: PerformanceModel { store.performance }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ModuleHeader(item: .performance, subtitle: "Memory, heavy apps, background items and maintenance tasks.")
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                HStack(alignment: .top, spacing: 18) {
                    memoryCard
                    tasksCard
                }
                .fixedSize(horizontal: false, vertical: true)
                heavyApps
                launchItems
            }
            .padding(24)
        }
        .navigationTitle("Performance")
        .toolbar {
            Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .onAppear { model.refresh() }
        .confirmationDialog("Remove “\(confirmRemove?.label ?? "")”?", isPresented: Binding(
            get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let item = confirmRemove {
                    Task {
                        await store.trashFiles([item.url], label: "Launch agent")
                        model.refresh()
                    }
                }
            }
        } message: {
            Text("The item stops launching at your next login. Its app may re-create it when you open it.")
        }
    }

    private var memoryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("Memory").font(.headline)
                HStack(spacing: 22) {
                    Gauge(value: model.memoryPressure) {
                        EmptyView()
                    } currentValueLabel: {
                        Text("\(Int(model.memoryPressure * 100))%").font(.title2.weight(.bold)).monospacedDigit()
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(model.memoryPressure > 0.85 ? .red : model.memoryPressure > 0.7 ? .orange : .green)
                    .scaleEffect(1.6)
                    .frame(width: 90, height: 90)
                    VStack(alignment: .leading, spacing: 6) {
                        row("Used", model.memoryUsed)
                        row("Compressed", model.memoryCompressed)
                        row("Swap", model.swapUsed)
                        row("Installed", model.memoryTotal)
                    }
                }
            }
        }
    }

    private func row(_ title: String, _ bytes: Int64) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(bytes.byteString).monospacedDigit()
        }
        .font(.callout)
        .frame(width: 200)
    }

    private var tasksCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Maintenance").font(.headline)
                ForEach(model.tasks) { task in
                    HStack(spacing: 10) {
                        IconBadge(symbol: task.symbol, color: .yellow, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(task.name).fontWeight(.medium)
                            Text(task.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Button(model.runningTask == task.id ? "Running…" : "Run") {
                            Task {
                                let ok = await model.run(task)
                                taskResult = ok ? "✓ \(task.name) finished" : "\(task.name) was cancelled"
                            }
                        }
                        .disabled(model.runningTask != nil)
                    }
                }
                Text(taskResult ?? "macOS asks for your admin password before running these.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var heavyApps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Heavy apps").font(.title3.weight(.semibold))
            Card {
                VStack(spacing: 0) {
                    let maxMemory = Double(max(model.topApps.first?.memory ?? 1, 1))
                    ForEach(Array(model.topApps.prefix(10).enumerated()), id: \.element.id) { index, app in
                        if index > 0 { Divider().padding(.leading, 40) }
                        HStack(spacing: 10) {
                            if let url = app.bundleURL { FileIcon(url: url, size: 26) }
                            Text(app.name).fontWeight(.medium)
                            Spacer()
                            SizeBar(fraction: Double(app.memory) / maxMemory, color: .yellow).frame(width: 120)
                            Text(app.memory.byteString).monospacedDigit().frame(width: 80, alignment: .trailing)
                            Button("Quit") { model.quit(app) }.controlSize(.small)
                        }
                        .padding(.vertical, 7)
                    }
                }
            }
        }
    }

    private var launchItems: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Background items (\(model.launchItems.count))").font(.title3.weight(.semibold))
                Spacer()
                Button("Open Login Items Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                }
            }
            Card {
                VStack(spacing: 0) {
                    if model.launchItems.isEmpty {
                        Text("No launch agents found.").foregroundStyle(.secondary).padding()
                    }
                    ForEach(Array(model.launchItems.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        HStack(spacing: 10) {
                            Image(systemName: item.isUser ? "person.crop.circle" : "gearshape.2")
                                .foregroundStyle(.secondary).frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.label).fontWeight(.medium).lineLimit(1)
                                Text(item.program.isEmpty ? item.url.tildePath : item.program)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Tag(text: item.scope, color: item.isUser ? .blue : .secondary)
                            Button { NSWorkspace.shared.reveal([item.url]) } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.borderless)
                            if item.isUser {
                                Button { confirmRemove = item } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                                    .help("Stop this from launching")
                            }
                        }
                        .padding(.vertical, 7)
                    }
                }
            }
        }
    }
}
