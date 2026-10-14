import AppKit
import SwiftUI

/// Big "start" panel shown before a module's first scan.
struct StartPanel: View {
    let item: SidebarItem
    let title: String
    let detail: String
    let button: String
    var extra: AnyView? = nil
    let action: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            IconBadge(symbol: item.symbol, color: item.tint, size: 76)
            VStack(spacing: 6) {
                Text(title).font(.title2.weight(.semibold))
                Text(detail).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 480)
            }
            if let extra { extra }
            Button(action: action) { Text(button).padding(.horizontal, 18).padding(.vertical, 4) }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Malware

struct MalwareView: View {
    @Environment(Store.self) private var store
    @State private var confirming = false
    private var model: MalwareModel { store.malware }

    var body: some View {
        @Bindable var model = store.malware
        VStack(spacing: 0) {
            ModuleHeader(item: .malware, subtitle: "Looks for known adware families and launch items that run suspicious commands or unsigned programs.",
                         value: nil, loading: model.isScanning)
            HStack(spacing: 14) {
                Picker("Depth", selection: $model.depth) {
                    ForEach(MalwareModel.Depth.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 260)
                Toggle("Real-time protection", isOn: Binding(get: { model.isMonitoring }, set: { model.setMonitoring($0) }))
                    .toggleStyle(.switch).controlSize(.small)
                    .help("Watches launch agents, Downloads and Applications while DevSweep runs, and notifies you about suspicious new items.")
                Spacer()
                if let last = model.lastScan {
                    Text("Last scan \(last.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                }
                Button(model.isScanning ? "Scanning…" : "Scan Now") { Task { await model.scan() } }
                    .buttonStyle(.borderedProminent).disabled(model.isScanning)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            content
        }
        .navigationTitle("Malware Removal")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !model.threats.isEmpty {
                TrashBar(count: model.selection.count, bytes: model.threats.filter { model.selection.contains($0.url) }.reduce(0) { $0 + $1.size },
                         disabled: store.isCleaning) { confirming = true }
            }
        }
        .confirmationDialog("Move \(model.selection.count) item(s) to the Trash?", isPresented: $confirming) {
            Button("Remove", role: .destructive) {
                let urls = model.selection
                Task {
                    for url in urls where url.path.contains("/LaunchAgents/") {
                        _ = FileOps.run("/bin/launchctl bootout gui/\(getuid()) '\(url.path)' 2>/dev/null; true", timeout: 10)
                    }
                    await store.trashFiles(Array(urls), label: "Malware removal")
                    model.forget(urls)
                }
            }
        } message: {
            Text("Launch items are stopped first. Items in /Library need admin rights; reveal them in Finder to delete manually.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isScanning {
            ScanningPlaceholder(text: "Checking launch agents, extensions and support folders…")
        } else if model.lastScan == nil {
            StartPanel(item: .malware, title: "Check your Mac for adware",
                       detail: "A signature-based check, not a full antivirus: it flags known adware families and launch items that behave like them.",
                       button: "Scan for Malware") { Task { await model.scan() } }
        } else if model.threats.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "checkmark.shield.fill").font(.system(size: 64)).foregroundStyle(.green)
                Text("No threats found").font(.title2.weight(.semibold))
                Text("Checked \(model.scannedCount) items.").foregroundStyle(.secondary)
                if !model.liveAlerts.isEmpty { liveAlerts }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(model.threats) { threat in
                    HStack(spacing: 10) {
                        Checkbox(value: model.selection.contains(threat.url) ? .on : .off) {
                            if model.selection.contains(threat.url) { model.selection.remove(threat.url) } else { model.selection.insert(threat.url) }
                        }
                        Image(systemName: threat.level == .known ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(threat.level == .known ? .red : .orange).font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(threat.url.lastPathComponent).fontWeight(.medium)
                                Tag(text: threat.level.rawValue, color: threat.level == .known ? .red : .orange)
                            }
                            Text(threat.reason).font(.caption).foregroundStyle(.secondary)
                            Text(threat.url.deletingLastPathComponent().tildePath).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(threat.size.byteString).foregroundStyle(.secondary).monospacedDigit()
                        Button { NSWorkspace.shared.reveal([threat.url]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                    }
                    .padding(.vertical, 3)
                }
                if !model.liveAlerts.isEmpty { SwiftUI.Section("Real-time alerts") { liveAlerts } }
            }
            .listStyle(.inset)
        }
    }

    private var liveAlerts: some View {
        ForEach(model.liveAlerts) { alert in
            Label("\(alert.url.lastPathComponent): \(alert.reason)", systemImage: "bell.badge").font(.callout)
        }
    }
}

// MARK: - Privacy

struct PrivacyView: View {
    @Environment(Store.self) private var store
    @State private var confirming = false
    @State private var scanned = false
    private var model: PrivacyModel { store.privacy }

    var body: some View {
        @Bindable var model = store.privacy
        VStack(spacing: 0) {
            ModuleHeader(item: .privacy, subtitle: "Browsing history, caches, cookies and recent-items traces. Bookmarks and passwords are never touched.",
                         value: scanned ? model.items.reduce(0) { $0 + $1.size } : nil, loading: model.isScanning)
            HStack {
                Picker("Clean", selection: $model.age) {
                    ForEach(PrivacyModel.Age.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 260)
                .onChange(of: model.age) { Task { await model.scan() } }
                Spacer()
                if !store.hasFullDiskAccess {
                    Label("Safari needs Full Disk Access", systemImage: "lock").font(.caption).foregroundStyle(.orange)
                    Button("Grant") { Store.openFullDiskAccessSettings() }.controlSize(.small)
                }
                Button("Rescan") { Task { await model.scan(); scanned = true } }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if model.isScanning {
                ScanningPlaceholder(text: "Looking at your browsers…")
            } else if !scanned {
                StartPanel(item: .privacy, title: "Clear your browsing traces",
                           detail: "Safari, Chrome, Brave, Edge, Arc, Vivaldi and Firefox, plus macOS recent-items lists.",
                           button: "Scan") { Task { await model.scan(); scanned = true } }
            } else {
                list
            }
        }
        .navigationTitle("Privacy")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if scanned { TrashBar(count: model.selection.count, bytes: model.selectedBytes, disabled: store.isCleaning) { confirming = true } }
        }
        .confirmationDialog("Clean \(model.selection.count) item(s)?", isPresented: $confirming) {
            Button("Clean", role: .destructive) { clean() }
        } message: {
            let running = model.runningApps(for: model.selection)
            Text(running.isEmpty ? "Items go to the Trash." : "Quit \(running.joined(separator: ", ")) first, or its data will be recreated right away.")
        }
    }

    private var list: some View {
        let apps = Dictionary(grouping: store.privacy.items, by: \.app).sorted { $0.key < $1.key }
        return List {
            ForEach(apps, id: \.key) { app, items in
                SwiftUI.Section {
                    ForEach(items) { item in
                        HStack(spacing: 10) {
                            Checkbox(value: model.selection.contains(item.id) ? .on : .off) {
                                if model.selection.contains(item.id) { model.selection.remove(item.id) } else { model.selection.insert(item.id) }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(item.kind).fontWeight(.medium)
                                    if item.risky { Tag(text: "Signs you out", color: .orange) }
                                }
                                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.size.byteString).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        if let id = items.first?.appBundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                            FileIcon(url: url, size: 20)
                        } else {
                            Image(systemName: "applelogo")
                        }
                        Text(app).font(.headline)
                        if let id = items.first?.appBundleID, store.browserExtensions.isRunning(id) { Tag(text: "Running", color: .orange) }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func clean() {
        let urls = model.urls(for: model.selection)
        Task {
            await store.trashFiles(urls, label: "Privacy")
            await model.scan()
        }
    }
}

// MARK: - Browser extensions

struct BrowserExtensionsView: View {
    @Environment(Store.self) private var store
    @State private var message: String?
    private var model: BrowserExtensionsModel { store.browserExtensions }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(item: .browserExtensions, subtitle: "Every extension in Chrome, Brave, Edge, Arc, Vivaldi, Firefox and Safari, with suspicious ones on top.",
                         value: nil, loading: model.isLoading)
            if let message { Text(message).font(.callout).padding(8).frame(maxWidth: .infinity).background(.quaternary.opacity(0.4)) }
            List {
                ForEach(Dictionary(grouping: model.extensions, by: \.browser).sorted { $0.key < $1.key }, id: \.key) { browser, items in
                    SwiftUI.Section("\(browser) · \(items.count)") {
                        ForEach(items) { ext in
                            HStack(spacing: 10) {
                                Image(systemName: ext.suspicious ? "exclamationmark.triangle.fill" : "puzzlepiece.fill")
                                    .foregroundStyle(ext.suspicious ? .red : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack {
                                        Text(ext.name).fontWeight(.medium)
                                        if ext.suspicious { Tag(text: "Suspicious", color: .red) }
                                    }
                                    Text([ext.profile, ext.version.isEmpty ? nil : "v\(ext.version)", ext.identifier].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if ext.removable {
                                    Button("Remove") { remove(ext) }.controlSize(.small)
                                } else {
                                    Button("Safari Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Safari-Settings")!) }.controlSize(.small)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .overlay { if model.extensions.isEmpty && !model.isLoading { ContentUnavailableView("No extensions found", systemImage: "puzzlepiece") } }
        }
        .navigationTitle("Browser Extensions")
        .toolbar { Button { Task { await model.load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") } }
        .task { if model.extensions.isEmpty { await model.load() } }
    }

    private func remove(_ ext: BrowserExtension) {
        if model.isRunning(ext.bundleID) {
            message = "Quit \(ext.browser) first, or remove “\(ext.name)” from its Extensions page."
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ext.bundleID) { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
            return
        }
        Task {
            await store.trashFiles([ext.url], label: "Removed extension \(ext.name)")
            message = "Moved “\(ext.name)” to the Trash."
            await model.load()
        }
    }
}

// MARK: - Saved Wi-Fi

struct WiFiView: View {
    @Environment(Store.self) private var store
    @State private var confirming = false
    private var model: WiFiModel { store.wifi }

    var body: some View {
        @Bindable var model = store.wifi
        VStack(spacing: 0) {
            ModuleHeader(item: .wifi, subtitle: "Networks your Mac joins automatically. Forget the ones you don't use (one admin prompt).",
                         value: nil, loading: model.isLoading)
            if let message = model.message {
                ContentUnavailableView(message, systemImage: "wifi.slash")
            } else {
                List(model.networks, selection: $model.selection) { network in
                    HStack {
                        Image(systemName: network.ssid == model.current ? "wifi" : "wifi.circle").foregroundStyle(network.ssid == model.current ? .green : .secondary)
                        Text(network.ssid)
                        if network.ssid == model.current { Tag(text: "Connected", color: .green) }
                        Spacer()
                        Text(network.device).font(.caption).foregroundStyle(.tertiary)
                    }
                    .tag(network.id)
                }
            }
        }
        .navigationTitle("Saved Wi-Fi")
        .toolbar { Button { Task { await model.load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") } }
        .task { await model.load() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Text("\(model.networks.count) saved · \(model.selection.count) selected").foregroundStyle(.secondary)
                Spacer()
                Button("Forget Selected", role: .destructive) { confirming = true }.disabled(model.selection.isEmpty)
            }
            .padding(14).background(.bar)
        }
        .confirmationDialog("Forget \(model.selection.count) network(s)?", isPresented: $confirming) {
            Button("Forget", role: .destructive) { Task { _ = await model.forget(model.selection) } }
        } message: { Text("You'll need the password to join them again.") }
    }
}

// MARK: - Permissions

struct PermissionsView: View {
    @Environment(Store.self) private var store
    @State private var filter: PrivacyPermission?
    private var model: PermissionsModel { store.permissions }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(item: .permissions, subtitle: "Which apps can use your camera, microphone, screen, files and more. Read-only; changes happen in System Settings.",
                         value: nil, loading: model.isLoading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(nil, "All", "square.grid.2x2", model.apps.count)
                    ForEach(PrivacyPermission.allCases) { p in
                        let count = model.apps.filter { $0.permissions.contains(p) }.count
                        if count > 0 { chip(p, p.rawValue, p.symbol, count) }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            Divider()
            if model.needsFullDiskAccess {
                ContentUnavailableView {
                    Label("Full Disk Access needed", systemImage: "lock.shield")
                } description: {
                    Text("macOS keeps the permission database private. Grant DevSweep Full Disk Access to read it.")
                } actions: {
                    Button("Open Settings") { Store.openFullDiskAccessSettings() }
                }
            } else {
                List(model.apps.filter { filter == nil || $0.permissions.contains(filter!) }) { app in
                    HStack(spacing: 10) {
                        if let url = app.appURL { FileIcon(url: url, size: 26) } else { Image(systemName: "app").frame(width: 26) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name).fontWeight(.medium)
                            HStack(spacing: 4) {
                                ForEach(app.permissions) { p in
                                    Button { NSWorkspace.shared.open(p.settingsURL) } label: {
                                        Label(p.rawValue, systemImage: p.symbol).font(.caption2)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(.quaternary, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Open \(p.rawValue) in System Settings")
                                }
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .navigationTitle("App Permissions")
        .toolbar { Button { Task { await model.load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") } }
        .task { await model.load() }
    }

    private func chip(_ p: PrivacyPermission?, _ title: String, _ symbol: String, _ count: Int) -> some View {
        Button { filter = p } label: {
            Label("\(title) \(count)", systemImage: symbol).font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(filter == p ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.6)), in: Capsule())
                .foregroundStyle(filter == p ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}
