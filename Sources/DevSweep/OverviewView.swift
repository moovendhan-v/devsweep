import Charts
import SwiftUI

struct OverviewView: View {
    @Environment(Store.self) private var store
    @State private var confirmSafeClean = false

    private struct Slice: Identifiable {
        let name: String
        let bytes: Int64
        let color: Color
        var id: String { name }
    }

    private var slices: [Slice] {
        var result = TargetGroup.allCases.map { Slice(name: $0.rawValue, bytes: store.groupBytes($0), color: $0.color) }
        result.append(Slice(name: "Project Folders", bytes: store.projectTotal, color: Palette.projects))
        return result.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if store.isDiskLow { lowDiskBanner }
                diskCard
                HStack(alignment: .top, spacing: 18) {
                    reclaimCard
                    breakdownCard
                }
                .fixedSize(horizontal: false, vertical: true)

                Text("Categories").font(.title3.weight(.semibold)).padding(.top, 4)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
                    ForEach(TargetGroup.allCases) { group in
                        CategoryCard(symbol: group.symbol, color: group.color, title: group.rawValue,
                                     bytes: store.groupBytes(group),
                                     subtitle: "\(store.locationCount(group)) locations with data",
                                     loading: store.isScanningCaches) {
                            store.focus(group)
                        }
                    }
                    CategoryCard(symbol: "folder.badge.gearshape", color: Palette.projects, title: "Project Folders",
                                 bytes: store.projectTotal,
                                 subtitle: store.projectRoot == nil ? "Not scanned yet"
                                     : "\(store.projectJunk.count) folders in \(store.projectRoot!.lastPathComponent)",
                                 loading: store.projectScanStatus != nil) {
                        store.section = .projects
                    }
                }

