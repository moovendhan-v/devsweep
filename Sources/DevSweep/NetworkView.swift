import Charts
import SwiftUI

struct NetworkView: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @State private var range = 30
    @State private var confirmReset = false
    private var monitor: SystemMonitor { store.system }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                HStack(alignment: .top, spacing: 16) {
                    liveCard
                    todayCard
                }
                .fixedSize(horizontal: false, vertical: true)
                historyCard
                appsCard
                Text("DevSweep counts traffic while it's running (including from the menu bar). Usage while it's quit isn't recorded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .navigationTitle("Network")
        .toolbar {
            Button("Reset History…") { confirmReset = true }
        }
        .confirmationDialog("Delete all recorded network history?", isPresented: $confirmReset) {
            Button("Delete History", role: .destructive) { monitor.resetHistory() }
        }
        .onAppear { monitor.refreshAppTraffic() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            IconBadge(symbol: "network", color: .teal, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("Network").font(.title2.weight(.bold))
                Text("Live speed, daily usage and which apps use the most data. Interface: \(monitor.interfaceName)")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 22) {
                rate("arrow.down", monitor.downRate, .teal)
                rate("arrow.up", monitor.upRate, .orange)
            }
        }
    }

    private func rate(_ symbol: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.title3.weight(.bold)).foregroundStyle(color)
            Text(value.rateString).font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
        }
    }

    private struct RatePoint: Identifiable { let id = UUID(); let date: Date; let kind: String; let value: Double }

    private var liveCard: some View {
        let peak = monitor.rateHistory.map { max($0.down, $0.up) }.max() ?? 0
        let useMB = peak >= 1_000_000
        let divisor = useMB ? 1_000_000.0 : 1_000.0
        let unit = useMB ? "MB/s" : "KB/s"
        let points = monitor.rateHistory.flatMap {
            [RatePoint(date: $0.date, kind: "Download", value: $0.down / divisor), RatePoint(date: $0.date, kind: "Upload", value: $0.up / divisor)]
        }
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Live speed").font(.headline)
                    Spacer()
                    Text("Peak ↓ \(monitor.peakDown.rateString)").font(.caption).foregroundStyle(.secondary)
                }
                if points.count < 4 {
                    Text("Measuring…").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    Chart(points) { point in
                        AreaMark(x: .value("Time", point.date), y: .value("MB/s", point.value), series: .value("Kind", point.kind))
                            .foregroundStyle(by: .value("Kind", point.kind))
                            .opacity(0.35)
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Time", point.date), y: .value("MB/s", point.value), series: .value("Kind", point.kind))
                            .foregroundStyle(by: .value("Kind", point.kind))
                            .interpolationMethod(.monotone)
                    }
                    .chartForegroundStyleScale(["Download": Color.teal, "Upload": Color.orange])
                    .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: useMB ? "%.1f %@" : "%.0f %@", d, unit)) } } } }
                    .chartXAxis { AxisMarks(values: .stride(by: .minute)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute()) } }
                    .chartLegend(position: .top, alignment: .leading)
                    .frame(height: 180)
                }
            }
        }
    }

    private struct HourBar: Identifiable { let id = UUID(); let hour: Int; let kind: String; let mb: Double }

    private var todayCard: some View {
        let today = monitor.today
        let bars = (0..<24).flatMap { h in
            [HourBar(hour: h, kind: "Download", mb: Double(today.hourlyDown[h]) / 1_000_000),
             HourBar(hour: h, kind: "Upload", mb: Double(today.hourlyUp[h]) / 1_000_000)]
        }
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Today").font(.headline)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(today.total.byteString).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("used").foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    Label(today.down.byteString, systemImage: "arrow.down").foregroundStyle(.teal)
                    Label(today.up.byteString, systemImage: "arrow.up").foregroundStyle(.orange)
                }
                .font(.callout.weight(.medium))
                Chart(bars) { bar in
                    BarMark(x: .value("Hour", bar.hour), y: .value("MB", bar.mb))
                        .foregroundStyle(by: .value("Kind", bar.kind))
                }
                .chartForegroundStyleScale(["Download": Color.teal, "Upload": Color.orange])
                .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) { v in AxisValueLabel { if let h = v.as(Int.self) { Text("\(h):00") } } } }
                .chartLegend(.hidden)
                .frame(height: 100)
            }
        }
        .frame(width: 340)
    }

    private struct DayBar: Identifiable { let id = UUID(); let date: Date; let kind: String; let gb: Double }

    private var historyCard: some View {
        let days = monitor.days.suffix(range)
        let bars = days.flatMap { [DayBar(date: $0.date, kind: "Download", gb: Double($0.down) / 1e9), DayBar(date: $0.date, kind: "Upload", gb: Double($0.up) / 1e9)] }
        let total = days.reduce(Int64(0)) { $0 + $1.total }
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("History").font(.headline)
                    Text("\(total.byteString) over \(days.count) day\(days.count == 1 ? "" : "s") · avg \((days.isEmpty ? 0 : total / Int64(days.count)).byteString)/day")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $range) {
                        Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 230)
                }
                if days.isEmpty {
                    Text("History builds up day by day.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    Chart(bars) { bar in
                        BarMark(x: .value("Day", bar.date, unit: .day), y: .value("GB", bar.gb))
                            .foregroundStyle(by: .value("Kind", bar.kind))
                    }
                    .chartXScale(domain: Calendar.current.date(byAdding: .day, value: -(range - 1), to: Calendar.current.startOfDay(for: .now))!...Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))!)
                    .chartXAxis { AxisMarks(values: .stride(by: .day, count: range <= 7 ? 1 : range <= 30 ? 5 : 15)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                    .chartForegroundStyleScale(["Download": Color.teal, "Upload": Color.orange])
                    .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "%.1f GB", d)) } } } }
                    .frame(height: 180)
                    Divider()
                    ForEach(days.reversed().prefix(7)) { day in
                        HStack {
                            Text(day.date.formatted(date: .abbreviated, time: .omitted))
                            Spacer()
                            Label(day.down.byteString, systemImage: "arrow.down").foregroundStyle(.teal).frame(width: 110, alignment: .trailing)
                            Label(day.up.byteString, systemImage: "arrow.up").foregroundStyle(.orange).frame(width: 110, alignment: .trailing)
                            Text(day.total.byteString).fontWeight(.semibold).frame(width: 90, alignment: .trailing)
                        }
                        .font(.callout).monospacedDigit()
                    }
                }
            }
        }
    }

    private var appsCard: some View {
        let apps = Array(monitor.appTraffic.prefix(15))
        let maxBytes = Double(max(apps.first?.total ?? 1, 1))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Apps using the network").font(.title3.weight(.semibold))
                Text("since each app started").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { monitor.refreshAppTraffic() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.controlSize(.small)
            }
            Card {
                VStack(spacing: 0) {
                    if apps.isEmpty { Text("Reading per-app traffic…").foregroundStyle(.secondary).padding() }
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        if index > 0 { Divider() }
                        HStack(spacing: 10) {
                            Text(app.name).lineLimit(1)
                            Spacer()
                            SizeBar(fraction: Double(app.total) / maxBytes, color: .teal).frame(width: 140)
                            Text("↓ \(app.bytesIn.byteString)").foregroundStyle(.teal).frame(width: 100, alignment: .trailing)
                            Text("↑ \(app.bytesOut.byteString)").foregroundStyle(.orange).frame(width: 100, alignment: .trailing)
                        }
                        .font(.callout).monospacedDigit()
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }
}
