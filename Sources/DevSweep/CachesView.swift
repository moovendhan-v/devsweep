import AppKit
import SwiftUI

/// Shared screen for "System Junk" and "Developer Caches": grouped, searchable list of
/// cache targets with drill-down into individual sub-folders.
struct CachesView: View {
    enum Kind { case developer, junk }

    @Environment(Store.self) private var store
    let kind: Kind
    @State private var confirming = false
    @State private var search = ""

    private var allGroups: [TargetGroup] { kind == .developer ? TargetGroup.developer : TargetGroup.junk }
    private var groups: [TargetGroup] {
        if let focus = store.cacheFocus, allGroups.contains(focus) { return [focus] }
        return allGroups
    }

    private func isVisible(_ target: CleanTarget) -> Bool {
        if store.hideMissing {
            guard store.isAvailable(target) else { return false }
            if target.command == nil && store.sizes[target.id] == 0 { return false }
        }
        guard !search.isEmpty else { return true }
        return target.name.localizedCaseInsensitiveContains(search) || target.detail.localizedCaseInsensitiveContains(search)
    }

    private func targets(in group: TargetGroup) -> [CleanTarget] {
        let items = store.targets.filter { $0.group == group && isVisible($0) }
        return items.sorted { (store.sizes[$0.id] ?? -1) > (store.sizes[$1.id] ?? -1) }
    }

    private var largest: Int64 {
        let values = store.targets.filter { allGroups.contains($0.group) }.compactMap { store.sizes[$0.id] }
        return max(values.max() ?? 1, 1)
    }

