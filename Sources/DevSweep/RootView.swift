import SwiftUI

struct RootView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: Binding($store.section)) {
                SwiftUI.Section {
                    row(.smartCare)
                    row(.overview)
                }
                SwiftUI.Section("Cleanup") {
                    row(.junk, badge: store.junkTotal)
                    row(.caches, badge: store.cacheTotal)
                    row(.projects, badge: store.projectTotal)
                }
                SwiftUI.Section("My Clutter") {
                    row(.largeFiles, badge: store.largeFiles.total)
                    row(.duplicates, badge: store.duplicates.wasted)
                }
                SwiftUI.Section("Applications & Speed") {
                    row(.apps)
                    row(.performance)
                }
                SwiftUI.Section("Explore") {
                    row(.explorer)
                    row(.activity)
                }
            }
            .safeAreaInset(edge: .bottom) { DiskGauge().padding(14) }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            switch store.section {
            case .smartCare: SmartCareView()
            case .overview: OverviewView()
            case .junk: CachesView(kind: .junk)
            case .caches: CachesView(kind: .developer)
            case .projects: ProjectsView()
            case .largeFiles: LargeFilesView()
            case .duplicates: DuplicatesView()
            case .apps: AppsView()
            case .performance: PerformanceView()
            case .explorer: ExplorerView()
            case .activity: ActivityView()
            }
        }
        .task {
            if store.lastScan == nil { await store.scanCaches() }
            await store.trash.refresh()
        }
    }

    private func row(_ item: SidebarItem, badge: Int64 = 0) -> some View {
        Label {
            Text(item.rawValue)
        } icon: {
            Image(systemName: item.symbol).foregroundStyle(item.tint)
        }
        .badge(badge > 0 ? Text(badge.byteString).monospacedDigit() : nil)
        .tag(item)
    }
}

/// Menu bar popover: free space at a glance plus quick actions.
struct MenuBarView: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
                Text("DevSweep").font(.headline)
                Spacer()
                if store.isScanningCaches || store.smartStage != nil { ProgressView().controlSize(.small) }
            }
            DiskGauge()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reclaimable").font(.caption).foregroundStyle(.secondary)
                    Text(store.reclaimable.byteString).font(.title3.weight(.bold)).monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Memory").font(.caption).foregroundStyle(.secondary)
                    Text("\(Int(store.performance.memoryPressure * 100))%").font(.title3.weight(.bold)).monospacedDigit()
                }
            }
            Divider()
            Button {
                show(.smartCare)
                Task { await store.smartScan() }
            } label: { Label("Run Smart Scan", systemImage: "sparkles") }
            Button { show(.junk) } label: { Label("Review System Junk", systemImage: "trash.circle") }
            Button { show(.caches) } label: { Label("Review Developer Caches", systemImage: "hammer.circle") }
            Button { show(.explorer) } label: { Label("Open Space Lens", systemImage: "circle.hexagongrid") }
            Divider()
            Button("Quit DevSweep") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .padding(14)
        .frame(width: 280)
        .onAppear { store.performance.refresh(); store.disk = FileOps.diskSpace() }
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
