import SwiftUI
import AppKit
import UniformTypeIdentifiers

private enum HistoryPresentation {
    static func date(_ value: Date?) -> String {
        guard let value else { return "时间未知" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: value)
    }

    static func label(_ run: HistoricalRun) -> String {
        if run.snapshot.endedAt == nil { return "未观察到结束" }
        switch run.status {
        case .completed: return "本轮已结束"
        case .failed: return "明确失败"
        case .stopped: return "已中断"
        default: return "边界待核实"
        }
    }
}

struct HistoryPage: View {
    @ObservedObject var history: HistoryModel
    @ObservedObject var center: TaskCenterStore
    @State private var range = "7"
    @State private var startDate = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @State private var endDate = Date()
    @State private var source = ""
    @State private var project = ""
    @State private var grouping = "day"
    @State private var selected: HistoricalRun?
    @State private var showClear = false
    @State private var visibleLimit = 50
    @State private var exportMessage: String?

    private var filter: HistoryFilter {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let from: Date
        let through: Date
        if range == "custom" {
            from = calendar.startOfDay(for: min(startDate, endDate))
            through = calendar.startOfDay(for: max(startDate, endDate))
        } else {
            let days = Int(range) ?? 7
            from = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
            through = today
        }
        let end = calendar.date(byAdding: .day, value: 1, to: through) ?? through.addingTimeInterval(86400)
        return HistoryFilter(interval: DateInterval(start: from, end: end),
                             source: source.isEmpty ? nil : source, project: project.isEmpty ? nil : project)
    }

