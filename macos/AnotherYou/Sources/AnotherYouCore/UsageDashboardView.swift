import Charts
import SwiftUI

public struct UsageDashboardView: View {
    @Environment(\.locale) private var interfaceLocale
    private let store: AssistantStore
    @State private var records: [UsageRecord]
    @State private var period: UsagePeriod = .day
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let palette: [Color] = [.indigo, .teal, .orange, .pink, .blue, .purple, .green, .brown]

    public init(store: AssistantStore) {
        self.store = store
        _records = State(initialValue: store.usageRecords)
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            dashboard(UsageSummary(records: records, period: period, now: timeline.date), now: timeline.date)
        }
        .onReceive(store.$usageRecords) { next in
            if records != next { records = next }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: period)
    }

    private func dashboard(_ summary: UsageSummary, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    Text(AppLocalization.text("用量概览")).font(.title3.bold()).fixedSize()
                    Spacer(minLength: 0)
                    headerActions(summary, now: now)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text(AppLocalization.text("用量概览")).font(.title3.bold())
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { headerActions(summary, now: now) }
                        VStack(alignment: .leading, spacing: 12) { headerActions(summary, now: now) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if summary.records.isEmpty {
                HStack(spacing: 20) {
                    Image(systemName: "chart.pie").font(.system(size: 48)).foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(AppLocalization.text("这段时间还没有调用记录")).font(.headline)
                        Text(AppLocalization.text("发起会话后查看真实用量；统计从此版本开始记录，保留最近 186 天。"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 16)
            } else {
                HStack(alignment: .center, spacing: 28) {
                    modelChart(summary).frame(width: 170, height: 170)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(summary.knownCount == 0 ? AppLocalization.text("未报告") : AppLocalization.number(summary.totalTokens))
                            .font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(AppLocalization.text("已报告 Token · %d 次请求", summary.records.count)).foregroundStyle(.secondary)
                        if summary.knownCount > 0 {
                            Text(AppLocalization.text("输入 %@ · 输出 %@ · 缓存 %@", AppLocalization.number(summary.inputTokens), AppLocalization.number(summary.outputTokens), AppLocalization.number(summary.cacheTokens)))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(AppLocalization.text("输入、输出和缓存 Token 均未报告")).font(.caption).foregroundStyle(.secondary)
                        }
                        if summary.unknownCount > 0 {
                            Text(AppLocalization.text("%d 次请求未报告用量，不计入 Token 总量和占比", summary.unknownCount))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if summary.failedCount > 0 {
                            Text(AppLocalization.text("含 %d 次失败请求已报告的消耗", summary.failedCount)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                Divider()
                HStack(alignment: .top, spacing: 24) {
                    modelBreakdown(summary)
                    breakdown(AppLocalization.text("思考深度"), rows: summary.reasoning, empty: AppLocalization.text("暂无记录"), unit: AppLocalization.text("次"))
                }
                Divider()
                breakdown(AppLocalization.text("工具 / Plugin / Skill / MCP"), rows: summary.tools, empty: AppLocalization.text("这段时间没有已记录的调用"), unit: AppLocalization.text("次"))
            }
        }
        .padding(.vertical, 24)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private func headerActions(_ summary: UsageSummary, now: Date) -> some View {
        Picker(AppLocalization.text("时间范围"), selection: $period) {
            ForEach(UsagePeriod.allCases) { Text($0.title(locale: interfaceLocale)).tag($0) }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        UsageExportButton(summary: summary, period: period, now: now).fixedSize()
    }

    @ViewBuilder
    private func modelChart(_ summary: UsageSummary) -> some View {
        if summary.totalTokens > 0 {
            Chart(summary.models.filter { $0.count > 0 }) { item in
                SectorMark(angle: .value("Token", item.count), angularInset: 1.5)
                    .foregroundStyle(by: .value(AppLocalization.text("模型"), item.name))
                    .accessibilityLabel(item.name)
                    .accessibilityValue("\(AppLocalization.number(item.count)) Token")
            }
            .chartForegroundStyleScale(domain: summary.models.map(\.name), range: summary.models.indices.map { palette[$0 % palette.count] })
            .chartLegend(.hidden)
        } else {
            Circle().fill(Color.secondary.opacity(0.12))
                .overlay(Text(summary.knownCount == 0 ? AppLocalization.text("未报告用量") : "0 Token").font(.caption).foregroundStyle(.secondary))
        }
    }

    private func modelBreakdown(_ summary: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalization.text("模型消耗")).font(.subheadline.bold())
            if summary.models.isEmpty { Text(AppLocalization.text("暂无已报告的模型用量")).font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(summary.models.enumerated()), id: \.element.id) { index, row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(palette[index % palette.count]).frame(width: 8, height: 8)
                    Text(row.name).font(.callout).textSelection(.enabled)
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(AppLocalization.number(row.count)) Token")
                        Text(summary.totalTokens > 0 ? (Double(row.count) / Double(summary.totalTokens)).formatted(.percent.precision(.fractionLength(1)).locale(AppLocalization.locale)) : "0%")
                    }.font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func breakdown(_ title: String, rows: [UsageBreakdown], empty: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.bold())
            if rows.isEmpty { Text(empty).font(.caption).foregroundStyle(.secondary) }
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline) {
                    Text(AppLocalization.reasoningEffort(row.name, locale: interfaceLocale)).font(.callout).textSelection(.enabled)
                    Spacer(minLength: 12)
                    Text("\(AppLocalization.number(row.count)) \(unit)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
