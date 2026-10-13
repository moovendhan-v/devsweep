import AppKit
import SwiftUI

struct ActivityView: View {
    @Environment(Store.self) private var store

    var body: some View {
        Group {
            if store.log.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "clock",
                                       description: Text("Everything DevSweep removes is listed here."))
            } else {
                List(Array(store.log.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 10) {
                        Image(systemName: icon(for: line)).foregroundStyle(color(for: line)).frame(width: 18)
                        Text(line.drop { "✓✗⚠︎— ".contains($0) })
                            .font(line.hasPrefix("—") ? .callout.weight(.semibold) : .callout)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            Button("Open Trash", systemImage: "trash") {
                NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
            }
            .help("Empty the Trash to actually free the space")
        }
    }

    private func icon(for line: String) -> String {
        switch line.first {
        case "✓": "checkmark.circle.fill"
        case "✗": "xmark.octagon.fill"
        case "⚠": "exclamationmark.triangle.fill"
        default: "clock"
        }
    }

    private func color(for line: String) -> Color {
        switch line.first {
        case "✓": .green
        case "✗": .red
        case "⚠": .orange
        default: .secondary
        }
    }
}
