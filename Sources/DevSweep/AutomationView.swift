import AppKit
import SwiftUI

struct AutomationView: View {
    @Environment(Store.self) private var store
    @State private var editing: ScheduledTask?
    @State private var message: String?
    @State private var wakeHour = 3
    @State private var wakeMinute = 0
    private var model: AutomationModel { store.automation }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ModuleHeader(item: .automation, subtitle: "Run cleanups on a schedule, in the background, even when DevSweep is closed.")
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                if let message { Text(message).font(.callout).foregroundStyle(message.hasPrefix("✗") ? .red : .green) }
                tasksCard
                HStack(alignment: .top, spacing: 16) {
                    backgroundCard
                    keepAwakeCard
                }
                .fixedSize(horizontal: false, vertical: true)
                sleepExplainer
                if !model.log.isEmpty { logCard }
            }
            .padding(24)
        }
        .navigationTitle("Scheduled Tasks")
        .toolbar {
            Menu {
                ForEach(ScheduledTask.Action.allCases) { action in
                    Button { editing = ScheduledTask(action: action, moveToTrash: action != .emptyTrash, keepAwake: true) } label: {
                        Label(action.rawValue, systemImage: action.symbol)
                    }
                }
            } label: { Label("New Task", systemImage: "plus") }
        }
        .sheet(item: $editing) { task in
            TaskEditor(task: task) { saved in
                if model.tasks.contains(where: { $0.id == saved.id }) {
                    if let i = model.tasks.firstIndex(where: { $0.id == saved.id }) { model.tasks[i] = saved }
                    model.save()
                } else {
                    model.add(saved)
                }
            }
        }
    }

    private var tasksCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Tasks").font(.headline)
                    Spacer()
                    Menu("Add Task") {
                        ForEach(ScheduledTask.Action.allCases) { action in
                            Button(action.rawValue) { editing = ScheduledTask(action: action, moveToTrash: action != .emptyTrash) }
                        }
                    }
                    .fixedSize()
                }
                .padding(.bottom, 8)
                if model.tasks.isEmpty {
                    VStack(spacing: 10) {
                        Text("No tasks yet. Some ideas:").foregroundStyle(.secondary)
                        HStack {
                            suggestion(.cleanDevCaches, "Weekly dev cache cleanup", .weekly)
                            suggestion(.brewCleanup, "Nightly Homebrew cleanup", .daily)
                            suggestion(.networkReport, "Daily data usage report", .daily)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                ForEach(model.tasks) { task in
                    Divider()
                    HStack(spacing: 12) {
                        IconBadge(symbol: task.action.symbol, color: task.enabled ? .indigo : .gray, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(task.title).fontWeight(.medium).lineLimit(1)
                                if task.action.isDestructive && !task.moveToTrash { Tag(text: "Permanent", color: .red) }
                                if task.keepAwake { Image(systemName: "cup.and.saucer.fill").font(.caption2).foregroundStyle(.secondary).help("Keeps the Mac awake while running") }
                            }
                            Text(task.scheduleText + (task.lastRun.map { " · last run \($0.formatted(.relative(presentation: .named)))" } ?? " · never run"))
                                .font(.caption).foregroundStyle(.secondary)
                            if let result = task.lastResult { Text(result).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                        }
                        Spacer()
                        if model.running == task.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Run Now") { Task { await model.runNow(task) } }.controlSize(.small)
                        }
                        Button { editing = task } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                        Toggle("", isOn: Binding(get: { task.enabled }, set: { on in
                            if let i = model.tasks.firstIndex(where: { $0.id == task.id }) { model.tasks[i].enabled = on; model.save() }
                        })).toggleStyle(.switch).controlSize(.small).labelsHidden()
                        Button(role: .destructive) { model.delete(task) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func suggestion(_ action: ScheduledTask.Action, _ title: String, _ every: ScheduledTask.Repeat) -> some View {
        Button {
            model.add(ScheduledTask(action: action, repeatEvery: every, hour: action == .networkReport ? 21 : 3))
        } label: {
            Label(title, systemImage: action.symbol).padding(.horizontal, 10).padding(.vertical, 6)
                .background(.quaternary.opacity(0.6), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var backgroundCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Run when DevSweep is closed", systemImage: "moon.zzz").font(.headline)
                Toggle("Background agent", isOn: Binding(get: { model.agentInstalled }, set: { message = model.setAgent($0) }))
                    .toggleStyle(.switch)
                Text("Installs a small launchd job that checks every 15 minutes and at login. If the Mac was asleep when a task was due, it runs right after waking.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Label("Wake the Mac for tasks", systemImage: "alarm").font(.subheadline.weight(.semibold))
                HStack {
                    Text("Every day at")
                    Picker("", selection: $wakeHour) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) } }.frame(width: 70).labelsHidden()
                    Text(":")
                    Picker("", selection: $wakeMinute) { ForEach([0, 15, 30, 45], id: \.self) { Text(String(format: "%02d", $0)).tag($0) } }.frame(width: 70).labelsHidden()
                    Button("Schedule") {
                        Task { message = await model.scheduleWake(hour: wakeHour, minute: wakeMinute) ? "✓ Your Mac will wake daily at \(String(format: "%02d:%02d", wakeHour, wakeMinute))" : "✗ Not scheduled" }
                    }
                }
                if let schedule = model.wakeSchedule {
                    Text(schedule).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Button("Cancel Wake Schedule") { Task { await model.cancelWake() } }.controlSize(.small)
                }
                Text("Uses macOS's power schedule (asks for your admin password). Works on power or with the lid open.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var keepAwakeCard: some View {
        @Bindable var model = store.automation
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Keep Mac Awake", systemImage: model.isKeepingAwake ? "cup.and.saucer.fill" : "cup.and.saucer").font(.headline)
                if model.isKeepingAwake {
                    Text(model.keepAwakeForever ? "On until you turn it off" :
                            "On until \(model.keepAwakeUntil?.formatted(date: .omitted, time: .shortened) ?? "")")
                        .foregroundStyle(.green)
                    Button("Turn Off") { model.stopKeepAwake() }
                } else {
                    HStack {
                        Button("1 hour") { model.keepAwake(for: 3600) }
                        Button("4 hours") { model.keepAwake(for: 4 * 3600) }
                        Button("Indefinitely") { model.keepAwake(for: nil) }
                    }
                }
                Toggle("Keep the display on too", isOn: $model.keepDisplayOn).toggleStyle(.checkbox)
                Text("Stops idle sleep so long builds, downloads and tasks finish. Closing the lid on battery still sleeps the Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var sleepExplainer: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("While a Mac is asleep, no app can run. DevSweep covers this three ways: tasks keep the Mac awake while they run, the background agent catches up right after wake, and the optional wake schedule wakes the Mac at task time.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var logCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recent runs").font(.headline)
                ForEach(Array(model.log.prefix(10).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption).textSelection(.enabled)
                }
            }
        }
    }
}

private struct TaskEditor: View {
    @State var task: ScheduledTask
    let onSave: (ScheduledTask) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            SwiftUI.Section {
                Picker("Task", selection: $task.action) {
                    ForEach(ScheduledTask.Action.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                }
                if task.action == .custom {
                    TextField("Shell command", text: $task.command, prompt: Text("e.g. npm cache verify"))
                        .font(.body.monospaced())
                }
                if task.action == .staleProjects {
                    HStack {
                        TextField("Projects folder", text: $task.projectFolder, prompt: Text("~/Desktop"))
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            if panel.runModal() == .OK, let url = panel.url { task.projectFolder = url.path }
                        }
                    }
                }
            }
            SwiftUI.Section("When") {
                Picker("Repeat", selection: $task.repeatEvery) {
                    ForEach(ScheduledTask.Repeat.allCases) { Text($0.rawValue).tag($0) }
                }
                if task.repeatEvery == .weekly {
                    Picker("Day", selection: $task.weekday) {
                        ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                    }
                }
                if task.repeatEvery == .daily || task.repeatEvery == .weekly {
                    HStack {
                        Text("Time")
                        Spacer()
                        Picker("", selection: $task.hour) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) } }.frame(width: 70).labelsHidden()
                        Picker("", selection: $task.minute) { ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text(String(format: "%02d", $0)).tag($0) } }.frame(width: 70).labelsHidden()
                    }
                }
            }
            SwiftUI.Section("Options") {
                if ![.networkReport, .diskReport, .custom, .brewCleanup, .dockerPrune, .emptyTrash].contains(task.action) {
                    Toggle("Move to Trash instead of deleting", isOn: $task.moveToTrash)
                }
                Toggle("Keep the Mac awake while it runs", isOn: $task.keepAwake)
                Toggle("Enabled", isOn: $task.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { onSave(task); dismiss() }
                    .disabled(task.action == .custom && task.command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