    private var title: String { kind == .developer ? "Developer Caches" : "System Junk" }
    private var total: Int64 { kind == .developer ? store.cacheTotal : store.junkTotal }
    private var focusTitle: String? {
        guard let focus = store.cacheFocus, allGroups.contains(focus) else { return nil }
        return focus.rawValue
    }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(item: kind == .developer ? .caches : .junk,
                         subtitle: kind == .developer
                            ? "Build products, package caches and tool data, found by asking your tools and scanning your disk."
                            : "App caches, browser & Electron caches, logs and leftover downloads.",
                         value: total, loading: store.isScanningCaches)
            if kind == .junk { TrashCard().padding(.horizontal, 16).padding(.top, 10) }
            filterBar
            Divider()
            list
        }
        .navigationTitle(focusTitle ?? title)
        .searchable(text: $search, placement: .toolbar, prompt: "Filter")
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .confirmationDialog(confirmTitle, isPresented: $confirming) {
            Button(store.moveToTrash ? "Move to Trash" : "Delete Permanently", role: .destructive) {
                Task { await store.cleanSelectedCaches(in: allGroups) }
            }
        } message: {
            Text(selectedNames)
        }
    }

    private var confirmTitle: String {
        "Clean \(store.selectionCount(in: allGroups)) item(s) · \(store.selectedBytes(in: allGroups).byteString)?"
    }

    // MARK: Pieces

    @ViewBuilder
    private var list: some View {
        let visible: [(TargetGroup, [CleanTarget])] = groups.map { ($0, targets(in: $0)) }.filter { !$0.1.isEmpty }
        if visible.isEmpty && !store.isScanningCaches {
            ContentUnavailableView {
                Label(search.isEmpty ? "All clean" : "No matches",
                      systemImage: search.isEmpty ? "checkmark.seal.fill" : "magnifyingglass")
            } description: {
                Text(search.isEmpty ? "Nothing to clean here right now." : "Try a different filter.")
            }
            .frame(maxHeight: .infinity)
        } else {
            List {
                if store.isDiscovering {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Asking your tools where their caches live and scanning your disk…").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                ForEach(visible, id: \.0) { entry in
                    SwiftUI.Section {
                        ForEach(entry.1) { target in
                            TargetRow(target: target, largest: largest)
                        }
                    } header: {
                        GroupHeader(group: entry.0, targets: entry.1)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Chip(title: "All", symbol: "square.grid.2x2", color: .accentColor, bytes: total,
                     isOn: focusTitle == nil) { store.cacheFocus = nil }
                ForEach(allGroups) { group in
                    Chip(title: group.rawValue, symbol: group.symbol, color: group.color,
                         bytes: store.groupBytes(group), isOn: store.cacheFocus == group) {
                        store.cacheFocus = group
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Toggle(isOn: Bindable(store).hideMissing) {
                Label("Hide empty & missing", systemImage: "eye.slash")
            }
            .help("Hide caches that are empty or not on this Mac")
            Button { Task { await store.scanCaches() } } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(store.isScanningCaches || store.isCleaning)
        }
    }

    private var bottomBar: some View {
        let bytes = store.selectedBytes(in: allGroups)
        let count = store.selectionCount(in: allGroups)
        return CleanBar(title: bytes == 0 ? "Clean" : "Clean \(bytes.byteString)",
                        disabled: count == 0 || store.isScanningCaches) {
            HStack(spacing: 10) {
                Text("\(count) selected").foregroundStyle(.secondary)
                Button("Select Safe", action: selectSafe).buttonStyle(.link)
                Button("Clear", action: clearSelection).buttonStyle(.link)
            }
        } action: {
            confirming = true
        }
    }

    private func selectSafe() {
        clearSelection()
        store.selected.formUnion(store.safeTargets(in: allGroups).map(\.id))
    }

    private func clearSelection() {
        for target in store.targets where allGroups.contains(target.group) {
            store.selected.remove(target.id)
            store.childSelection[target.id] = nil
        }
    }

    private var selectedNames: String {
        store.targets.filter { allGroups.contains($0.group) && store.checkState($0) != .off }
            .map(\.name).prefix(12).joined(separator: ", ")
    }
}

/// Trash summary with an Empty button, shown on top of System Junk.
struct TrashCard: View {
    @Environment(Store.self) private var store
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: "trash.fill", color: .gray, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Trash").fontWeight(.semibold)
                if store.trash.readable {
                    Text(store.trash.count == 0 ? "Empty" : "\(store.trash.count) items waiting to be deleted")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Give DevSweep Full Disk Access to measure the Trash").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if store.trash.readable {
                Text(store.trash.size.byteString).font(.title3.weight(.semibold)).monospacedDigit()
                Button("Empty Trash") { confirming = true }
                    .disabled(store.trash.count == 0)
            } else {
                Button("Grant Access") { Store.openFullDiskAccessSettings() }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .task { await store.trash.refresh() }
        .confirmationDialog("Permanently erase \(store.trash.count) items in the Trash?", isPresented: $confirming) {
            Button("Empty Trash", role: .destructive) { Task { await store.emptyTrash() } }
        } message: {
            Text("This frees \(store.trash.size.byteString) and can't be undone.")
        }
    }
}

/// Big colorful title strip used at the top of every module.
struct ModuleHeader: View {
    let item: SidebarItem
    let subtitle: String
    var value: Int64? = nil
    var loading = false

    var body: some View {
        HStack(spacing: 16) {
            IconBadge(symbol: item.symbol, color: item.tint, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.rawValue).font(.title2.weight(.bold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if loading {
                ProgressView().controlSize(.small)
            } else if let value {
                Text(value.byteString)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(item.tint.gradient)
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(LinearGradient(colors: [item.tint.opacity(0.16), .clear], startPoint: .leading, endPoint: .trailing))
    }
}

private struct Chip: View {
    let title: String
    let symbol: String
    let color: Color
    let bytes: Int64
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
                if bytes > 0 {
                    Text(bytes.byteString).foregroundStyle(isOn ? .white.opacity(0.85) : .secondary).monospacedDigit()
                }
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isOn ? AnyShapeStyle(color.gradient) : AnyShapeStyle(.quaternary.opacity(0.6)), in: Capsule())
            .foregroundStyle(isOn ? .white : .primary)
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.15), value: isOn)
    }
}

private struct GroupHeader: View {
    @Environment(Store.self) private var store
    let group: TargetGroup
    let targets: [CleanTarget]

    var body: some View {
        let selectable = targets.filter { store.isAvailable($0) }
        let states = selectable.map { store.checkState($0) }
        let allOn = !states.isEmpty && states.allSatisfy { $0 == .on }
        let anyOn = states.contains { $0 != .off }
        let bytes = store.groupBytes(group)
        HStack(spacing: 10) {
            Checkbox(value: allOn ? .on : anyOn ? .mixed : .off) {
                for target in selectable {
                    store.childSelection[target.id] = nil
                    if allOn { store.selected.remove(target.id) } else { store.selected.insert(target.id) }
                }
            }
            IconBadge(symbol: group.symbol, color: group.color, size: 22)
            Text(group.rawValue).font(.headline).foregroundStyle(.primary)
            Text("\(targets.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
            Spacer()
            Text(bytes > 0 ? bytes.byteString : "Clean").font(.headline).monospacedDigit()
                .foregroundStyle(bytes > 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
        }
        .padding(.vertical, 6)
    }
}

struct TargetRow: View {
    @Environment(Store.self) private var store
    let target: CleanTarget
    let largest: Int64
    @State private var expanded = false
    @State private var children: [FolderItem]?

    private var available: Bool { store.isAvailable(target) }
    private var bytes: Int64 { store.sizes[target.id] ?? 0 }
    private var canExpand: Bool { !target.existingURLs.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mainRow
            if expanded {
                expandedContent
                    .padding(.leading, 74)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .opacity(available ? 1 : 0.55)
        .contextMenu { menu }
    }

    private var mainRow: some View {
        HStack(spacing: 12) {
            Checkbox(value: store.checkState(target)) { store.toggle(target) }
                .disabled(!available)
            TargetIcon(target: target, dimmed: !available)
            titleBlock
            Spacer(minLength: 12)
            sizeBlock.frame(minWidth: 110, alignment: .trailing)
            expandButton
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if canExpand { toggleExpanded() } }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(target.name).fontWeight(.medium).lineLimit(1)
                if target.risk == .caution { Tag(text: "Review first", color: .orange) }
                sourceTag
                if let command = target.command { Tag(text: "Runs command", color: .secondary).help(command) }
            }
            Text(target.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    @ViewBuilder
    private var sourceTag: some View {
        switch target.source {
        case .tool(let query): Tag(text: "via \(query)", color: .blue).help("Location reported by `\(query)`")
        case .discovered: Tag(text: "Auto-detected", color: .purple)
        case .builtIn: EmptyView()
        }
    }

    private var sizeBlock: some View {
        VStack(alignment: .trailing, spacing: 5) {
            sizeLabel
            if bytes > 0 {
                SizeBar(fraction: Double(bytes) / Double(largest), color: target.group.color).frame(width: 110)
            }
        }
    }

    @ViewBuilder
    private var sizeLabel: some View {
        if store.scanning.contains(target.id) {
            ProgressView().controlSize(.small)
        } else if target.command != nil && target.reportedSize == nil && target.existingURLs.isEmpty {
            Text("—").foregroundStyle(.tertiary)
        } else if !available {
            Text("Not found").foregroundStyle(.tertiary)
        } else if bytes == 0 {
            Label("Clean", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Text(bytes.byteString).monospacedDigit().fontWeight(bytes > 1_000_000_000 ? .semibold : .regular)
        }
    }

    @ViewBuilder
    private var expandButton: some View {
        if canExpand {
            Button { toggleExpanded() } label: {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Show what's inside")
        } else {
            Color.clear.frame(width: 20, height: 20)
        }
    }

    @ViewBuilder
    private var menu: some View {
        if let url = target.existingURLs.first {
            Button("Browse in Space Lens") { store.browse(url) }
            Button("Reveal in Finder") { NSWorkspace.shared.reveal(target.existingURLs) }
        }
        if let command = target.command {
            Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        if !target.supportsChildren {
            VStack(spacing: 4) {
                ForEach(target.existingURLs, id: \.self) { url in
                    PathRow(url: url, bytes: store.pathSizes[url])
                }
            }
        } else if let children {
            if children.isEmpty {
                Text("Empty").font(.callout).foregroundStyle(.secondary)
            } else {
                ChildList(target: target, children: children)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Measuring…").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func toggleExpanded() {
        withAnimation(.snappy) { expanded.toggle() }
        if expanded && children == nil && target.supportsChildren {
            Task { children = await store.children(of: target) }
        }
    }
}

private struct ChildList: View {
    @Environment(Store.self) private var store
    let target: CleanTarget
    let children: [FolderItem]

    var body: some View {
        let urls = children.map(\.url)
        let maxChild = Double(max(children.first?.size ?? 1, 1))
        VStack(spacing: 2) {
            ForEach(children.prefix(40)) { child in
                ChildRow(item: child, fraction: Double(child.size ?? 0) / maxChild, color: target.group.color,
                         isOn: isOn(child.url)) {
                    store.toggleChild(child.url, of: target, siblings: urls)
                }
            }
            if children.count > 40 {
                Text("+ \(children.count - 40) more. Open in Space Lens to see everything.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
            }
        }
        .padding(6)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func isOn(_ url: URL) -> Bool {
        store.selected.contains(target.id) || store.childSelection[target.id]?.contains(url) == true
    }
}

/// App icon when we know the app, otherwise a colored folder badge.
struct TargetIcon: View {
    let target: CleanTarget
    var dimmed = false

    var body: some View {
        if let app = target.appURL {
            FileIcon(url: app, size: 30).opacity(dimmed ? 0.5 : 1)
        } else {
            IconBadge(symbol: symbol, color: target.group.color.opacity(dimmed ? 0.4 : 1), size: 30)
        }
    }

    private var symbol: String {
        if target.command != nil { return "terminal" }
        return target.mode == .items ? "doc.on.doc.fill" : "folder.fill"
    }
}

private struct ChildRow: View {
    @Environment(Store.self) private var store
    let item: FolderItem
    let fraction: Double
    let color: Color
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Checkbox(value: isOn ? .on : .off, action: toggle)
            FileIcon(url: item.url, size: 18)
            Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle)
            if let modified = item.modified {
                Text(modified.formatted(.relative(presentation: .named)))
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            SizeBar(fraction: fraction, color: color).frame(width: 80)
            Text((item.size ?? 0).byteString).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 72, alignment: .trailing)
            Button { NSWorkspace.shared.reveal([item.url]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Browse in Space Lens") { store.browse(item.url) }
            Button("Reveal in Finder") { NSWorkspace.shared.reveal([item.url]) }
        }
    }
}

private struct PathRow: View {
    let url: URL
    let bytes: Int64?

    var body: some View {
        HStack(spacing: 8) {
            FileIcon(url: url, size: 18)
            Text(url.tildePath).font(.callout).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(bytes?.byteString ?? "…").font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Button { NSWorkspace.shared.reveal([url]) } label: { Image(systemName: "magnifyingglass") }
                .controlSize(.small)
                .help("Reveal in Finder")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
