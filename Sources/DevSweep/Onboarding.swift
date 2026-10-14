import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

/// First-launch guide: what DevSweep does, Full Disk Access, background activity, notifications.
struct OnboardingView: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @AppStorage("onboardingVersion") private var onboardingVersion = 0
    @AppStorage("showMenuBar") private var showMenuBar = true
    @State private var page: Int

    init(startPage: Int = 0) { _page = State(initialValue: startPage) }
    @State private var fullDiskAccess = Store.checkFullDiskAccess()
    @State private var backgroundOn = BackgroundAgent.isInstalled
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var notifications: UNAuthorizationStatus = .notDetermined
    @State private var agentNote: String?

    private let pages = 5

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { finish() } label: { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Skip")
            }
            .padding([.top, .horizontal], 16)

            Group {
                switch page {
                case 0: welcome
                case 1: features
                case 2: diskAccess
                case 3: background
                default: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))

            HStack {
                Button("Back") { withAnimation(.snappy) { page -= 1 } }.opacity(page == 0 ? 0 : 1).disabled(page == 0)
                Spacer()
                HStack(spacing: 7) {
                    ForEach(0..<pages, id: \.self) { i in
                        Circle().fill(i == page ? theme.accent : Color.secondary.opacity(0.35)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                Button(page == pages - 1 ? "Get Started" : "Next") {
                    if page == pages - 1 { finish(scan: true) } else { withAnimation(.snappy) { page += 1 } }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 720, height: 560)
        .task {
            // Re-check permissions while the guide is open (the user flips them in System Settings).
            while !Task.isCancelled {
                fullDiskAccess = Store.checkFullDiskAccess()
                notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                backgroundOn = BackgroundAgent.isInstalled
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 128, height: 128)
                .shadow(color: theme.accent.opacity(0.4), radius: 24)
            Text("Welcome to DevSweep").font(.system(size: 32, weight: .bold, design: .rounded))
            Text("A Mac cleaner built for developers: caches, junk, memory, network and background cleanups, all in one place. Nothing leaves your Mac.")
                .font(.title3).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 520)
        }
    }

    private var features: some View {
        VStack(spacing: 22) {
            Text("What DevSweep Can Do").font(.system(size: 26, weight: .bold, design: .rounded))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                feature(.caches, "Developer Caches", "npm, Xcode, Docker, pip and 100+ tools, found automatically")
                feature(.junk, "System Junk", "App caches, logs, leftovers and old installers")
                feature(.malware, "Protection", "Adware scan, privacy cleanup, browser extensions")
                feature(.memory, "Memory & Swap", "Live RAM, swap and one-click Speed Up")
                feature(.network, "Network", "Live speed and daily data usage in the menu bar")
                feature(.automation, "Scheduled Tasks", "Cleanups that run in the background")
                feature(.apps, "Applications", "Uninstaller, updater, extensions, default apps")
                feature(.explorer, "Files", "Space Lens, large files, duplicates, shredder")
            }
        }
    }

    private func feature(_ item: SidebarItem, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            IconBadge(symbol: item.symbol, color: item == .smartCare ? theme.accent : item.tint, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private var diskAccess: some View {
        VStack(spacing: 18) {
            Image(systemName: fullDiskAccess ? "checkmark.shield.fill" : "lock.shield.fill")
                .font(.system(size: 56)).foregroundStyle(fullDiskAccess ? .green : theme.accent)
                .contentTransition(.symbolEffect(.replace))
            Text("Full Disk Access").font(.system(size: 26, weight: .bold, design: .rounded))
            Text("DevSweep needs Full Disk Access to measure the Trash and to scan Safari, Mail and other protected areas. Without it, some features are limited.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 520)
            if fullDiskAccess {
                Label("Full Disk Access is on", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    step(1, "Open System Settings")
                    step(2, "Go to Privacy & Security › Full Disk Access")
                    step(3, "Turn on DevSweep (or click + and add it)")
                    step(4, "Come back here. This page updates by itself.")
                }
                .padding(16)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                HStack {
                    Button("Open System Settings") { Store.openFullDiskAccessSettings() }.buttonStyle(.borderedProminent)
                    Button("Show DevSweep in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                        .help("Drag DevSweep from Finder into the Full Disk Access list")
                }
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text("\(number)").font(.callout.weight(.bold)).foregroundStyle(.white)
                .frame(width: 24, height: 24).background(theme.accent, in: Circle())
            Text(text)
        }
    }

    private var background: some View {
        VStack(spacing: 16) {
            Image(systemName: "moon.stars.fill").font(.system(size: 50)).foregroundStyle(theme.accent)
            Text("Run in the Background").font(.system(size: 26, weight: .bold, design: .rounded))
            Text("Let DevSweep run scheduled cleanups and track network usage even when its window is closed. macOS will show an “App Background Activity” notice; you can change this anytime in System Settings › General › Login Items & Extensions.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 560)
            VStack(spacing: 0) {
                permissionRow("Background tasks", "Runs scheduled tasks every 15 minutes and after wake", "calendar.badge.clock",
                              isOn: Binding(get: { backgroundOn }, set: { on in
                                  agentNote = store.automation.setAgent(on)
                                  backgroundOn = BackgroundAgent.isInstalled
                              }))
                Divider()
                permissionRow("Open at login", "Keeps the menu bar stats and network history running", "power",
                              isOn: Binding(get: { launchAtLogin }, set: { on in
                                  try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                                  launchAtLogin = SMAppService.mainApp.status == .enabled
                              }))
                Divider()
                permissionRow("Menu bar stats", "CPU, memory, network speed and today's data", "menubar.rectangle", isOn: $showMenuBar)
                Divider()
                HStack(spacing: 12) {
                    Image(systemName: "bell.badge").frame(width: 26).foregroundStyle(theme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Notifications").fontWeight(.medium)
                        Text("Task results, low disk and memory alerts").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    switch notifications {
                    case .authorized, .provisional: Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .denied:
                        Button("Open Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) }
                    default:
                        Button("Allow") {
                            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                            UserDefaults.standard.set(true, forKey: "healthAlerts")
                        }
                    }
                }
                .padding(.vertical, 10)
            }
            .padding(.horizontal, 16)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            if let agentNote { Text(agentNote).font(.caption).foregroundStyle(agentNote.hasPrefix("✗") ? .red : .secondary) }
        }
    }

    private func permissionRow(_ title: String, _ detail: String, _ symbol: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 26).foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden()
        }
        .padding(.vertical, 10)
    }

    private var done: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles").font(.system(size: 56)).foregroundStyle(theme.accent)
            Text("You're All Set").font(.system(size: 30, weight: .bold, design: .rounded))
            VStack(alignment: .leading, spacing: 8) {
                status(fullDiskAccess, "Full Disk Access", fullDiskAccess ? "On" : "Off. Some scans are limited.")
                status(backgroundOn, "Background tasks", backgroundOn ? "On" : "Off")
                status(launchAtLogin, "Open at login", launchAtLogin ? "On" : "Off")
                status(notifications == .authorized, "Notifications", notifications == .authorized ? "On" : "Off")
            }
            .padding(16)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            Text("Start with a Smart Care scan to see what you can clean.").foregroundStyle(.secondary)
        }
    }

    private func status(_ on: Bool, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(on ? .green : .secondary)
            Text(title).fontWeight(.medium).frame(width: 150, alignment: .leading)
            Text(detail).foregroundStyle(.secondary)
        }
    }

    private func finish(scan: Bool = false) {
        onboardingVersion = 1
        store.hasFullDiskAccess = Store.checkFullDiskAccess()
        dismiss()
        if scan {
            store.section = .smartCare
            Task { await store.smartScan() }
        }
    }
}
