import SwiftUI

@MainActor
struct ActivityLogView: View {
    @Environment(\.locale) private var interfaceLocale
    private let store: AssistantStore
    @State private var history: [AgentEvent]
    @State private var period: UsagePeriod = .day
    @State private var category: ActivityCategory = .all
    @State private var grouped = false
    @State private var selectedEvent: AgentEvent?

    init(store: AssistantStore) {
        self.store = store
        _history = State(initialValue: store.history)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            activityLog(ActivityHistory(events: history, period: period, category: category, now: Date()))
        }
        .onReceive(store.$history) { next in
            if history != next { history = next }
        }
        .sheet(item: $selectedEvent) { event in ActivityDetailView(store: store, event: event) }
    }

    private func activityLog(_ snapshot: ActivityHistory) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        Text(AppLocalization.text("活动记录")).font(.title2.bold()).fixedSize()
                        Spacer(minLength: 0)
                        periodPicker
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text(AppLocalization.text("活动记录")).font(.title2.bold())
                        periodPicker
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Toggle(AppLocalization.text("按类型分组"), isOn: $grouped).toggleStyle(.checkbox).font(.caption)
                    Spacer()
                    Picker(AppLocalization.text("筛选"), selection: $category) {
                        ForEach(ActivityCategory.allCases) { Text($0.title(locale: interfaceLocale)).tag($0) }
                    }.frame(width: 190)
                }
                if snapshot.events.isEmpty { Text(AppLocalization.text("还没有活动记录。")).foregroundStyle(.secondary).font(.callout) }
                LazyVStack(alignment: .leading, spacing: 0) {
                    if grouped {
                        ForEach(ActivityCategory.allCases.filter { $0 != .all }) { category in
                            let rows = snapshot.groups[category] ?? []
                            if !rows.isEmpty {
                                Text(category.title(locale: interfaceLocale)).font(.subheadline.bold()).padding(.vertical, 12)
                                ForEach(rows) { row($0) }
                            }
                        }
                    } else { ForEach(snapshot.events) { row($0) } }
                }
            }.padding(30).frame(maxWidth: 980, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
        }.background(Color(nsColor: .windowBackgroundColor))
    }

    private var periodPicker: some View {
        Picker(AppLocalization.text("时间范围"), selection: $period) {
            ForEach(UsagePeriod.allCases) { Text($0.title(locale: interfaceLocale)).tag($0) }
        }.pickerStyle(.segmented).fixedSize()
    }

    private func row(_ event: AgentEvent) -> some View {
        Button { selectedEvent = event } label: {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.activityCategory?.icon ?? "circle").foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 5) {
                Text(event.payload["action"]?.string.map { AppLocalization.text($0) } ?? event.activityTitle(locale: interfaceLocale)).font(.system(size: 12, weight: .medium))
                if let app = event.payload["appName"]?.string { Text(app).font(.caption).foregroundStyle(.secondary) }
                if let detail = event.payload["toolName"]?.string ?? event.payload["message"]?.string ?? event.payload["text"]?.string ?? event.payload["prompt"]?.string {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer(minLength: 8)
            Text(event.date.map { AppLocalization.date($0) } ?? "").font(.caption2).foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityHint(AppLocalization.text("查看执行详情"))
    }
}
