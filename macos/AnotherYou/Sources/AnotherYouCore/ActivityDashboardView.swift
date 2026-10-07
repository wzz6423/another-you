import Charts
import SwiftUI

struct ActivityDashboardView: View {
    @Environment(\.locale) private var locale
    private let store: AssistantStore
    @State private var records: [ActivityRecord]
    @State private var usageRecords: [UsageRecord]
    private let period: ActivityPeriod = .halfYear
    @State private var hoveredDay: DailyUsage?
    @State private var selectedHour: Int?

    init(store: AssistantStore) {
        self.store = store
        _records = State(initialValue: store.activityRecords)
        _usageRecords = State(initialValue: store.usageRecords)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let summary = ActivitySummary(records: records, period: period, now: timeline.date)
            let usage = DailyUsageSummary(records: usageRecords, period: period, now: timeline.date)
            VStack(alignment: .leading, spacing: 24) {
                header
                heatmap(usage)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        frequency(summary).frame(minWidth: 280)
                        applications(summary).frame(minWidth: 280)
                    }
                    VStack(alignment: .leading, spacing: 24) {
                        frequency(summary)
                        applications(summary)
                    }
                }
            }
        }
        .onReceive(store.$activityRecords) { next in
            if records != next { records = next }
        }
        .onReceive(store.$usageRecords) { next in
            if usageRecords != next { usageRecords = next }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(AppLocalization.text("使用统计")).font(.title3.bold())
            Spacer()
            Text(AppLocalization.text("Token 用量与应用活动")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func heatmap(_ summary: DailyUsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(AppLocalization.text("每日 Token 用量")).font(.headline)
                Spacer()
                Group {
                    if summary.knownCount > 0 {
                        Text(AppLocalization.text("已报告 %@ Token · %d 个用量日", AppLocalization.number(summary.totalTokens), summary.usageDays))
                    } else {
                        Text(AppLocalization.text(summary.unknownCount > 0 ? "未报告用量" : "无用量记录"))
                    }
                }.font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            ActivityHeatmap(summary: summary, locale: locale, hoveredDay: $hoveredDay)
            VStack(alignment: .leading, spacing: 10) {
                heatmapCaption(summary)
                heatmapLegend
                if summary.unknownCount > 0 {
                    Text(AppLocalization.text("虚线方格含未报告用量"))
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }

    private func heatmapCaption(_ summary: DailyUsageSummary) -> some View {
        Group {
            if let hoveredDay, let day = summary.days.first(where: { $0.date == hoveredDay.date }) {
                Text("\(day.date.formatted(.dateTime.year().month().day().locale(locale))) · \(day.description(locale: locale))")
            } else if let first = summary.days.first, let last = summary.days.last {
                Text("\(first.date.formatted(.dateTime.month().day().locale(locale))) – \(last.date.formatted(.dateTime.month().day().locale(locale)))")
            }
        }
        .monospacedDigit()
    }

    private var heatmapLegend: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { heatmapLevels }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 8) {
                    heatmapLevels
                }
            }
        }
    }

    private var heatmapLevels: some View {
        ForEach(UsageHeatmapScale.labels.indices, id: \.self) { level in
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(ActivityHeatmap.color(level: level)).frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(UsageHeatmapScale.labels[level]).monospacedDigit().fixedSize()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(UsageHeatmapScale.labels[level]) Token")
        }
    }

    private func frequency(_ summary: ActivitySummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(AppLocalization.text("今日使用频率")).font(.headline)
                Spacer()
                Text(AppLocalization.text("%d 次", summary.todayTotal)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Chart {
                ForEach(summary.hours) { item in
                    AreaMark(x: .value(AppLocalization.text("时间"), item.hour), y: .value(AppLocalization.text("触发次数"), item.count))
                        .foregroundStyle(.indigo.opacity(0.08))
                    LineMark(x: .value(AppLocalization.text("时间"), item.hour), y: .value(AppLocalization.text("触发次数"), item.count))
                        .foregroundStyle(.indigo).lineStyle(StrokeStyle(lineWidth: 2))
                        .symbol(.circle).symbolSize(16)
                        .accessibilityLabel(String(format: "%02d:00", item.hour))
                        .accessibilityValue(AppLocalization.text("%d 次", item.count))
                }
                if let selectedHour, summary.hours.contains(where: { $0.hour == selectedHour }) {
                    RuleMark(x: .value(AppLocalization.text("时间"), selectedHour)).foregroundStyle(.secondary.opacity(0.35))
                }
            }
            .chartXScale(domain: 0...23)
            .chartYScale(domain: 0...max(1, summary.hours.map(\.count).max() ?? 0))
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                    AxisTick()
                    AxisValueLabel { if let hour = value.as(Int.self) { Text(String(format: "%02d", hour)) } }
                }
            }
            .chartYAxis { integerAxis }
            .chartXSelection(value: $selectedHour)
            .frame(height: 180)
            Group {
                if let selectedHour, let item = summary.hours.first(where: { $0.hour == selectedHour }) {
                    Text("\(String(format: "%02d:00", item.hour)) · \(AppLocalization.text("%d 次", item.count))")
                } else {
                    Text(AppLocalization.text("按本地时间，每小时统计"))
                }
            }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }

    private func applications(_ summary: ActivitySummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppLocalization.text("应用触发次数")).font(.headline)
            if summary.applications.isEmpty {
                ContentUnavailableView(AppLocalization.text("暂无记录"), systemImage: "chart.bar.xaxis")
                    .frame(height: 180)
            } else {
                Chart(summary.applications) { item in
                    BarMark(x: .value(AppLocalization.text("触发次数"), item.count),
                            y: .value(AppLocalization.text("应用"), appTitle(item.name)), height: .fixed(16))
                        .foregroundStyle(.indigo.gradient).cornerRadius(3)
                        .annotation(position: .trailing) {
                            Text(AppLocalization.number(item.count)).font(.caption2).monospacedDigit()
                        }
                        .accessibilityLabel(appTitle(item.name))
                        .accessibilityValue(AppLocalization.text("%d 次", item.count))
                }
                .chartXScale(domain: 0...max(1, Double(summary.applications.first?.count ?? 0) * 1.2))
                .chartXAxis { integerAxis }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisValueLabel { if let name = value.as(String.self) { Text(name).lineLimit(1).truncationMode(.middle).help(name) } }
                    }
                }
                .frame(height: max(180, CGFloat(summary.applications.count) * 28))
            }
            Text(AppLocalization.text("近 %d 个月", period.rawValue)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }

    private var integerAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) { value in
            if let number = value.as(Double.self), number.rounded() == number {
                AxisGridLine()
                AxisValueLabel { Text(AppLocalization.number(Int(number))) }
            }
        }
    }

    private func appTitle(_ name: String) -> String {
        name.isEmpty ? AppLocalization.text("未关联应用") : name
    }
}

