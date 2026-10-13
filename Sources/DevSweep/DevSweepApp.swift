import SwiftUI

@main
struct DevSweepApp: App {
    @State private var store = Store()

    var body: some Scene {
        WindowGroup("DevSweep", id: "main") {
            RootView()
                .environment(store)
                .frame(minWidth: 1040, minHeight: 680)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About DevSweep") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(string: "Clean developer caches, system junk, large files and unused apps.\nbrew install --cask devsweep"),
                    ])
                }
            }
            CommandGroup(after: .newItem) {
                Button("Smart Scan") { store.section = .smartCare; Task { await store.smartScan() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView().environment(store)
        } label: {
            Label(store.disk.free.byteString, systemImage: "sparkles")
        }
        .menuBarExtraStyle(.window)
    }
}
