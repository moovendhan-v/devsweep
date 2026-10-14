import AppKit
import SwiftUI

extension TargetGroup {
    var color: Color {
        switch self {
        case .apple: .blue
        case .javascript: .yellow
        case .languages: .purple
        case .jvm: .orange
        case .editors: .teal
        case .system: .indigo
        case .appCaches: .green
        case .webCaches: .mint
        case .logs: .brown
        case .downloads: .cyan
        case .mail: .blue
        case .broken: .red
        case .slimming: .purple
        }
    }
}

enum Palette {
    static let projects = Color.pink
    static let otherUsed = Color.gray.opacity(0.45)
    static let free = Color.green
}

/// Rounded, colored tile with an SF Symbol — the visual anchor of every row and card.
struct IconBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: color.opacity(0.25), radius: 2, y: 1)
    }
}

/// Finder's real icon for a file or folder.
struct FileIcon: View {
    let url: URL
    var size: CGFloat = 20

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

struct SizeBar: View {
    let fraction: Double
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color.gradient)
                    .frame(width: fraction > 0 ? max(4, geo.size.width * min(1, fraction)) : 0)
            }
        }
        .frame(height: 6)
        .animation(.smooth, value: fraction)
    }
}

struct Tag: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Round checkbox with an indeterminate state, used for folder trees.
struct Checkbox: View {
    enum Value { case on, off, mixed }

    let value: Value
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: value == .on ? "checkmark.circle.fill" : value == .mixed ? "minus.circle.fill" : "circle")
            .font(.system(size: 17))
            .foregroundStyle(value == .off ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
            .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
    }
}

/// White rounded panel used on the dashboard.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6)))
            .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}

/// Bottom action bar shared by every cleaning screen.
struct CleanBar<Leading: View>: View {
    @Environment(Store.self) private var store
    let title: String
    let disabled: Bool
    @ViewBuilder var leading: Leading
    let action: () -> Void

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 14) {
            leading
            Spacer()
            Toggle("Move to Trash", isOn: $store.moveToTrash)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Off = delete permanently. Frees space immediately but cannot be undone.")
            Button(action: action) {
                HStack(spacing: 6) {
                    if store.isCleaning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(title).monospacedDigit()
                }
                .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(disabled || store.isCleaning)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

extension NSWorkspace {
    func reveal(_ urls: [URL]) { activateFileViewerSelecting(urls) }
}