    private var filteredRuns: [HistoricalRun] { history.runs.filter(filter.includes) }
    private var summary: HistorySummary {
        HistoryStatistics.summarize(runs: filteredRuns, attentions: center.attentions, filter: filter)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selected {
                Button("返回工作回顾") { self.selected = nil }.buttonStyle(.link)
                ScrollView { HistoryRunPanel(run: selected, center: center) }
            } else {
                controls
                if let issue = history.issue { Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundColor(.orange) }
                if let status = history.importStatus { Text(status).font(.caption).foregroundColor(.secondary) }
                if history.truncated {
                    Label("当前范围超过 5,000 条，展示和统计最近 5,000 条；可缩小时间或筛选范围。", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundColor(.orange)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        overview
                        trend
                        runList
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear { applyFilter() }
        .onChange(of: range) { _ in applyFilter() }
        .onChange(of: startDate) { _ in if range == "custom" { applyFilter() } }
        .onChange(of: endDate) { _ in if range == "custom" { applyFilter() } }
        .onChange(of: source) { _ in applyFilter() }
        .onChange(of: project) { _ in applyFilter() }
        .alert("清除本应用历史？", isPresented: $showClear) {
            Button("清除历史", role: .destructive) { history.clearHistory() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("来源会话与待处理事项不会删除。以后主动回填旧日志时，可能重新导入已清除的历史。")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("时间范围", selection: $range) {
                    Text("今天").tag("1"); Text("近 7 天").tag("7"); Text("近 30 天").tag("30"); Text("自选").tag("custom")
                }.pickerStyle(.segmented).frame(width: 330)
                Spacer()
            }
            HStack {
                Button(history.importing ? "正在回填…" : "回填旧日志") { history.beginBackfill() }
                    .disabled(history.importing || history.loading)
                Menu("导出统计") {
                    Button("导出 CSV") { export(format: "csv") }
                    Button("导出 JSON") { export(format: "json") }
                }.disabled(history.loading || filteredRuns.isEmpty)
                Button("清除历史") { showClear = true }.disabled(history.loading)
                Spacer()
            }
            HStack {
                if range == "custom" {
                    DatePicker("开始", selection: $startDate, displayedComponents: .date).frame(maxWidth: 180)
                    DatePicker("结束", selection: $endDate, displayedComponents: .date).frame(maxWidth: 180)
                }
                Picker("来源", selection: $source) {
                    Text("全部来源").tag("")
                    ForEach(history.sources, id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 180)
                Picker("项目", selection: $project) {
                    Text("全部项目").tag("")
                    ForEach(history.projects, id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 260)
                Spacer()
            }.controlSize(.small)
            Text("自动记录自 \(HistoryPresentation.date(history.enabledAt))；回填读取已发现的本地会话，不补发旧通知。保留期限遵循设置。")
                .font(.caption).foregroundColor(.secondary)
            Text("目前支持 Codex、Claude、CatDesk 的结构化日志；其他来源暂不计入。")
                .font(.caption).foregroundColor(.secondary)
            if let exportMessage { Text(exportMessage).font(.caption).foregroundColor(.secondary) }
        }
    }

    private var overview: some View {
        let data = summary
        return VStack(alignment: .leading, spacing: 10) {
            Text("回合与等待").font(.headline)
            HStack(spacing: 10) {
                metric("本轮已结束", "\(data.completed)", .blue)
                metric("明确失败", "\(data.failed)", .red)
                metric("已中断", "\(data.stopped)", .secondary)
                metric("片段 / 待核实", "\(data.partial)", .orange)
            }
            HStack(spacing: 10) {
                metric("可确认等待", "\(data.waits) 次", .primary)
                metric("累计等待", WorkflowFormatting.duration(data.waitSeconds), .primary)
                metric("日历等待（去重）", WorkflowFormatting.duration(data.calendarWaitSeconds), .primary)
            }
            if data.matchedWaits > 0 {
                Text("可关联的 \(data.matchedWaits) 次等待：主动延后 \(WorkflowFormatting.duration(data.deferredSeconds)) · 非延后等待 \(WorkflowFormatting.duration(data.nonDeferredSeconds))")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Text("暂无可完整关联的延后记录；旧记录和缺少起止证据的等待不推算延后时长。")
                    .font(.caption).foregroundColor(.secondary)
            }
            Text("仅统计来源可确认的回合与已结束等待；回合结束不代表业务验收。日历等待包含延后。时区：\(TimeZone.current.identifier)")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private func metric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundColor(color)
        }.frame(maxWidth: .infinity, minHeight: 65, alignment: .leading)
            .padding(.horizontal, 12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }

    private var trend: some View {
        let days = grouping == "week" ? HistoryStatistics.groupedByWeek(summary.days) : summary.days
        let shown = Array(days.suffix(14))
        let maximum = max(1, shown.map { $0.completed + $0.failed + $0.stopped }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("回合趋势").font(.headline)
                Spacer()
                Picker("汇总方式", selection: $grouping) { Text("按日").tag("day"); Text("按周").tag("week") }
                    .pickerStyle(.segmented).frame(width: 120)
            }
            if shown.isEmpty {
                Text("当前范围暂无可确认结束时间的回合。") .font(.caption).foregroundColor(.secondary)
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(shown) { day in
                        let count = day.completed + day.failed + day.stopped
                        VStack(spacing: 4) {
                            Text("\(count)").font(.system(size: 9)).foregroundColor(.secondary)
                            RoundedRectangle(cornerRadius: 3).fill(Color.blue.opacity(0.75))
                                .frame(height: max(3, CGFloat(count) / CGFloat(maximum) * 65))
                            Text(day.day, format: .dateTime.month().day()).font(.system(size: 9)).foregroundColor(.secondary)
                        }.frame(maxWidth: .infinity).accessibilityLabel("\(HistoryPresentation.date(day.day))，\(count) 个已结束回合")
                    }
                }.frame(height: 100, alignment: .bottom)
                Text("仅显示有可确认记录的日期；最近最多 14 个时间点。") .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var runList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("历史回合 · \(filteredRuns.count)").font(.headline)
            if history.loading { ProgressView("正在读取历史…") }
            else if filteredRuns.isEmpty { Text("当前范围暂无历史回合。新记录会自动积累，也可主动回填旧日志。") .font(.caption).foregroundColor(.secondary) }
            LazyVStack(spacing: 6) {
                ForEach(Array(filteredRuns.prefix(visibleLimit))) { run in
                    Button { selected = run } label: { HistoryRunRow(run: run) }.buttonStyle(.plain)
                }
            }
            if filteredRuns.count > visibleLimit {
                Button("加载更多") { visibleLimit += 50 }.buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    private func applyFilter() {
        visibleLimit = 50
        history.setFilter(filter)
    }

    private func export(format: String) {
        let data = summary
        let report: [String: Any] = [
            "from": ISO8601DateFormatter().string(from: filter.interval.start),
            "to_exclusive": ISO8601DateFormatter().string(from: filter.interval.end),
            "timezone": TimeZone.current.identifier,
            "source": source.isEmpty ? "全部" : source,
            "project_filtered": !project.isEmpty,
            "truncated": history.truncated,
            "completed_rounds": data.completed, "failed_rounds": data.failed, "stopped_rounds": data.stopped,
            "partial_rounds": data.partial, "confirmed_waits": data.waits,
            "cumulative_wait_seconds": data.waitSeconds, "calendar_wait_seconds": data.calendarWaitSeconds,
            "matched_waits": data.matchedWaits,
            "deferred_seconds": data.matchedWaits > 0 ? data.deferredSeconds as Any : NSNull(),
            "non_deferred_seconds": data.matchedWaits > 0 ? data.nonDeferredSeconds as Any : NSNull()
        ]
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Agent哈基米-工作回顾.\(format)"
        panel.allowedContentTypes = [format == "json" ? .json : .commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data
            if format == "json" {
                data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            } else {
                let rows = report.keys.sorted().map { key in
                    let value = String(describing: report[key] ?? "")
                    let safe = ["=", "+", "-", "@"].contains(where: value.hasPrefix) ? "'" + value : value
                    return "\"\(key.replacingOccurrences(of: "\"", with: "\"\""))\",\"\(safe.replacingOccurrences(of: "\"", with: "\"\""))\""
                }
                data = Data((["\"metric\",\"value\""] + rows).joined(separator: "\n").utf8)
            }
            try data.write(to: url, options: .atomic)
            exportMessage = "已导出汇总；未包含会话标题或项目路径。"
        } catch { exportMessage = "导出失败：\(error.localizedDescription)" }
    }
}

private struct HistoryRunRow: View {
    let run: HistoricalRun
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(run.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text("\(run.source) · \(TaskCenterView.projectName(run.project)) · \(HistoryPresentation.date(run.snapshot.startedAt))")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(HistoryPresentation.label(run)).font(.caption).foregroundColor(run.status.color)
                if run.snapshot.isPartial || !run.snapshot.hasExplicitStart { Text("日志片段").font(.caption2).foregroundColor(.orange) }
                if run.imported { Text("已回填").font(.caption2).foregroundColor(.secondary) }
            }
            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
        }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct SessionHistoryView: View {
    @ObservedObject var history: HistoryModel
    @ObservedObject var center: TaskCenterStore
    let taskID: String
    @State private var selected: HistoricalRun?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let selected {
                Button("返回历史回合") { self.selected = nil }.buttonStyle(.link)
                HistoryRunPanel(run: selected, center: center)
            } else if history.sessionTaskID != taskID {
                ProgressView("正在读取历史…")
            } else if history.sessionRuns.isEmpty {
                Text("该会话暂无历史回合。可在「工作回顾」中主动回填旧日志。") .foregroundColor(.secondary)
            } else {
                Text("历史回合 · \(history.sessionRuns.count)").font(.headline)
                if history.sessionTruncated { Text("仅显示最近 500 个回合。") .font(.caption).foregroundColor(.orange) }
                ForEach(history.sessionRuns) { run in
                    Button { selected = run } label: { HistoryRunRow(run: run) }.buttonStyle(.plain)
                }
            }
        }.onAppear { history.loadSession(taskID) }
    }
}

private struct HistoryRunPanel: View {
    let run: HistoricalRun
    @ObservedObject var center: TaskCenterStore
    @State private var navigationMessage: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(run.title).font(.headline); Spacer(); Text(HistoryPresentation.label(run)).foregroundColor(run.status.color) }
            Text("\(run.source) · \(TaskCenterView.projectName(run.project)) · 开始：\(HistoryPresentation.date(run.snapshot.startedAt)) · 结束：\(HistoryPresentation.date(run.snapshot.endedAt))")
                .font(.caption).foregroundColor(.secondary)
            if run.snapshot.isPartial || !run.snapshot.hasExplicitStart {
                Label("日志片段，部分步骤或回合边界可能缺失。", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundColor(.orange)
            }
            if let task = center.task(run.taskID) {
                Button("回到来源会话") { TaskNavigator.open(task) { navigationMessage = $0 } }.buttonStyle(.bordered)
            }
            if let navigationMessage { Text(navigationMessage).font(.caption).foregroundColor(.secondary) }
            if run.snapshot.steps.isEmpty { Text("没有可展示的步骤。") .foregroundColor(.secondary) }
            else {
                // 历史视图不会将未知的旧步骤画成正在执行。
                WorkflowGraphView(snapshot: run.snapshot, phase: run.status == .running ? .unknown : run.status)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
