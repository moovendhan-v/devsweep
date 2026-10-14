import AppKit
import SwiftUI

// MARK: - Updater

struct UpdaterView: View {
    @Environment(Store.self) private var store
    @State private var message: String?
    private var model: UpdaterModel { store.updater }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(item: .updater, subtitle: "Checks Homebrew casks and each app's own update feed. Only version info is downloaded; nothing about you is sent.",
                         value: nil, loading: model.isChecking)
            if let message { Text(message).font(.callout).padding(8).frame(maxWidth: .infinity).background(.quaternary.opacity(0.4)) }
            if model.isChecking {
                ScanningPlaceholder(text: model.status)
            } else if model.lastCheck == nil {
                StartPanel(item: .updater, title: "See which apps have updates",
                           detail: "Homebrew-installed apps update with one click. Other apps open their download or their own updater.",
                           button: "Check for Updates") { Task { await model.check() } }
            } else if model.updates.isEmpty {
                ContentUnavailableView("Everything is up to date", systemImage: "checkmark.seal.fill",
                                       description: Text("Checked \(model.checkedApps) update feeds and your Homebrew casks."))
            } else {
                List {
                    ForEach([AppUpdate.Source.homebrew, .sparkle, .appStore], id: \.self) { source in
                        let items = model.updates.filter { $0.source == source }
                        if !items.isEmpty {
                            SwiftUI.Section("\(source.rawValue) · \(items.count)") {
                                ForEach(items) { update in row(update) }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Updater")
        .toolbar {
            if model.updates.contains(where: { $0.source == .homebrew }) {
                Button("Update All Casks") {
                    Task {
                        for update in model.updates where update.source == .homebrew { message = await model.install(update) }
                    }
                }
                .disabled(model.updatingCask != nil)
            }
            Button { Task { await model.check() } } label: { Label("Check Again", systemImage: "arrow.clockwise") }.disabled(model.isChecking)
        }
    }

    private func row(_ update: AppUpdate) -> some View {
        HStack(spacing: 10) {
            if let url = update.appURL ?? appURL(forCask: update.caskToken) { FileIcon(url: url, size: 28) } else { Image(systemName: "shippingbox").frame(width: 28) }
            VStack(alignment: .leading, spacing: 2) {
                Text(update.name).fontWeight(.medium)
                Text("\(update.current) → \(update.available)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            if model.updatingCask == update.caskToken && update.caskToken != nil {
                ProgressView().controlSize(.small)
            } else {
                Button(update.source == .homebrew ? "Update" : "Get Update") { Task { message = await model.install(update) } }
                    .controlSize(.small)
                    .disabled(model.updatingCask != nil)
            }
        }
        .padding(.vertical, 3)
    }

    private func appURL(forCask token: String?) -> URL? {
        guard let token else { return nil }
        return store.apps.apps.first { $0.name.lowercased().replacingOccurrences(of: " ", with: "-") == token }?.url
    }
}

// MARK: - Extensions

struct ExtensionsView: View {
    @Environment(Store.self) private var store
    private var model: ExtensionsModel { store.extensions }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(item: .extensions, subtitle: "Preference panes, plug-ins, Quick Look and Spotlight importers, and app extensions added by third-party apps.",
                         value: nil, loading: model.isLoading)
            List {
                ForEach(ManagedExtension.Kind.allCases, id: \.self) { kind in
                    let items = model.items.filter { $0.kind == kind }
                    if !items.isEmpty {
                        SwiftUI.Section {
                            ForEach(items) { item in
                                HStack(spacing: 10) {
                                    FileIcon(url: item.url, size: 24)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.name).fontWeight(.medium)
                                        Text(item.bundleID.isEmpty ? item.url.tildePath : item.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if let enabled = item.enabled {
                                        Toggle("", isOn: Binding(get: { enabled }, set: { on in Task { await model.setEnabled(item, on) } }))
                                            .toggleStyle(.switch).controlSize(.small).labelsHidden()
                                    }
                                    Button { NSWorkspace.shared.reveal([item.url]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                                    if item.canTrash {
                                        Button("Remove") { Task { await store.trashFiles([item.url], label: "Extension"); await model.load() } }.controlSize(.small)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        } header: {
                            Label("\(kind.rawValue) · \(items.count)", systemImage: kind.symbol)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .overlay { if model.items.isEmpty && !model.isLoading { ContentUnavailableView("No third-party extensions", systemImage: "puzzlepiece.extension") } }
        }
        .navigationTitle("Extensions")
        .toolbar { Button { Task { await model.load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") } }
        .task { if model.items.isEmpty { await model.load() } }
    }
}

// MARK: - Default apps

struct DefaultAppsView: View {
    @Environment(Store.self) private var store
    @State private var search = ""
    @State private var message: String?
    private var model: DefaultAppsModel { store.defaultApps }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(item: .defaultApps, subtitle: "Custom “Open with” choices for file types and links. Remove a rule to go back to macOS's default; a backup is kept.",
                         value: nil)
            if let message { Text(message).font(.callout).padding(8).frame(maxWidth: .infinity).background(.quaternary.opacity(0.4)) }
            List {
                ForEach(model.handlers.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || ($0.bundleID ?? "").localizedCaseInsensitiveContains(search) }) { handler in
                    HStack(spacing: 10) {
                        Image(systemName: handler.urlScheme != nil ? "link" : "doc").frame(width: 22).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(handler.title).fontWeight(.medium)
                            Text(handler.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let app = handler.appURL {
                            FileIcon(url: app, size: 20)
                            Text(app.deletingPathExtension().lastPathComponent).foregroundStyle(.secondary)
                        } else {
                            Text(handler.bundleID ?? "?").font(.caption).foregroundStyle(.orange)
                            Tag(text: "App missing", color: .orange)
                        }
                        Button("Reset") { message = model.remove(handler) }.controlSize(.small)
                    }
                }
            }
            .listStyle(.inset)
        }
        .navigationTitle("Default Apps")
        .searchable(text: $search, placement: .toolbar, prompt: "File type, link or app")
        .toolbar {
            Menu("Restore Backup") {
                ForEach(model.backups.prefix(10), id: \.self) { backup in
                    Button(backup.deletingPathExtension().lastPathComponent) { message = model.restore(backup) }
                }
                if model.backups.isEmpty { Text("No backups yet") }
            }
        }
        .onAppear { model.load() }
    }
}
