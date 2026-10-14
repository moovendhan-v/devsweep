import SwiftUI

/// One-click 360° checkup: scan everything, show a checklist, run the safe parts.
struct SmartCareView: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @State private var includeTrash = false
    @State private var includeProjects = true
    @State private var lastRunMessage: String?
    @State private var pulse = false

    private var isScanning: Bool { store.smartStage != nil }
    private var safeBytes: Int64 { store.safeTargets.reduce(0) { $0 + (store.sizes[$1.id] ?? 0) } }
    private var recommendedBytes: Int64 {
        safeBytes + (includeProjects ? store.selectedJunkBytes : 0) + (includeTrash ? store.trash.size : 0)
    }

    var body: some View {
        ZStack {
            background
            ScrollView {
                VStack(spacing: 26) {
                    if !store.hasFullDiskAccess { accessBanner }
                    if isScanning {
                        scanningView
                    } else if store.smartDone {
                        resultsView
                    } else {
                        idleView
                    }
                }
                .padding(32)
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(.white)
        .navigationTitle("Smart Care")
        .toolbarBackground(.hidden, for: .windowToolbar)
    }

    private var background: some View {
        ZStack {
            theme.hero
            Circle().fill(theme.accent.opacity(0.30)).frame(width: 520).blur(radius: 120).offset(x: 260, y: -220)
            Circle().fill(theme.accent2.opacity(0.35)).frame(width: 460).blur(radius: 110).offset(x: -300, y: 260)
        }
        .ignoresSafeArea()
    }

    // MARK: States

    private var idleView: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 30)
            Text(lastRunMessage == nil ? "Let's give your Mac a checkup" : "All done!")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text(lastRunMessage ?? "Smart Care scans system junk, developer caches, project folders, large files, apps and memory in one go, then gives you a checklist.")
                .font(.title3).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.8)).frame(maxWidth: 560)

            Button { Task { await store.smartScan() } } label: {
                ZStack {
                    Circle().fill(.white.opacity(0.12)).frame(width: 210, height: 210)
                        .scaleEffect(pulse ? 1.08 : 0.96)
                    Circle()
                        .fill(LinearGradient(colors: [theme.accent, theme.accent2], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 168, height: 168)
                        .shadow(color: theme.accent.opacity(0.6), radius: 30)
                    VStack(spacing: 4) {
                        Image(systemName: "sparkles").font(.system(size: 30, weight: .semibold))
                        Text("Scan").font(.system(size: 26, weight: .bold, design: .rounded))
                    }
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])
            .padding(.vertical, 12)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true }
            }

            HStack(spacing: 28) {
                stat("internaldrive", "\(store.disk.free.byteString) free", "of \(store.disk.total.byteString)")
                if let last = store.lastScan {
                    stat("clock", "Last scan", last.formatted(.relative(presentation: .named)))
                }
                stat("memorychip", "\(Int(store.memory.current.usedFraction * 100))% memory used",
                     "\(store.memory.current.swapUsed.byteString) swap · pressure \(store.memory.current.pressure.label.lowercased())")
            }
            .padding(.top, 6)
        }
        .onAppear { store.memory.start() }
    }

    private var scanningView: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 40)
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: max(0.03, store.smartProgress))
                    .stroke(AngularGradient(colors: [theme.accent, theme.accent2, theme.accent], center: .center),
                            style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.6), value: store.smartProgress)
                VStack(spacing: 2) {
                    Text("\(Int(store.smartProgress * 100))%").font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit().contentTransition(.numericText())
                    Text("Scanning").foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: 210, height: 210)

            Text(store.smartStage ?? "").font(.title3).foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)

            HStack(spacing: 18) {
                stageIcon(.junk, done: store.smartProgress >= 0.35)
                stageIcon(.caches, done: store.smartProgress >= 0.35)
                stageIcon(.projects, done: store.smartProgress >= 0.6)
                stageIcon(.largeFiles, done: store.smartProgress >= 0.85)
                stageIcon(.malware, done: store.smartProgress >= 0.9)
                stageIcon(.memory, done: store.smartProgress >= 0.9)
                stageIcon(.apps, done: store.smartProgress >= 1)
            }
        }
    }

    private var resultsView: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Text("Here's your checklist").font(.system(size: 30, weight: .bold, design: .rounded))
                Text("We found \(store.reclaimable.byteString) you could reclaim. Review anything, or run the safe items now.")
                    .foregroundStyle(.white.opacity(0.8))
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 16)], spacing: 16) {
                ResultCard(item: .junk, value: store.junkTotal.byteString,
                           detail: "\(store.safeTargets(in: TargetGroup.junk).count) safe app & browser caches") { store.section = .junk }
                ResultCard(item: .malware, value: store.malware.threats.isEmpty ? "No threats" : "\(store.malware.threats.count) found",
                           detail: "\(store.malware.scannedCount) items checked") { store.section = .malware }
                ResultCard(item: .caches, value: store.cacheTotal.byteString,
                           detail: "\(store.devTargets.filter { (store.sizes[$0.id] ?? 0) > 0 }.count) tool caches found") { store.section = .caches }
                ResultCard(item: .projects, value: store.projectTotal.byteString,
                           detail: store.projectRoot == nil ? "Pick a code folder to scan"
                               : "\(store.projectJunk.filter(\.isStale).count) untouched for 30+ days") { store.section = .projects }
                ResultCard(item: .largeFiles, value: store.largeFiles.total.byteString,
                           detail: "\(store.largeFiles.files.count) files over 50 MB") { store.section = .largeFiles }
                ResultCard(item: .apps, value: "\(store.apps.unused.count) unused",
                           detail: "\(store.apps.apps.count) apps · \(store.apps.orphanBytes.byteString) of leftovers") { store.section = .apps }
                ResultCard(item: .memory, value: "\(Int(store.memory.current.usedFraction * 100))% RAM",
                           detail: "\(store.memory.current.swapUsed.byteString) swap · pressure \(store.memory.current.pressure.label.lowercased())") { store.section = .memory }
            }

            VStack(spacing: 14) {
                HStack(spacing: 24) {
                    Toggle("Safe caches (\(safeBytes.byteString))", isOn: .constant(true)).disabled(true)
                    Toggle("Stale project folders (\(store.selectedJunkBytes.byteString))", isOn: $includeProjects)
                        .disabled(store.selectedJunk.isEmpty)
                    Toggle("Empty Trash (\(store.trash.size.byteString))", isOn: $includeTrash)
                        .disabled(store.trash.size == 0)
                }
                .toggleStyle(.checkbox)
                .foregroundStyle(.white)

                HStack(spacing: 14) {
                    Button {
                        Task {
                            let before = store.disk.free
                            await store.runSmartCare(includeTrash: includeTrash, includeProjects: includeProjects)
                            let freed = max(0, store.disk.free - before)
                            lastRunMessage = store.moveToTrash && !includeTrash
                                ? "Cleaned items were moved to the Trash. Empty it to get the space back."
                                : "You got back about \(freed.byteString)."
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if store.isCleaning { ProgressView().controlSize(.small).tint(.white) }
                            Text("Run · \(recommendedBytes.byteString)").font(.title3.weight(.bold))
                        }
                        .padding(.horizontal, 34).padding(.vertical, 14)
                        .background(theme.button, in: Capsule())
                        .shadow(color: theme.accent.opacity(0.5), radius: 16)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isCleaning || recommendedBytes == 0)

                    Button("Scan Again") { Task { await store.smartScan() } }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.white.opacity(0.15), in: Capsule())
                }
                Text(store.moveToTrash ? "Items go to the Trash first, so you can put them back."
                                       : "Items are deleted permanently.")
                    .font(.caption).foregroundStyle(.white.opacity(0.65))
            }
            .padding(.top, 6)
        }
    }

    private var accessBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill").font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Allow Full Disk Access for a complete scan").fontWeight(.semibold)
                Text("Without it, macOS hides the Trash, Mail and some app caches from DevSweep.")
                    .font(.callout).foregroundStyle(.white.opacity(0.8))
            }
            Spacer()
            Button("Open Settings") { Store.openFullDiskAccessSettings() }
            Button("Recheck") { store.hasFullDiskAccess = Store.checkFullDiskAccess() }
                .buttonStyle(.link).foregroundStyle(.white)
        }
        .padding(14)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Helpers

    private func stat(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.white.opacity(0.8))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.semibold).monospacedDigit()
                Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.65))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private func stageIcon(_ item: SidebarItem, done: Bool) -> some View {
        VStack(spacing: 6) {
            IconBadge(symbol: item.symbol, color: done ? item.tint : .white.opacity(0.25), size: 40)
                .overlay(alignment: .bottomTrailing) {
                    if done {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green)
                            .font(.system(size: 15)).offset(x: 4, y: 4)
                    }
                }
            Text(item.rawValue).font(.caption2).foregroundStyle(.white.opacity(done ? 0.95 : 0.55))
        }
        .animation(.spring, value: done)
    }
}

private struct ResultCard: View {
    let item: SidebarItem
    let value: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                IconBadge(symbol: item.symbol, color: item.tint, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.rawValue).font(.callout).foregroundStyle(.white.opacity(0.75))
                    Text(value).font(.title2.weight(.bold)).monospacedDigit()
                    Text(detail).font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
                Spacer()
                Text("Review").font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.white.opacity(hovering ? 0.3 : 0.16), in: Capsule())
            }
            .padding(16)
            .background(.white.opacity(hovering ? 0.16 : 0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.14)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
    }
}