                biggestItems
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Dashboard")
        .toolbar {
            Button { Task { await store.scanCaches() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .disabled(store.isScanningCaches)
        }
        .confirmationDialog("Clean \(store.safeTargets.count) safe caches?", isPresented: $confirmSafeClean) {
            Button(store.moveToTrash ? "Move to Trash" : "Delete Permanently", role: .destructive) {
                Task { await store.cleanSelectedCaches(in: TargetGroup.allCases) }
            }
        } message: {
            Text(store.safeTargets.map(\.name).joined(separator: ", ") + "\n\nThese rebuild automatically the next time you build or install.")
        }
    }

    // MARK: Sections

    private var lowDiskBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your disk is almost full").font(.headline).foregroundStyle(.white)
                Text("Only \(store.disk.free.byteString) left. Builds, installs and macOS updates may fail.")
                    .font(.callout).foregroundStyle(.white.opacity(0.9))
            }
            Spacer()
            if !store.moveToTrash {
                EmptyView()
            } else {
                Text("Tip: turn off “Move to Trash” to free space instantly")
                    .font(.caption).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.trailing)
            }
        }
        .padding(16)
        .background(LinearGradient(colors: [.red, .orange], startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var diskCard: some View {
        let total = Double(max(store.disk.total, 1))
        let caches = Double(store.cacheTotal + store.junkTotal)
        let projects = Double(store.projectTotal)
        let free = Double(store.disk.free)
        let other = max(0, total - free - caches - projects)
        let segments: [(String, Double, Color)] = [
            ("Caches & junk", caches, TargetGroup.apple.color),
            ("Project folders", projects, Palette.projects),
            ("Everything else", other, Palette.otherUsed),
            ("Free", free, Palette.free),
        ]

        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Macintosh HD").font(.headline)
                    Spacer()
                    Text("\(Int64(total - free).byteString) used of \(store.disk.total.byteString)")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(segments, id: \.0) { _, value, color in
                            if value > 0 {
                                Rectangle().fill(color.gradient)
                                    .frame(width: max(3, (geo.size.width - 6) * value / total))
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .frame(height: 22)
                .animation(.smooth, value: caches + projects)

                HStack(spacing: 18) {
                    ForEach(segments, id: \.0) { name, value, color in
                        HStack(spacing: 6) {
                            Circle().fill(color).frame(width: 9, height: 9)
                            Text(name).foregroundStyle(.secondary)
                            Text(Int64(value).byteString).fontWeight(.medium).monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    private var reclaimCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("You can reclaim").font(.subheadline).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(store.reclaimable.byteString)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.smooth, value: store.reclaimable)
                    if store.isScanningCaches { ProgressView().controlSize(.small) }
                }
                if store.reclaimable == 0 && !store.isScanningCaches {
                    Label("All clean. Check Space Explorer for other big folders.", systemImage: "checkmark.seal.fill")
                        .font(.callout).foregroundStyle(.green)
                } else {
                    Text("Safe caches alone: \(store.safeTargets.reduce(0) { $0 + (store.sizes[$1.id] ?? 0) }.byteString). They rebuild automatically.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                HStack {
                    Button {
                        store.selected = Set(store.safeTargets.map(\.id))
                        store.childSelection = [:]
                        confirmSafeClean = true
                    } label: {
                        Label("Clean Safe Caches", systemImage: "sparkles").padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(store.safeTargets.isEmpty || store.isScanningCaches || store.isCleaning)

                    Button("Review…") { store.focus(nil) }
                        .controlSize(.large)
                    Button("Explore Disk") { store.browse(URL(fileURLWithPath: NSHomeDirectory())) }
                        .controlSize(.large)
                }
                if store.projectRoot == nil {
                    Button {
                        store.section = .projects
                    } label: {
                        Label("Scan your code folders for node_modules & build output", systemImage: "arrow.right.circle")
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
            }
        }
    }

    private var breakdownCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Breakdown").font(.headline)
                if slices.isEmpty {
                    Group {
                        if store.isScanningCaches {
                            ContentUnavailableView("Scanning…", systemImage: "chart.pie")
                        } else {
                            ContentUnavailableView("Nothing to clean", systemImage: "checkmark.seal.fill",
                                                   description: Text("Your developer caches are already tidy."))
                        }
                    }
                    .frame(height: 170)
                } else {
                    HStack(spacing: 16) {
                        Chart(slices) { slice in
                            SectorMark(angle: .value("Size", slice.bytes), innerRadius: .ratio(0.62), angularInset: 1.5)
                                .foregroundStyle(slice.color.gradient)
                                .cornerRadius(3)
                        }
                        .chartLegend(.hidden)
                        .frame(width: 150, height: 150)

                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(slices.prefix(6)) { slice in
                                HStack(spacing: 6) {
                                    Circle().fill(slice.color).frame(width: 8, height: 8)
                                    Text(slice.name).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(slice.bytes.byteString).foregroundStyle(.secondary).monospacedDigit()
                                }
                                .font(.caption)
                            }
                        }
                    }
                }
            }
        }
    }

    private var biggestItems: some View {
        struct Big: Identifiable { let id: String; let name: String; let detail: String; let bytes: Int64; let url: URL; let color: Color; let symbol: String }
        let caches = store.targets.compactMap { t -> Big? in
            guard let bytes = store.sizes[t.id], bytes > 0, let url = t.existingURLs.first else { return nil }
            return Big(id: t.id, name: t.name, detail: url.tildePath, bytes: bytes, url: url, color: t.group.color, symbol: t.group.symbol)
        }
        let junk = store.projectJunk.prefix(10).map {
            Big(id: $0.url.path, name: "\($0.projectName) › \($0.url.lastPathComponent)", detail: $0.url.tildePath,
                bytes: $0.size, url: $0.url, color: Palette.projects, symbol: "folder.fill")
        }
        let top = (caches + junk).sorted { $0.bytes > $1.bytes }.prefix(8)
        let maxBytes = Double(top.first?.bytes ?? 1)

        return VStack(alignment: .leading, spacing: 10) {
            Text("Biggest space users").font(.title3.weight(.semibold)).padding(.top, 4)
            Card {
                VStack(spacing: 0) {
                    ForEach(Array(top.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().padding(.leading, 44) }
                        HStack(spacing: 12) {
                            IconBadge(symbol: item.symbol, color: item.color, size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).fontWeight(.medium).lineLimit(1)
                                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            SizeBar(fraction: Double(item.bytes) / maxBytes, color: item.color).frame(width: 120)
                            Text(item.bytes.byteString).monospacedDigit().frame(width: 76, alignment: .trailing)
                            Button { store.browse(item.url) } label: { Image(systemName: "chevron.right.circle.fill") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Browse in Space Explorer")
                        }
                        .padding(.vertical, 8)
                    }
                    if top.isEmpty {
                        Text("Nothing found yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding()
                    }
                }
            }
        }
    }
}

struct CategoryCard: View {
    let symbol: String
    let color: Color
    let title: String
    let bytes: Int64
    let subtitle: String
    let loading: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    IconBadge(symbol: symbol, color: color, size: 38)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).lineLimit(1)
                    HStack(spacing: 6) {
                        if bytes == 0 && !loading {
                            Label("Clean", systemImage: "checkmark.circle.fill")
                                .font(.title3.weight(.semibold)).foregroundStyle(.green)
                        } else {
                            Text(bytes.byteString)
                                .font(.title2.weight(.semibold)).monospacedDigit()
                        }
                        if loading { ProgressView().controlSize(.mini) }
                    }
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hovering ? color.opacity(0.6) : Color(nsColor: .separatorColor).opacity(0.6)))
            .shadow(color: .black.opacity(hovering ? 0.08 : 0.04), radius: hovering ? 10 : 6, y: 2)
            .scaleEffect(hovering ? 1.01 : 1)
            .animation(.snappy(duration: 0.15), value: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