private struct ActivityHeatmap: View {
    let summary: DailyUsageSummary
    let locale: Locale
    @Binding var hoveredDay: DailyUsage?
    @State private var width: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let weeks = summary.weeks
            let side = Self.cellSide(width: geometry.size.width, weekCount: weeks.count)
            HStack(alignment: .top, spacing: 4) {
                VStack(spacing: 4) {
                    Color.clear.frame(width: 28, height: 18)
                    ForEach(0..<7) { row in
                        Text(weekday(row)).font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(width: 28, height: side)
                    }
                }
                ForEach(weeks.indices, id: \.self) { week in
                    VStack(spacing: 4) {
                        Text(monthLabel(weeks[week], first: week == 0))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize().frame(width: side, height: 18, alignment: week == weeks.count - 1 ? .trailing : .leading)
                        ForEach(0..<7) { row in
                            if let day = weeks[week][row] {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Self.color(level: UsageHeatmapScale.level(for: day.totalTokens)))
                                    .frame(width: side, height: side)
                                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(day.unknownCount > 0 ? 0.6 : 0), style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
                                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.primary.opacity(hoveredDay?.date == day.date ? 0.6 : 0), lineWidth: 1))
                                    .onHover { inside in hoveredDay = inside ? day : nil }
                                    .help("\(day.date.formatted(.dateTime.year().month().day().locale(locale))) · \(day.description(locale: locale))")
                                    .accessibilityLabel(day.date.formatted(.dateTime.year().month().day().locale(locale)))
                                    .accessibilityValue(day.description(locale: locale))
                            } else {
                                Color.clear.frame(width: side, height: side).accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
        }
        .frame(height: 46 + 7 * Self.cellSide(width: width, weekCount: summary.weeks.count))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private static func cellSide(width: CGFloat, weekCount: Int) -> CGFloat {
        let columns = CGFloat(max(1, weekCount))
        return max(1, (width - 28 - 4 * columns) / columns)
    }

    static func color(level: Int) -> Color {
        level == 0 ? Color.secondary.opacity(0.10) : Color.indigo.opacity([0, 0.16, 0.28, 0.42, 0.60, 0.80, 1][level])
    }

    private func weekday(_ row: Int) -> String {
        var calendar = summary.calendar
        calendar.locale = locale
        let index = (calendar.firstWeekday - 1 + row) % 7
        return row.isMultiple(of: 2) ? calendar.shortWeekdaySymbols[index] : ""
    }

    private func monthLabel(_ week: [DailyUsage?], first: Bool) -> String {
        let days = week.compactMap { $0 }
        let day = first ? days.first : days.first { summary.calendar.component(.day, from: $0.date) == 1 }
        return day?.date.formatted(.dateTime.month(.abbreviated).locale(locale)) ?? ""
    }
}
