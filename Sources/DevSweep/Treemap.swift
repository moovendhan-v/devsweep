import AppKit
import SwiftUI

/// Squarified treemap of the current Space Lens folder: area = size.
struct TreemapView: View {
    let explorer: Explorer
    let hint: (URL) -> String?
    let open: (URL) -> Void
    @Environment(Store.self) private var store
    @State private var hovered: URL?

    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .mint, .cyan, .yellow, .red]

    var body: some View {
        let items = Array(explorer.items.filter { ($0.size ?? 0) > 0 }.prefix(80))
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size).insetBy(dx: 8, dy: 8)
            let rects = Self.layout(items.map { Double($0.size ?? 0) }, in: bounds)
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    tile(item, color: color(for: item, index: index), rect: rects[index])
                }
            }
        }
        .overlay {
            if items.isEmpty {
                if explorer.isMeasuring {
                    ProgressView("Measuring folders…")
                } else {
                    ContentUnavailableView("Empty folder", systemImage: "folder")
                }
            }
        }
        .animation(.smooth(duration: 0.35), value: items.map(\.size))
    }

    private func color(for item: FolderItem, index: Int) -> Color {
        if hint(item.url) != nil { return .green }
        if !item.isDirectory { return .gray }
        return Self.palette[index % Self.palette.count]
    }

    @ViewBuilder
    private func tile(_ item: FolderItem, color: Color, rect: CGRect) -> some View {
        let isHovered = hovered == item.url
        let roomy = rect.width > 70 && rect.height > 38
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(color.gradient.opacity(isHovered ? 0.95 : 0.75))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(isHovered ? 0.8 : 0.15), lineWidth: isHovered ? 2 : 1))
            .overlay(alignment: .topLeading) {
                if roomy {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if item.canOpen { Image(systemName: "folder.fill").font(.caption2) }
                            Text(item.name).font(.system(size: rect.width > 160 ? 13 : 11, weight: .semibold)).lineLimit(1)
                        }
                        Text((item.size ?? 0).byteString).font(.system(size: 11)).monospacedDigit().opacity(0.85)
                    }
                    .foregroundStyle(.white)
                    .padding(7)
                }
            }
            .frame(width: max(rect.width - 3, 1), height: max(rect.height - 3, 1))
            .offset(x: rect.minX + 1.5, y: rect.minY + 1.5)
            .onHover { hovered = $0 ? item.url : (hovered == item.url ? nil : hovered) }
            .onTapGesture { if item.canOpen { open(item.url) } else { NSWorkspace.shared.reveal([item.url]) } }
            .help("\(item.name) · \((item.size ?? 0).byteString)")
            .contextMenu {
                if item.canOpen { Button("Open") { open(item.url) } }
                Button("Reveal in Finder") { NSWorkspace.shared.reveal([item.url]) }
                Divider()
                Button("Select for Removal") { explorer.selection = [item.url] }
            }
    }

    /// Squarified treemap (Bruls, Huizing & van Wijk). Values must be sorted descending.
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: values.count)
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var remaining = rect
        var index = 0

        while index < areas.count {
            let short = Double(min(remaining.width, remaining.height))
            func worst(_ sum: Double, _ minArea: Double, _ maxArea: Double) -> Double {
                let s2 = short * short
                return max(s2 * maxArea / (sum * sum), (sum * sum) / (s2 * max(minArea, 0.0001)))
            }
            var rowEnd = index + 1
            var sum = areas[index], minArea = areas[index], maxArea = areas[index]
            while rowEnd < areas.count {
                let area = areas[rowEnd]
                if worst(sum + area, min(minArea, area), max(maxArea, area)) <= worst(sum, minArea, maxArea) {
                    sum += area; minArea = min(minArea, area); maxArea = max(maxArea, area); rowEnd += 1
                } else { break }
            }
            let thickness = CGFloat(sum / short)
            let vertical = remaining.width >= remaining.height
            var offset: CGFloat = 0
            for k in index..<rowEnd {
                let length = CGFloat(areas[k]) / thickness
                result[k] = vertical
                    ? CGRect(x: remaining.minX, y: remaining.minY + offset, width: thickness, height: length)
                    : CGRect(x: remaining.minX + offset, y: remaining.minY, width: length, height: thickness)
                offset += length
            }
            remaining = vertical
                ? CGRect(x: remaining.minX + thickness, y: remaining.minY, width: remaining.width - thickness, height: remaining.height)
                : CGRect(x: remaining.minX, y: remaining.minY + thickness, width: remaining.width, height: remaining.height - thickness)
            index = rowEnd
        }
        return result
    }
}
