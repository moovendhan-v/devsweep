import AppKit
import SwiftUI

struct RootView: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @AppStorage("collapsedSections") private var collapsedRaw = ""
    @AppStorage("onboardingVersion") private var onboardingVersion = 0

    private struct SidebarSection: Identifiable {
        let title: String
        let items: [SidebarItem]
        var id: String { title }
    }

    private let sections: [SidebarSection] = [
        SidebarSection(title: "", items: [.smartCare, .overview]),
        SidebarSection(title: "Cleanup", items: [.junk, .caches, .projects, .history]),
        SidebarSection(title: "Protection", items: [.malware, .privacy, .browserExtensions, .wifi, .permissions]),
        SidebarSection(title: "Speed", items: [.memory, .optimization, .performance, .network]),
        SidebarSection(title: "Applications", items: [.apps, .updater, .extensions, .defaultApps]),
        SidebarSection(title: "Files", items: [.explorer, .largeFiles, .duplicates, .shredder]),
        SidebarSection(title: "Automation", items: [.automation, .activity]),
    ]

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: "|").map(String.init)) }

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: Binding($store.section)) {
                ForEach(sections) { section in
                    if section.title.isEmpty {
                        ForEach(section.items, id: \.self) { row($0) }
                    } else {
                        SwiftUI.Section(isExpanded: Binding(
                            get: { !collapsed.contains(section.title) },
                            set: { open in
                                var set = collapsed
                                if open { set.remove(section.title) } else { set.insert(section.title) }
                                collapsedRaw = set.sorted().joined(separator: "|")
                            })) {
                            ForEach(section.items, id: \.self) { row($0) }
                        } header: {
                            Text(section.title)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                DiskGauge().padding(12).background(.regularMaterial)
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 250)
        } detail: {
            detail
        }
        .sheet(isPresented: Binding(get: { onboardingVersion < 1 && ProcessInfo.processInfo.environment["DEVSWEEP_SNAPSHOT"] == nil },
                                    set: { if !$0 { onboardingVersion = 1 } })) {
            OnboardingView().environment(store)
        }
        .task {
            store.memory.start()
            store.system.start()
            store.automation.start()
            if store.lastScan == nil { await store.scanCaches() }
            await store.trash.refresh()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch store.section {
        case .smartCare: SmartCareView()
        case .overview: OverviewView()
        case .junk: CachesView(kind: .junk)
        case .caches: CachesView(kind: .developer)
        case .projects: ProjectsView()
        case .history: HistoryView()
        case .malware: MalwareView()
        case .privacy: PrivacyView()
        case .browserExtensions: BrowserExtensionsView()
        case .wifi: WiFiView()
        case .permissions: PermissionsView()
        case .memory: MemoryView()
        case .optimization: OptimizationView()
        case .performance: PerformanceView()
        case .network: NetworkView()
        case .apps: AppsView()
        case .updater: UpdaterView()
        case .extensions: ExtensionsView()
        case .defaultApps: DefaultAppsView()
        case .explorer: ExplorerView()
        case .largeFiles: LargeFilesView()
        case .duplicates: DuplicatesView()
        case .shredder: ShredderView()
        case .automation: AutomationView()
        case .activity: ActivityView()
        }
    }

    private func badge(for item: SidebarItem) -> Text? {
        switch item {
        case .junk: store.junkTotal > 0 ? Text(store.junkTotal.byteString) : nil
        case .caches: store.cacheTotal > 0 ? Text(store.cacheTotal.byteString) : nil
        case .projects: store.projectTotal > 0 ? Text(store.projectTotal.byteString) : nil
        case .largeFiles: store.largeFiles.total > 0 ? Text(store.largeFiles.total.byteString) : nil
        case .duplicates: store.duplicates.wasted > 0 ? Text(store.duplicates.wasted.byteString) : nil
        case .memory: Text("\(Int(store.memory.current.usedFraction * 100))%")
        case .network: Text(store.system.downRate.rateString)
        case .malware: store.malware.threats.isEmpty ? nil : Text("\(store.malware.threats.count)")
        case .updater: store.updater.updates.isEmpty ? nil : Text("\(store.updater.updates.count)")
        default: nil
        }
    }

    private func row(_ item: SidebarItem) -> some View {
        Label {
            Text(item.rawValue).fontWeight(item == .smartCare ? .semibold : .regular)
        } icon: {
            Image(systemName: item.symbol).foregroundStyle(item == .smartCare ? theme.accent : item.tint)
        }
        .badge(badge(for: item)?.monospacedDigit())
        .tag(item)
    }
}

/// Menu bar popover: live vitals, network, tips and quick actions.
struct MenuBarView: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let mem = store.memory.current
        let sys = store.system
        let diskUsed = Double(store.disk.total - store.disk.free) / Double(max(store.disk.total, 1))
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text("DevSweep").font(.headline)
                    Text("Up \(sys.uptime.uptimeString)").font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.borderless)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ring("CPU", "cpu", sys.cpu, "\(Int(sys.cpu * 100))%", sys.gpu.map { "GPU \(Int($0 * 100))%" })
                ring("Memory", "memorychip", mem.usedFraction, "\(Int(mem.usedFraction * 100))%", "\(mem.swapUsed.byteString) swap")
                ring("Disk", "internaldrive", diskUsed, "\(Int(diskUsed * 100))%", "\(store.disk.free.byteString) free")
                if let battery = sys.battery {
                    ring("Battery", battery.isCharging ? "battery.100.bolt" : "battery.75", battery.level, "\(Int(battery.level * 100))%",
                         battery.health.map { "Health \(Int($0 * 100))%" + (battery.cycles.map { " · \($0) cycles" } ?? "") })
                } else {
                    ring("Network", "network", min(sys.downRate / max(sys.peakDown, 1), 1), sys.downRate.rateString, "↑ \(sys.upRate.rateString)")
                }
            }

            HStack(spacing: 0) {
                stat("arrow.down", sys.downRate.rateString)
                Divider().frame(height: 18)
                stat("arrow.up", sys.upRate.rateString)
                Divider().frame(height: 18)
                stat("calendar", sys.today.total.byteString)
            }
            .padding(.vertical, 8)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

            if let tip = tips.first {
                HStack(spacing: 10) {
                    Image(systemName: tip.symbol).foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tip.title).font(.callout.weight(.semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Text(tip.detail).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
                    }
                    Spacer()
                    Button(tip.action) { show(tip.section) }.buttonStyle(.borderedProminent).tint(theme.accent).controlSize(.small)
                }
                .padding(10)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }

            if !sys.volumes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sys.volumes) { volume in
                        HStack {
                            Image(systemName: "externaldrive")
                            Text(volume.name).lineLimit(1)
                            Spacer()
                            Text("\(volume.free.byteString) free").foregroundStyle(.white.opacity(0.7))
                            Button { try? NSWorkspace.shared.unmountAndEjectDevice(at: volume.url) } label: { Image(systemName: "eject") }
                                .buttonStyle(.borderless)
                        }
                        .font(.caption)
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    if store.automation.isKeepingAwake { store.automation.stopKeepAwake() } else { store.automation.keepAwake(for: nil) }
                } label: {
                    Label(store.automation.isKeepingAwake ? "Awake" : "Keep Awake",
                          systemImage: store.automation.isKeepingAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .frame(maxWidth: .infinity)
                }
                Button { Task { _ = await store.memory.freeUpRAM() } } label: { Label("Free RAM", systemImage: "bolt.fill").frame(maxWidth: .infinity) }
            }
            .controlSize(.large)

            HStack(spacing: 8) {
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                Button {
                    show(.smartCare)
                } label: {
                    Label("Open DevSweep", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(theme.accent).controlSize(.large)
            }
        }
        .padding(16)
        .frame(width: 320)
        .foregroundStyle(.white)
        .background(theme.hero)
        .onAppear {
            store.memory.start()
            store.system.start()
            store.disk = FileOps.diskSpace()
        }
    }

    private func ring(_ title: String, _ symbol: String, _ value: Double, _ label: String, _ caption: String?) -> some View {
        let color: Color = value > 0.85 ? .red : value > 0.65 ? .orange : .green
        return VStack(spacing: 6) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold))
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 7)
                Circle().trim(from: 0, to: min(max(value, 0.01), 1))
                    .stroke(color.gradient, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(label).font(.system(size: 14, weight: .bold, design: .rounded)).monospacedDigit()
            }
            .frame(width: 66, height: 66)
            .animation(.smooth, value: value)
            Text(caption ?? " ").font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private func stat(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1)
            .frame(maxWidth: .infinity)
    }

    private struct Tip { let symbol: String; let title: String; let detail: String; let action: String; let section: SidebarItem }

    private var tips: [Tip] {
        var result: [Tip] = []
        let mem = store.memory.current
        if store.isDiskLow {
            result.append(Tip(symbol: "internaldrive.fill", title: "Only \(store.disk.free.byteString) free",
                              detail: "Run Smart Care to find caches and junk you can remove.", action: "Free Up", section: .smartCare))
        }
        if mem.pressure != .normal {
            result.append(Tip(symbol: "memorychip.fill", title: "Memory pressure \(mem.pressure.label.lowercased())",
                              detail: "\(store.memory.groups.first.map { "\($0.name) uses \($0.memory.byteString)." } ?? "") Speed Up can help.",
                              action: "Speed Up", section: .memory))
        }
        if store.trash.size > 1_000_000_000 {
            result.append(Tip(symbol: "trash.fill", title: "Trash holds \(store.trash.size.byteString)", detail: "Empty it to get the space back.",
                              action: "Review", section: .junk))
        }
        if store.cacheTotal > 2_000_000_000 {
            result.append(Tip(symbol: "hammer.fill", title: "Developer caches: \(store.cacheTotal.byteString)", detail: "Most rebuild automatically.",
                              action: "Review", section: .caches))
        }
        if !store.malware.threats.isEmpty {
            result.insert(Tip(symbol: "exclamationmark.shield.fill", title: "\(store.malware.threats.count) possible threat(s)",
                              detail: "Review what the malware scan found.", action: "Review", section: .malware), at: 0)
        }
        return result
    }

    private func show(_ item: SidebarItem) {
        store.section = item
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct DiskGauge: View {
    @Environment(Store.self) private var store

    var body: some View {
        let used = Double(store.disk.total - store.disk.free)
        let total = Double(max(store.disk.total, 1))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "internaldrive")
                Text("Macintosh HD").font(.caption.weight(.medium))
                Spacer()
                if store.isDiskLow {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption)
                }
            }
            ProgressView(value: used, total: total)
                .tint(store.isDiskLow ? .red : .accentColor)
            Text("\(store.disk.free.byteString) free of \(store.disk.total.byteString)")
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
