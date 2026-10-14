import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }
            MemorySettings().tabItem { Label("Memory", systemImage: "memorychip") }
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 560)
    }
}

private struct AppearanceSettings: View {
    @AppStorage("theme") private var themeID = AppTheme.navy.rawValue
    @AppStorage("menuBarMode") private var menuBarMode = "both"
    @AppStorage("showMenuBar") private var showMenuBar = true

    var body: some View {
        Form {
            SwiftUI.Section("Theme") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(AppTheme.allCases) { theme in
                        ThemeSwatch(theme: theme, selected: themeID == theme.rawValue) { themeID = theme.rawValue }
                    }
                }
                .padding(.vertical, 4)
                Text("Changes Smart Care, buttons, charts and the Dock icon right away.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Menu bar") {
                Toggle("Show DevSweep in the menu bar", isOn: $showMenuBar)
                Picker("Show", selection: $menuBarMode) {
                    Text("RAM usage and free disk").tag("both")
                    Text("RAM usage").tag("ram")
                    Text("CPU usage").tag("cpu")
                    Text("Network speed (↓ ↑)").tag("network")
                    Text("Data used today").tag("today")
                    Text("Free disk space").tag("disk")
                    Text("Icon only").tag("icon")
                }
                .disabled(!showMenuBar)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ThemeSwatch: View {
    let theme: AppTheme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.hero)
                    Image(nsImage: IconRenderer.image(theme: theme, size: 64)).resizable().frame(width: 46, height: 46)
                    Capsule().fill(theme.button).frame(width: 60, height: 8).offset(y: 30)
                }
                .frame(height: 86)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? theme.accent : .clear, lineWidth: 3))
                HStack(spacing: 4) {
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accent) }
                    Text(theme.name).fontWeight(selected ? .semibold : .regular)
                    if theme == .navy { Text("Default").font(.caption2).foregroundStyle(.secondary) }
                }
                .font(.callout)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MemorySettings: View {
    @Environment(Store.self) private var store
    @AppStorage("memoryInterval") private var interval = 2.0
    @AppStorage("memoryAlerts") private var alerts = false

    var body: some View {
        Form {
            SwiftUI.Section("Tracking") {
                Picker("Sample memory every", selection: $interval) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                }
                .onChange(of: interval) { store.memory.restart() }
                Text("DevSweep keeps 30 minutes of history while it's running. Sampling is very light (one system call).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Alerts") {
                Toggle("Notify me when memory pressure rises", isOn: $alerts)
                    .onChange(of: alerts) { if alerts { MemoryMonitor.requestAlertPermission() } }
                Text("At most one notification every 10 minutes, naming the app using the most memory.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct GeneralSettings: View {
    @Environment(Store.self) private var store
    @AppStorage("moveToTrashDefault") private var moveToTrash = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("healthAlerts") private var healthAlerts = false
    @State private var excluded = ExcludedFolders.paths
    @State private var loginError: String?

    var body: some View {
        Form {
            SwiftUI.Section("Cleaning") {
                Toggle("Move cleaned items to the Trash (safer)", isOn: $moveToTrash)
                    .onChange(of: moveToTrash) { store.moveToTrash = moveToTrash }
                Text("When off, items are deleted permanently and space is freed immediately.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Startup") {
                Toggle("Open DevSweep at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { setLaunchAtLogin(launchAtLogin) }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
            SwiftUI.Section("Health alerts") {
                Toggle("Notify me when disk space is low, memory is critical or the battery is worn", isOn: $healthAlerts)
                    .onChange(of: healthAlerts) { if healthAlerts { MemoryMonitor.requestAlertPermission() } }
            }
            SwiftUI.Section("Excluded folders") {
                ForEach(excluded, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder.badge.minus")
                        Text((path as NSString).abbreviatingWithTildeInPath)
                        Spacer()
                        Button { excluded.removeAll { $0 == path }; ExcludedFolders.paths = excluded } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = true
                    if panel.runModal() == .OK {
                        excluded = Array(Set(excluded + panel.urls.map { SafetyGuard.canonical($0.path) })).sorted()
                        ExcludedFolders.paths = excluded
                    }
                }
                Text("DevSweep never deletes anything inside these folders.").font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Welcome guide") {
                Button("Show Welcome Guide Again") { UserDefaults.standard.set(0, forKey: "onboardingVersion") }
            }
            SwiftUI.Section("Permissions") {
                LabeledContent("Full Disk Access") {
                    Text(store.hasFullDiskAccess ? "Granted" : "Not granted")
                        .foregroundStyle(store.hasFullDiskAccess ? .green : .orange)
                }
                Button("Open Privacy & Security Settings") { Store.openFullDiskAccessSettings() }
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change this: \(error.localizedDescription). Add DevSweep in System Settings › General › Login Items instead."
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
