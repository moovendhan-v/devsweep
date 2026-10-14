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

    enum Filter: String, CaseIterable { case all = "All Apps", unused = "Unused", leftovers = "Leftovers" }
    @AppStorage("unusedMonths") private var unusedMonths = 3
    @State private var confirmingReset = false

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
            HStack {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text(label(for: $0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if filter == .unused {
                    Picker("Not opened for", selection: $unusedMonths) {
                        Text("3 months").tag(3); Text("6 months").tag(6); Text("12 months").tag(12)
                    }
                    .frame(width: 220)
                }
            }
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
        .confirmationDialog("Reset \(focused?.name ?? "app") to defaults?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { resetFocused() }
        } message: {
            Text("Its caches, preferences, saved state, cookies and logs go to the Trash. The app and your documents stay. Quit it first.")
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
        case .unused: "Unused \(unusedMonths)+ months (\(model.unused.count))"
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
                    Button("Reset to Defaults") { confirmingReset = true }
                        .help("Delete this app's caches and settings but keep the app")
                        .disabled(leftovers.allSatisfy { !AppReset.isResettable($0.url) })
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

    private func resetFocused() {
        guard let app = focused else { return }
        let urls = leftovers.map(\.url).filter(AppReset.isResettable)
        Task {
            if let bundleID = app.bundleID {
                for running in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) { running.terminate() }
                try? await Task.sleep(for: .seconds(1))
            }
            await store.trashFiles(urls, label: "Reset \(app.name)")
            select(app)
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

// MARK: - Maintenance

struct PerformanceView: View {
    @Environment(Store.self) private var store
    @State private var confirmTask: Maintenance?
    private var model: PerformanceModel { store.performance }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ModuleHeader(item: .performance, subtitle: "macOS housekeeping scripts. Safe tasks can run together with a single admin password.")
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                HStack {
                    Text("Safe tasks").font(.title3.weight(.semibold))
                    Spacer()
                    Button {
                        Task { _ = await model.runSafeTasks() }
                    } label: {
                        Label(model.runningTask == "safe" ? "Running…" : "Run All Safe Tasks", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.runningTask != nil)
                }
                taskList(model.tasks.filter { $0.severity == .safe })
                Text("Advanced").font(.title3.weight(.semibold)).padding(.top, 6)
                taskList(model.tasks.filter { $0.severity == .advanced })
                memoryLink
            }
            .padding(24)
        }
        .navigationTitle("Maintenance")
        .confirmationDialog("Run “\(confirmTask?.name ?? "")”?", isPresented: Binding(get: { confirmTask != nil }, set: { if !$0 { confirmTask = nil } })) {
            Button("Run", role: .destructive) { if let task = confirmTask { Task { _ = await model.run(task) } } }
        } message: {
            Text(confirmTask?.sideEffect ?? "")
        }
    }

    private func taskList(_ tasks: [Maintenance]) -> some View {
        Card {
            VStack(spacing: 0) {
                ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                    if index > 0 { Divider() }
                    HStack(spacing: 12) {
                        IconBadge(symbol: task.symbol, color: task.severity == .safe ? .green : .orange, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(task.name).fontWeight(.medium)
                                if task.admin { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary).help("Asks for your admin password") }
                            }
                            Text(task.detail).font(.caption).foregroundStyle(.secondary)
                            if let result = model.results[task.id] { Text(result).font(.caption2).foregroundStyle(result.hasPrefix("✓") ? .green : .orange) }
                        }
                        Spacer()
                        if model.runningTask == task.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Run") {
                                if task.severity == .advanced { confirmTask = task } else { Task { _ = await model.run(task) } }
                            }
                            .disabled(model.runningTask != nil)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private var memoryLink: some View {
        let snap = store.memory.current
        return Card {
            HStack(spacing: 14) {
                IconBadge(symbol: "memorychip", color: .blue, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Free Up RAM lives in Memory & Swap").fontWeight(.medium)
                    Text("\(Int(snap.usedFraction * 100))% used · \(snap.swapUsed.byteString) swap · pressure \(snap.pressure.label.lowercased())")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open") { store.section = .memory }
            }
        }
    }
}

// MARK: - Optimization

struct OptimizationView: View {
    @Environment(Store.self) private var store
    @State private var tab = 0
    @State private var message: String?
    @State private var search = ""
    private var model: PerformanceModel { store.performance }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(item: .optimization, subtitle: "Control what starts with your Mac and find processes burning CPU.")
            Picker("", selection: $tab) {
                Text("Startup Items (\(model.startupItems.count))").tag(0)
                Text("CPU Hogs").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 16).padding(.vertical, 10)
            if let message { Text(message).font(.callout).padding(6).frame(maxWidth: .infinity).background(.quaternary.opacity(0.4)) }
            Divider()
            if tab == 0 { startup } else { cpu }
        }
        .navigationTitle("Optimization")
        .searchable(text: $search, placement: .toolbar, prompt: "Filter")
        .toolbar {
            Button("Login Items Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!) }
            Button { model.refresh(); Task { await model.refreshCPU() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .onAppear { model.refresh() }
        .task(id: tab) {
            guard tab == 1 else { return }
            while !Task.isCancelled {
                await model.refreshCPU()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var startup: some View {
        List {
            ForEach([StartupItem.Kind.loginItem, .agent, .daemon], id: \.self) { kind in
                let items = model.startupItems.filter { $0.kind == kind && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.label.localizedCaseInsensitiveContains(search)) }
                if !items.isEmpty {
                    SwiftUI.Section("\(kind.rawValue)s · \(items.count)") {
                        ForEach(items) { item in
                            HStack(spacing: 10) {
                                if let app = item.appURL { FileIcon(url: app, size: 26) } else { Image(systemName: "gearshape.2").frame(width: 26).foregroundStyle(.secondary) }
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack {
                                        Text(item.name).fontWeight(.medium).lineLimit(1)
                                        if !item.isUser { Tag(text: "All users", color: .secondary) }
                                    }
                                    Text(item.program.isEmpty ? item.label : item.program).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                if let plist = item.plist {
                                    Button { NSWorkspace.shared.reveal([plist]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                                }
                                Toggle("", isOn: Binding(get: { item.enabled }, set: { on in Task { message = await model.setEnabled(item, on) } }))
                                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                                    .disabled(!item.isUser)
                                    .help(item.isUser ? "" : "System-wide items are managed in System Settings")
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var cpu: some View {
        let procs = model.cpuProcesses.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }.prefix(40)
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        return List {
            SwiftUI.Section("CPU now: \(Int(store.system.cpu * 100))% across \(Int(cores)) cores") {
                ForEach(Array(procs)) { proc in
                    HStack(spacing: 10) {
                        if let app = proc.appURL { FileIcon(url: app, size: 22) } else { Image(systemName: "gearshape").frame(width: 22).foregroundStyle(.secondary) }
                        Text(proc.name).lineLimit(1)
                        Text("pid \(proc.pid) · \(proc.threads) threads").font(.caption).foregroundStyle(.tertiary)
                        Spacer()
                        SizeBar(fraction: proc.cpu / cores, color: proc.cpu > 0.8 ? .red : .orange).frame(width: 120)
                        Text("\(Int(proc.cpu * 100))%").monospacedDigit().frame(width: 50, alignment: .trailing)
                        if getuid() == uidOf(proc.pid) {
                            Menu("Quit") {
                                Button("Quit") { kill(proc.pid, SIGTERM) }
                                Button("Force Quit", role: .destructive) { kill(proc.pid, SIGKILL) }
                            }
                            .menuStyle(.borderedButton).fixedSize().controlSize(.small)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay { if model.cpuProcesses.isEmpty { ProgressView("Sampling CPU…") } }
    }

    private func uidOf(_ pid: pid_t) -> uid_t {
        var info = proc_bsdinfo()
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 ? info.pbi_uid : 0
    }
}
