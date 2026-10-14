import SwiftUI

@main
struct DevSweepApp: App {
    @State private var store = Store()
    @AppStorage("theme") private var themeID = AppTheme.navy.rawValue
    @AppStorage("menuBarMode") private var menuBarMode = "both"
    @AppStorage("showMenuBar") private var showMenuBar = true

    private var theme: AppTheme { AppTheme(rawValue: themeID) ?? .navy }

    init() {
        // Background agent mode: run due scheduled tasks without any UI, then exit.
        if CommandLine.arguments.contains("--run-due-tasks") {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                let lines = await TaskStore.runDue(includeLogin: CommandLine.arguments.contains("--login"))
                for line in lines { print(Date(), line) }
                done.signal()
            }
            done.wait()
            Thread.sleep(forTimeInterval: 1)   // let notifications post
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("DevSweep", id: "main") {
            RootView()
                .environment(store)
                .environment(\.theme, theme)
                .tint(theme.accent)
                .frame(minWidth: 1040, minHeight: 680)
                .onAppear { applyDockIcon() }
                .onChange(of: themeID) { applyDockIcon() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About DevSweep") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(string: "Clean developer caches, system junk, large files and unused apps.\nbrew install --cask moovendhan-v/tap/devsweep\n\nIncludes code adapted from Mac Sai (BSD 3-Clause). See THIRD_PARTY_NOTICES.md in the app bundle."),
                    ])
                }
            }
            CommandGroup(after: .newItem) {
                Button("Smart Scan") { store.section = .smartCare; Task { await store.smartScan() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Memory & Swap") { store.section = .memory }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(store)
                .environment(\.theme, theme)
                .tint(theme.accent)
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarView()
                .environment(store)
                .environment(\.theme, theme)
                .tint(theme.accent)
        } label: {
            MenuBarLabel(title: menuBarTitle, symbol: store.automation.isKeepingAwake ? "cup.and.saucer.fill"
                            : menuBarMode == "network" || menuBarMode == "today" ? "network" : "memorychip")
                .environment(store)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarTitle: String {
        let ram = "\(Int(store.memory.current.usedFraction * 100))%"
        let net = "↓\(store.system.downRate.rateString) ↑\(store.system.upRate.rateString)"
        switch menuBarMode {
        case "ram": return ram
        case "disk": return store.disk.free.byteString
        case "network": return net
        case "today": return "\(store.system.today.total.byteString) today"
        case "cpu": return "CPU \(Int(store.system.cpu * 100))%"
        case "icon": return ""
        default: return "\(ram) · \(store.disk.free.byteString)"
        }
    }

    private func applyDockIcon() {
        NSApp.applicationIconImage = IconRenderer.image(theme: theme, size: 512)
    }
}

/// The menu bar item. Also keeps monitors running and makes sure the main window opens at launch.
private struct MenuBarLabel: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .monospacedDigit()
            .task {
                store.memory.start()
                store.system.start()
                store.automation.start()
                try? await Task.sleep(for: .milliseconds(600))
                if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    store.disk = FileOps.diskSpace()
                    store.system.checkHealth(disk: store.disk, memory: store.memory.current)
                }
            }
    }
}
