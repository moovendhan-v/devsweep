import AppKit
import Charts
import SwiftUI

enum MemoryColors {
    static let wired = Color.orange
    static let compressed = Color.purple
    static let cached = Color.teal
    static let swap = Color.red
}

struct MemoryView: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @State private var range: Double = 300
    @State private var filter: Filter = .apps
    @State private var search = ""
    @State private var showSpeedUp = false
    @State private var showSwapInfo = false
    @State private var confirmRestart = false

    enum Filter: String, CaseIterable { case apps = "Apps", mine = "All my processes", all = "Everything" }

    private var monitor: MemoryMonitor { store.memory }
    private var snap: MemorySnapshot { monitor.current }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusBanner
                HStack(alignment: .top, spacing: 16) {
                    ramCard
                    breakdownCard
                    swapCard
                }
                .fixedSize(horizontal: false, vertical: true)
                historyCard
                processCard
            }
            .padding(24)
        }
        .navigationTitle("Memory & Swap")
        .searchable(text: $search, placement: .toolbar, prompt: "Find a process")
        .toolbar {
            Button { monitor.sample(); monitor.refreshProcesses() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .sheet(isPresented: $showSpeedUp) { SpeedUpSheet().environment(store) }
        .confirmationDialog("Restart your Mac?", isPresented: $confirmRestart) {
            Button("Restart", role: .destructive) {
                NSAppleScript(source: "tell application \"System Events\" to restart")?.executeAndReturnError(nil)
            }
        } message: {
            Text("Restarting clears all swap files and gives every app fresh memory. Save your work first; apps will be asked to quit.")
        }
    }

    // MARK: Header & status

    private var header: some View {
        HStack(spacing: 16) {
            IconBadge(symbol: "memorychip", color: theme.accent, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("Memory & Swap").font(.title2.weight(.bold))
                Text("Live RAM, compression and swap, sampled every \(Int(monitor.interval)) s. History covers the last 30 minutes.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(snap.usedFraction * 100))%")
                    .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(theme.accent.gradient)
                    .contentTransition(.numericText())
                Text("\(snap.used.byteString) of \(snap.total.byteString)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var statusBanner: some View {
        let color = Color(nsColor: snap.pressure.color)
        let swapHeavy = snap.swapUsed > snap.total / 4
        return HStack(spacing: 14) {
            Image(systemName: snap.pressure == .normal ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.title).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text("Memory pressure: \(snap.pressure.label)").font(.headline)
                Text(snap.pressure.advice + (swapHeavy ? " \(snap.swapUsed.byteString) is in swap on disk, which is much slower than RAM." : ""))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if swapHeavy {
                Button("Restart to Clear Swap…") { confirmRestart = true }
            }
            Button { showSpeedUp = true } label: {
                Label("Speed Up", systemImage: "bolt.fill").font(.headline)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(theme.button, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(color.opacity(0.35)))
    }

    // MARK: Cards

    private var ramCard: some View {
        Card {
            VStack(spacing: 12) {
                Text("RAM").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                SegmentRing(segments: [
                    (Double(snap.app), theme.accent), (Double(snap.wired), MemoryColors.wired),
                    (Double(snap.compressed), MemoryColors.compressed), (Double(snap.cached), MemoryColors.cached.opacity(0.45)),
                ], total: Double(snap.total)) {
                    VStack(spacing: 0) {
                        Text("\(Int(snap.usedFraction * 100))%").font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("used").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 150, height: 150)
                HStack {
                    stat("Available", "\(snap.availablePercent)%")
                    Spacer()
                    stat("Peak", monitor.peakUsed.byteString)
                }
            }
        }
    }

    private var breakdownCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("What's using it").font(.headline)
                legendRow("App memory", snap.app, theme.accent, "Memory used by apps and their helpers.")
                legendRow("Wired", snap.wired, MemoryColors.wired, "Used by macOS itself; can't be freed.")
                legendRow("Compressed", snap.compressed, MemoryColors.compressed, "Squeezed in RAM to avoid swapping.")
                legendRow("Cached files", snap.cached, MemoryColors.cached, "Reusable file cache; freed automatically.")
                legendRow("Free", snap.free, .gray, "Not used at all.")
            }
        }
    }

    private var swapCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Swap").font(.headline)
                    Spacer()
                    Button { showSwapInfo.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless)
                        .popover(isPresented: $showSwapInfo, arrowEdge: .bottom) { swapInfo }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(snap.swapUsed.byteString).font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("of \(snap.swapTotal.byteString)").foregroundStyle(.secondary)
                }
                SizeBar(fraction: snap.swapFraction, color: snap.swapFraction > 0.8 ? .red : .orange)
                HStack {
                    stat("Swap files", "\(monitor.swapFiles.count)")
                    Spacer()
                    stat("Swapping in", rate(monitor.swapInRate))
                    Spacer()
                    stat("Out", rate(monitor.swapOutRate))
                }
                Text(swapSummary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var swapSummary: String {
        if snap.swapUsed == 0 { return "No swap in use. Everything fits in RAM." }
        if monitor.swapOutRate > 0.5 { return "macOS is moving memory to disk right now. This is when your Mac feels slow." }
        return "Old swap stays on disk until it's needed again or you restart. It only slows things down while it's being read back."
    }

    private var swapInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About swap on macOS").font(.headline)
            Text("macOS creates and deletes swap files on its own (in /System/Volumes/VM) as memory runs short. Apps, including DevSweep, can't create, resize or delete them: that volume is protected by System Integrity Protection, and removing a swap file in use would crash your Mac.")
            Text("To shrink swap safely:").fontWeight(.semibold)
            Label("Quit the apps using the most memory", systemImage: "1.circle")
            Label("Use Speed Up to free inactive RAM", systemImage: "2.circle")
            Label("Restart. All swap files are removed at boot.", systemImage: "3.circle")
            if !monitor.swapFiles.isEmpty {
                Divider()
                ForEach(monitor.swapFiles) { file in
                    HStack {
                        Text(file.name).font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text(file.size.byteString).font(.caption).monospacedDigit()
                        Text(file.modified?.formatted(date: .omitted, time: .shortened) ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.callout)
        .padding(16)
        .frame(width: 380)
    }

    // MARK: History

    private struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let kind: String
        let gb: Double
    }

    private var historyCard: some View {
        let cutoff = Date().addingTimeInterval(-range)
        let samples = monitor.history.filter { $0.date >= cutoff }
        let areas = samples.flatMap { s in
            [Point(date: s.date, kind: "App", gb: gb(s.app)), Point(date: s.date, kind: "Wired", gb: gb(s.wired)),
             Point(date: s.date, kind: "Compressed", gb: gb(s.compressed))]
        }
        let swap = samples.map { Point(date: $0.date, kind: "Swap", gb: gb($0.swapUsed)) }

        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Usage over time").font(.headline)
                    Spacer()
                    Picker("", selection: $range) {
                        Text("1 min").tag(60.0)
                        Text("5 min").tag(300.0)
                        Text("15 min").tag(900.0)
                        Text("30 min").tag(1800.0)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 280)
                    Button("Reset Peaks") { monitor.resetPeaks() }.controlSize(.small)
                }
                if samples.count < 2 {
                    Text("Collecting samples…").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    Chart {
                        ForEach(areas) { point in
                            AreaMark(x: .value("Time", point.date), y: .value("GB", point.gb))
                                .foregroundStyle(by: .value("Type", point.kind))
                                .interpolationMethod(.monotone)
                        }
                        ForEach(swap) { point in
                            LineMark(x: .value("Time", point.date), y: .value("GB", point.gb), series: .value("Series", "Swap"))
                                .foregroundStyle(MemoryColors.swap)
                                .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                                .interpolationMethod(.monotone)
                        }
                        RuleMark(y: .value("RAM", gb(snap.total)))
                            .foregroundStyle(.secondary.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                            .annotation(position: .top, alignment: .leading) {
                                Text("Installed RAM").font(.caption2).foregroundStyle(.secondary)
                            }
                    }
                    .chartForegroundStyleScale(["App": theme.accent, "Wired": MemoryColors.wired,
                                                "Compressed": MemoryColors.compressed])
                    .chartYAxis { AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v)) GB") } }
                    } }
                    .chartLegend(position: .top, alignment: .leading)
                    .frame(height: 220)
                    HStack(spacing: 6) {
                        Rectangle().fill(MemoryColors.swap).frame(width: 16, height: 2)
                        Text("Swap used").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("Peak swap \(monitor.peakSwap.byteString)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Processes

    private var visibleGroups: [ProcessGroup] {
        monitor.groups
            .filter { group in
                switch filter {
                case .apps: group.appURL != nil
                case .mine: group.isMine
                case .all: true
                }
            }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var processCard: some View {
        let groups = Array(visibleGroups.prefix(40))
        let maxMemory = Double(max(groups.first?.memory ?? 1, 1))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Memory by app").font(.title3.weight(.semibold))
                Text("helpers are grouped into their app").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 330)
            }
            Card {
                VStack(spacing: 0) {
                    if groups.isEmpty {
                        Text(monitor.groups.isEmpty ? "Reading processes…" : "No matches").foregroundStyle(.secondary).padding()
                    }
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        if index > 0 { Divider().padding(.leading, 40) }
                        ProcessRow(group: group, fraction: Double(group.memory) / maxMemory, total: snap.total)
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private func gb(_ bytes: Int64) -> Double { Double(bytes) / 1_073_741_824 }

    private func rate(_ value: Double) -> String {
        value < 0.5 ? "idle" : "\(Int(value))/s"
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
    }

    private func legendRow(_ title: String, _ bytes: Int64, _ color: Color, _ help: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(color.gradient).frame(width: 12, height: 12)
            Text(title)
            Spacer()
            Text(bytes.byteString).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
        .help(help)
    }
}

/// Ring split into colored segments (app, wired, compressed, cached).
struct SegmentRing<Center: View>: View {
    let segments: [(Double, Color)]
    let total: Double
    @ViewBuilder let center: Center

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 16)
            ForEach(Array(ranges.enumerated()), id: \.offset) { _, item in
                Circle()
                    .trim(from: item.0, to: item.1)
                    .stroke(item.2.gradient, style: StrokeStyle(lineWidth: 16, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            center
        }
        .animation(.smooth, value: segments.map(\.0))
        .padding(8)
    }

    private var ranges: [(Double, Double, Color)] {
        var start = 0.0
        return segments.map { value, color in
            let end = min(1, start + value / max(total, 1))
            defer { start = end }
            return (start, end, color)
        }
    }
}

private struct ProcessRow: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    let group: ProcessGroup
    let fraction: Double
    let total: Int64
    @State private var confirmForce = false

    var body: some View {
        HStack(spacing: 10) {
            if let app = group.appURL {
                FileIcon(url: app, size: 26)
            } else {
                Image(systemName: "gearshape.2").frame(width: 26).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name).fontWeight(.medium).lineLimit(1)
                Text(group.processCount == 1 ? "1 process" : "\(group.processCount) processes")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            SizeBar(fraction: fraction, color: theme.accent).frame(width: 140)
            Text(group.memory.byteString).monospacedDigit().frame(width: 80, alignment: .trailing)
            Text("\(String(format: "%.1f", Double(group.memory) / Double(max(total, 1)) * 100))%")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 44, alignment: .trailing)
            if group.isMine {
                Menu {
                    Button("Quit") { store.memory.quit(group, force: false) }
                    Button("Force Quit…", role: .destructive) { confirmForce = true }
                    if let app = group.appURL { Button("Reveal in Finder") { NSWorkspace.shared.reveal([app]) } }
                } label: {
                    Text("Quit")
                } primaryAction: {
                    store.memory.quit(group, force: false)
                }
                .menuStyle(.borderedButton)
                .fixedSize()
                .controlSize(.small)
            } else {
                Text("System").font(.caption).foregroundStyle(.tertiary).frame(width: 58)
            }
        }
        .padding(.vertical, 6)
        .confirmationDialog("Force quit \(group.name)?", isPresented: $confirmForce) {
            Button("Force Quit", role: .destructive) { store.memory.quit(group, force: true) }
        } message: {
            Text("Unsaved changes in \(group.name) will be lost.")
        }
    }
}

/// One-click speed up: free inactive RAM and quit selected memory hogs.
struct SpeedUpSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var purge = true
    @State private var quitSelection: Set<String> = []
    @State private var running = false
    @State private var result: String?

    private var hogs: [ProcessGroup] {
        Array(store.memory.groups.filter { $0.appURL != nil && $0.isMine && $0.name != "DevSweep" }.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconBadge(symbol: "bolt.fill", color: theme.accent, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speed Up Your Mac").font(.title2.weight(.bold))
                    Text("Using \(store.memory.current.used.byteString) RAM · \(store.memory.current.swapUsed.byteString) swap")
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $purge) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Free up inactive RAM").fontWeight(.medium)
                    Text("Runs macOS's purge tool. macOS asks for your admin password.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 6) {
                Text("Quit memory-hungry apps").fontWeight(.medium)
                ForEach(hogs) { group in
                    Toggle(isOn: Binding(get: { quitSelection.contains(group.id) },
                                         set: { if $0 { quitSelection.insert(group.id) } else { quitSelection.remove(group.id) } })) {
                        HStack(spacing: 8) {
                            if let app = group.appURL { FileIcon(url: app, size: 20) }
                            Text(group.name)
                            Spacer()
                            Text(group.memory.byteString).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                Text("Apps are asked to quit normally, so they can save your work.").font(.caption).foregroundStyle(.secondary)
            }

            if let result {
                Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }

            HStack {
                Spacer()
                Button(result == nil ? "Cancel" : "Done") { dismiss() }
                Button {
                    Task { await run() }
                } label: {
                    HStack {
                        if running { ProgressView().controlSize(.small) }
                        Text("Speed Up")
                    }
                    .padding(.horizontal, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(running || (!purge && quitSelection.isEmpty))
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func run() async {
        running = true
        let before = store.memory.current
        for group in hogs where quitSelection.contains(group.id) { store.memory.quit(group, force: false) }
        if !quitSelection.isEmpty { try? await Task.sleep(for: .seconds(2)) }
        var purged = true
        if purge { purged = await store.memory.freeUpRAM().ok }
        store.memory.sample()
        let after = store.memory.current
        let freed = max(0, before.used - after.used)
        result = (purge && !purged ? "Free RAM was cancelled. " : "")
            + "Freed \(freed.byteString) of RAM. Now using \(after.used.byteString), swap \(after.swapUsed.byteString)."
        store.log.insert("✓ Speed Up: freed \(freed.byteString) RAM", at: 0)
        quitSelection = []
        running = false
    }
}
