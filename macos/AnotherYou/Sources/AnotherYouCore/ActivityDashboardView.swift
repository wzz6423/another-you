import Charts
import SwiftUI

struct ActivityDashboardView: View {
    @Environment(\.locale) private var locale
    private let store: AssistantStore
    @State private var records: [ActivityRecord]
    private let period: ActivityPeriod = .halfYear
    @State private var application: String?
    @State private var hoveredDay: ActivityDay?
    @State private var selectedHour: Int?

    init(store: AssistantStore) {
        self.store = store
        _records = State(initialValue: store.activityRecords)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let all = ActivitySummary(records: records, period: period, now: timeline.date)
            let summary = application == nil ? all : ActivitySummary(records: records, period: period, application: application, now: timeline.date)
            VStack(alignment: .leading, spacing: 24) {
                header(applications: all.availableApplications)
                heatmap(summary)
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
        .onChange(of: application) { _, _ in hoveredDay = nil; selectedHour = nil }
    }

    private func header(applications: [String]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(AppLocalization.text("使用统计")).font(.title3.bold())
                Spacer()
                Text(AppLocalization.text("会话发送与主动建议")).font(.caption).foregroundStyle(.secondary)
            }
            filters(applications)
        }
    }

    @ViewBuilder
    private func filters(_ applications: [String]) -> some View {
        Picker(AppLocalization.text("应用"), selection: $application) {
            Text(AppLocalization.text("全部应用")).tag(String?.none)
            ForEach(Array(Set(applications + (application.map { [$0] } ?? []))).sorted(), id: \.self) { name in
                Text(appTitle(name)).tag(Optional(name))
            }
        }
        .labelsHidden().pickerStyle(.menu).frame(maxWidth: 200, alignment: .leading)
        .accessibilityLabel(AppLocalization.text("应用"))
    }

    private func heatmap(_ summary: ActivitySummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(AppLocalization.text("应用活跃度")).font(.headline)
                Spacer()
                Text(AppLocalization.text("%d 次 · %d 个活跃日", summary.total, summary.activeDays))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            ActivityHeatmap(summary: summary, locale: locale, hoveredDay: $hoveredDay)
            ViewThatFits(in: .horizontal) {
                HStack {
                    heatmapCaption(summary)
                    Spacer(minLength: 12)
                    heatmapLegend
                }
                VStack(alignment: .leading, spacing: 8) {
                    heatmapCaption(summary)
                    heatmapLegend
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }

    private func heatmapCaption(_ summary: ActivitySummary) -> some View {
        Group {
            if let hoveredDay {
                Text("\(hoveredDay.date.formatted(.dateTime.year().month().day().locale(locale))) · \(AppLocalization.text("%d 次", hoveredDay.count))")
            } else if let first = summary.days.first, let last = summary.days.last {
                Text("\(first.date.formatted(.dateTime.month().day().locale(locale))) – \(last.date.formatted(.dateTime.month().day().locale(locale)))")
            }
        }
        .monospacedDigit()
    }

    private var heatmapLegend: some View {
        HStack(spacing: 4) {
            Text(AppLocalization.text("较少"))
            ForEach(0..<5) { level in
                RoundedRectangle(cornerRadius: 2).fill(ActivityHeatmap.color(level: level)).frame(width: 10, height: 10)
            }
            Text(AppLocalization.text("较多"))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppLocalization.text("颜色越深，触发次数越多"))
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
    let summary: ActivitySummary
    let locale: Locale
    @Binding var hoveredDay: ActivityDay?
    @State private var width: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let weeks = summary.weeks
            let side = Self.cellSide(width: geometry.size.width, weekCount: weeks.count)
            let maximum = summary.days.map(\.count).max() ?? 0
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
                                    .fill(Self.color(level: day.count == 0 ? 0 : max(1, Int(ceil(sqrt(Double(day.count) / Double(max(1, maximum))) * 4)))))
                                    .frame(width: side, height: side)
                                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.primary.opacity(hoveredDay?.date == day.date ? 0.6 : 0), lineWidth: 1))
                                    .onHover { inside in hoveredDay = inside ? day : nil }
                                    .help("\(day.date.formatted(.dateTime.year().month().day().locale(locale))) · \(AppLocalization.text("%d 次", day.count))")
                                    .accessibilityLabel(day.date.formatted(.dateTime.year().month().day().locale(locale)))
                                    .accessibilityValue(AppLocalization.text("%d 次", day.count))
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
        level == 0 ? Color.secondary.opacity(0.10) : Color.indigo.opacity([0, 0.25, 0.45, 0.7, 1][level])
    }

    private func weekday(_ row: Int) -> String {
        var calendar = summary.calendar
        calendar.locale = locale
        let index = (calendar.firstWeekday - 1 + row) % 7
        return row.isMultiple(of: 2) ? calendar.shortWeekdaySymbols[index] : ""
    }

    private func monthLabel(_ week: [ActivityDay?], first: Bool) -> String {
        let days = week.compactMap { $0 }
        let day = first ? days.first : days.first { summary.calendar.component(.day, from: $0.date) == 1 }
        return day?.date.formatted(.dateTime.month(.abbreviated).locale(locale)) ?? ""
    }
}
