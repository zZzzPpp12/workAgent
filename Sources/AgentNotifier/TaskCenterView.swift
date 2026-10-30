import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement

/// 哮天犬是固定品牌资产，主面板和引导共用原图，避免改版时被通用符号替代。
struct BrandMascotView: View {
    var size: CGFloat
    private static let mascotImage: NSImage? = Bundle.main.url(forResource: "app-icon-1024", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        Image(nsImage: Self.mascotImage ?? NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .accessibilityLabel("哮天犬品牌形象")
    }
}

struct TaskCenterView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var center: TaskCenterStore
    @ObservedObject var credit: CreditStore
    @ObservedObject var updater: UpdateChecker
    @ObservedObject var preferences = MonitorPreferences.shared
    @State private var page = "overview"
    @AppStorage("r1.search") private var search = ""
    @AppStorage("r1.sourceFilter") private var sourceFilter = "全部来源"
    @AppStorage("r1.projectFilter") private var projectFilter = "全部项目"
    @AppStorage("r1.phaseFilter") private var phaseFilter = "全部状态"
    @AppStorage("ui.theme") private var theme = "dark"
    @AppStorage("r1.onboardingComplete") private var onboarded = false
    @State private var showOnboarding = false
    @State private var detailID: String?
    @State private var detailAttentionID: String?
    @State private var clipboardFeedback: ClipboardFeedback?
    @State private var defaultMuteDate = Date().addingTimeInterval(3600)
    @State private var workflowIncludeHistory = false

    init(monitor: Monitor, credit: CreditStore, updater: UpdateChecker) {
        self.monitor = monitor
        self.center = monitor.center
        self.credit = credit
        self.updater = updater
    }

    private let pages: [(String, String, String)] = [
        ("overview", "任务总览", "square.grid.2x2"),
        ("tasks", "全部任务", "list.bullet.rectangle"),
        ("workflows", "执行工作流", "point.topleft.down.curvedto.point.bottomright.up"),
        ("snoozed", "已延后", "clock"),
        ("sources", "来源接入", "point.3.connected.trianglepath.dotted"),
        ("diagnostics", "监测诊断", "waveform.path.ecg"),
        ("settings", "设置", "slider.horizontal.3")
    ]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                header
                if let message = center.navigationMessage { notice(message, icon: "arrow.up.forward.app", color: .blue) }
                if let issue = center.storageIssue { notice(issue, icon: "externaldrive.badge.exclamationmark") }
                if let clipboardFeedback { ClipboardFeedbackView(feedback: clipboardFeedback) }
                if page == "settings" { settingsPage }
                else if page == "sources" { sourcesPage }
                else if page == "diagnostics" { diagnosticsPage }
                else {
                    if page == "overview" { quotas }
                    filters
                    if page == "workflows" { workflowContent } else { taskContent }
                    HStack {
                        Text("来源：\(center.sources.filter(\.healthy).count) 正常 / \(center.sources.filter { !$0.healthy }.count) 受限或未配置").font(.system(size: 10)).foregroundColor(.secondary)
                        Spacer()
                        Button("查看接入状态") { page = "sources" }.buttonStyle(.link).font(.system(size: 10))
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 36)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(UITheme(rawValue: theme)?.scheme)
        .frame(minWidth: 800, minHeight: 580)
        .sheet(isPresented: Binding(get: { detailID != nil }, set: { if !$0 { detailID = nil; center.selectedTaskID = nil } })) {
            if let id = detailID { TaskDetailView(center: center, taskID: id, attentionID: detailAttentionID) }
        }
        .sheet(isPresented: $showOnboarding) { onboarding }
        .onAppear { center.inspectPermission(); showOnboarding = !onboarded }
        .onChange(of: preferences.value) { _ in monitor.scanAndPoll() }
        .onChange(of: preferences.value.creditEnabled) { _ in credit.applyNetworkSetting() }
        .onChange(of: center.requestedTaskID) { id in
            if let id { page = "overview"; detailAttentionID = center.requestedAttentionID; detailID = id; center.selectedTaskID = id; center.requestedTaskID = nil; center.requestedAttentionID = nil }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 8) {
                BrandMascotView(size: 56)
                VStack(spacing: 3) {
                    Text("Agent哮天犬").font(.system(size: 14, weight: .bold))
                    Text("任务监测中心").font(.system(size: 10)).foregroundColor(.secondary)
                }
            }.frame(maxWidth: .infinity).padding(.bottom, 24)
            ForEach(pages, id: \.0) { entry in
                Button { page = entry.0 } label: {
                    HStack(spacing: 9) {
                        Image(systemName: entry.2).frame(width: 17)
                        Text(entry.1)
                        Spacer(minLength: 0)
                        if entry.0 == "overview", center.actionableCount > 0 {
                            Text("\(center.actionableCount)").font(.caption.bold()).foregroundColor(.orange)
                        }
                    }
                    .font(.system(size: 12, weight: page == entry.0 ? .semibold : .regular))
                    .padding(.horizontal, 10).padding(.vertical, 10)
                    .foregroundColor(page == entry.0 ? .blue : .primary)
                    .background(RoundedRectangle(cornerRadius: 8).fill(page == entry.0 ? Color.blue.opacity(0.12) : .clear))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Spacer()
            if preferences.value.isQuiet(at: Date()) {
                Label("提醒已静音", systemImage: "bell.slash").font(.caption).foregroundColor(.orange)
            } else {
                Label("正在本机监测", systemImage: "circle.fill").font(.caption).foregroundColor(.secondary)
            }
            Text("v\(Config.appVersion) · 工作流").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
            Text("状态与处理记录保存在本机").font(.system(size: 9)).foregroundColor(.secondary).padding(.top, 4)
        }
        .padding(.horizontal, 12).padding(.top, 46).padding(.bottom, 20)
        .frame(width: 158)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(pages.first { $0.0 == page }?.1 ?? "任务总览").font(.system(size: 24, weight: .bold))
                Text(subtitle).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            if !["settings", "diagnostics", "sources"].contains(page) {
                Menu {
                    Button("静音 30 分钟") { preferences.value.muteUntil = Date().addingTimeInterval(1800) }
                    Button("静音 1 小时") { preferences.value.muteUntil = Date().addingTimeInterval(3600) }
                    Button("恢复提醒") { preferences.value.muteUntil = nil }
                    Divider()
                    Button("提醒设置…") { page = "settings" }
                } label: { Label("提醒", systemImage: preferences.value.isQuiet(at: Date()) ? "bell.slash" : "bell") }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
    }
    private var subtitle: String {
        switch page {
        case "workflows": return "跟随真实日志，查看模型处理、工具调用与等待交互的执行过程。"
        case "sources": return "接入能力如实展示，来源异常不会被当成任务失败。"
        case "settings": return "控制提醒、来源与网络功能，按你的节奏工作。"
        case "diagnostics": return "查看本次扫描、通知授权与本地存储状态。"
        case "snoozed": return "到期时重新核对；已恢复的任务不会再次提醒。"
        default: return "先处理需要你介入的任务，再查看本轮结果。"
        }
    }

    private var quotas: some View {
        HStack(alignment: .top, spacing: 12) {
            panel {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Credit 额度", systemImage: "creditcard").font(.caption).foregroundColor(.secondary)
                    if !preferences.value.creditEnabled {
                        Text("已关闭联网获取").font(.headline)
                    } else if credit.hasData {
                        CreditHeaderView(credit: credit)
                        Text(credit.lastUpdated.map { "更新于 \(Self.time($0))" } ?? "数据时间未知")
                            .font(.system(size: 9)).foregroundColor(.secondary)
                        if let error = credit.fetchError { Text(error).font(.system(size: 9)).foregroundColor(.orange).lineLimit(1) }
                    } else {
                        Text(credit.needsLogin ? "需要登录后获取额度" : "正在获取额度…").font(.callout)
                        if credit.needsLogin { Button("登录") { credit.showLogin() }.controlSize(.small) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            panel {
                CodexSnapshotView(quota: monitor.codexQuota)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            if page == "overview" {
                HStack(spacing: 12) {
                    metric("需要处理", value: center.actionableCount, color: .orange)
                    metric("执行中", value: center.runningCount, color: .green)
                    metric("回合待查看", value: center.reviewCount, color: .blue)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("搜索任务、项目或会话 ID", text: $search).textFieldStyle(.plain)
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                Picker("来源", selection: $sourceFilter) {
                    Text("全部来源").tag("全部来源")
                    ForEach(SourceGroup.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }.labelsHidden().frame(width: 112)
                Picker("项目", selection: $projectFilter) {
                    Text("全部项目").tag("全部项目")
                    ForEach(Array(Set(center.tasks.map(\.project))).sorted(), id: \.self) { Text(projectLabel($0)).tag($0).help($0) }
                }.labelsHidden().frame(width: 120)
                Picker("状态", selection: $phaseFilter) {
                    Text("全部状态").tag("全部状态")
                    ForEach(TaskPhase.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }.labelsHidden().frame(width: 110)
            }
            .padding(9).background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
            if filtered {
                HStack {
                    Text("正在筛选\(hiddenImportant > 0 ? " · 另有 \(hiddenImportant) 项待处理未显示" : "")").font(.caption).foregroundColor(.secondary)
                    Button("查看全部 / 重置") { resetFilters() }.font(.caption).buttonStyle(.link)
                }
            }
        }
    }
    private var filtered: Bool { !search.isEmpty || sourceFilter != "全部来源" || projectFilter != "全部项目" || phaseFilter != "全部状态" }
    private func resetFilters() { search = ""; sourceFilter = "全部来源"; projectFilter = "全部项目"; phaseFilter = "全部状态" }
    private func matches(_ task: TaskRecord) -> Bool {
        preferences.enabled(task.source)
            && (sourceFilter == "全部来源" || sourceFilter == task.source)
            && (projectFilter == "全部项目" || projectFilter == task.project)
            && (phaseFilter == "全部状态" || phaseFilter == task.phase.rawValue)
            && (search.isEmpty || (task.title + task.project + task.id).localizedCaseInsensitiveContains(search))
    }
    private var hiddenImportant: Int {
        Set(center.visibleItems().filter { $0.phase.actionable && center.task($0.taskID).map { !matches($0) } == true }.map(\.taskID)).count
    }

    private var taskContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if page == "tasks" {
                    let tasks = center.tasks.filter(matches)
                    if tasks.isEmpty { empty("没有匹配的任务", detail: "调整筛选条件，或在已接入的 Agent 中开始一个回合。", icon: "tray") }
                    ForEach(tasks) { task in taskRow(task, attention: center.item(for: task.id)) }
                } else if page == "snoozed" {
                    let items = center.attentions.filter { $0.resolvedAt == nil && ($0.snoozedUntil ?? .distantPast) > Date() }
                    if items.isEmpty { empty("没有已延后的事项", detail: "需要稍后处理时，可以在任务上选择提醒时间。", icon: "clock.badge.checkmark") }
                    ForEach(items) { item in
                        if let task = center.task(item.taskID), matches(task) { taskRow(task, attention: item) }
                    }
                } else {
                    overviewSections
                }
            }.padding(.bottom, 8)
        }
    }

    private var workflowContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("运行中的执行过程").font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("包含历史与其他状态", isOn: $workflowIncludeHistory).font(.caption).toggleStyle(.checkbox)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    let tasks = center.tasks.filter { matches($0) && (workflowIncludeHistory || [.running, .approval, .input, .suspected, .stalled].contains($0.phase)) }
                    if tasks.isEmpty {
                        empty("当前没有匹配的执行工作流", detail: "在 Agent 中开始任务后会自动出现，也可勾选包含历史与其他状态。", icon: "point.topleft.down.curvedto.point.bottomright.up")
                    }
                    ForEach(tasks) { task in
                        WorkflowCardView(task: task) {
                            // 查看执行过程不确认同一会话的旧回合结果。
                            detailAttentionID = nil
                            center.selectedTaskID = task.id
                            detailID = task.id
                        }
                    }
                    Text("展示来源已经记录的步骤，不推测内部思维过程。计划仅在模型显式更新时出现。")
                        .font(.system(size: 10)).foregroundColor(.secondary).padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder private var overviewSections: some View {
        let all = center.visibleItems().filter { item in center.task(item.taskID).map(matches) == true }
        let blocking = all.filter { $0.phase.actionable }
        sectionTitle("需要你处理", count: Set(blocking.map(\.taskID)).count)
        if blocking.isEmpty { empty("暂时没有需要你处理的任务", detail: "已确认的待审批、待回答与失败会出现在这里。", icon: "checkmark.shield") }
        ForEach(uniqueTasks(blocking)) { item in
            if let task = center.task(item.taskID) { taskRow(task, attention: item) }
        }
        let running = center.tasks.filter { $0.phase == .running && $0.precise && matches($0) }
        sectionTitle("执行中", count: running.count)
        if running.isEmpty { Text("当前没有已确认执行中的任务").font(.caption).foregroundColor(.secondary).padding(.vertical, 4) }
        ForEach(running) { task in taskRow(task, attention: nil) }
        let reviews = all.filter { $0.phase == .completed }
        if !reviews.isEmpty {
            sectionTitle("本轮结束 · 结果待查看", count: reviews.count)
            ForEach(reviews) { item in if let task = center.task(item.taskID) { taskRow(task, attention: item) } }
        }
        let inferred = all.filter { $0.phase.inferred }
        if !inferred.isEmpty {
            sectionTitle("需要核实 · 推测状态", count: inferred.count)
            Text("以下事项未计入确定的待处理数量，默认不发送系统提醒。").font(.caption).foregroundColor(.secondary)
            ForEach(uniqueTasks(inferred)) { item in if let task = center.task(item.taskID) { taskRow(task, attention: item) } }
        }
        Button("查看全部任务（\(center.tasks.count)）") { page = "tasks" }.buttonStyle(.link).padding(.top, 8)
    }

    private func uniqueTasks(_ items: [AttentionRecord]) -> [AttentionRecord] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.taskID).inserted }
    }

    private func taskRow(_ task: TaskRecord, attention: AttentionRecord?) -> some View {
        let phase = attention?.phase ?? task.phase
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: phase.symbol).foregroundColor(phase.color).font(.system(size: 18)).frame(width: 22).padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button { showDetail(task, item: attention) } label: {
                        Text(task.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).foregroundColor(.primary)
                    }.buttonStyle(.plain).help(task.title)
                    Spacer(minLength: 8)
                    Text(phase.label).font(.system(size: 10, weight: .medium)).foregroundColor(phase.color)
                }
                Text("\(task.source) · \(projectLabel(task.project)) · \(relative(attention?.createdAt ?? task.activity))")
                    .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1).help(task.project)
                if phase.actionable || phase.inferred { Text(task.evidence).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2) }
                if let flow = task.workflow, !flow.steps.isEmpty, phase == .running || phase.actionable {
                    HStack(spacing: 6) {
                        Image(systemName: flow.currentStep?.kind.symbol ?? "waveform.path")
                        Text(flow.activity(for: phase)).lineLimit(1)
                        Text("· \(flow.toolCount) 次工具调用").foregroundColor(.secondary)
                    }.font(.system(size: 10)).foregroundColor(.secondary)
                }
                if let until = attention?.snoozedUntil, until > Date() {
                    Text("延后至 \(Self.time(until))").font(.caption).foregroundColor(.orange)
                } else if attention?.recovered == true {
                    Text("启动时恢复 · 未补发历史通知").font(.system(size: 9)).foregroundColor(.secondary)
                }
                HStack(spacing: 10) {
                    Button("回到任务") { center.recordReturn(task.id, attentionID: attention?.id); TaskNavigator.open(task) { center.navigationMessage = $0 } }
                        .help(TaskNavigator.returnDescription(for: task))
                    Button("查看详情") { showDetail(task, item: attention) }
                    if let item = attention {
                        if (item.snoozedUntil ?? .distantPast) > Date() {
                            Button("取消延后") { center.unsnooze(item.id) }
                        } else if phase != .completed {
                            Menu("稍后提醒") {
                                ForEach([5, 15, 30], id: \.self) { minutes in Button("\(minutes) 分钟后") { center.snooze(item.id, minutes: minutes) } }
                            }.fixedSize()
                        }
                        if phase == .completed { Button("标记已查看") { center.see(task.id, attentionID: item.id) } }
                        if phase == .failed { Button("标记已处理") { center.handleFailure(item.id) } }
                    }
                }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(phase.actionable ? phase.color.opacity(0.25) : Color.primary.opacity(0.06), lineWidth: 1))
        .contextMenu {
            Button("复制会话 ID") { clipboardFeedback = ClipboardFeedback(text: task.sessionID, label: "会话 ID") }
            Button("重命名会话…") { monitor.promptRenameSession(key: task.path, current: task.title) }
        }
    }

    private var sourcesPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(center.sources) { source in
                    panel {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Text(source.id).font(.headline)
                                Text(source.status).font(.caption).foregroundColor(source.healthy ? .green : .secondary)
                                Spacer()
                                Toggle("启用", isOn: sourceBinding(source.id)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            }
                            Text(source.detail).font(.caption).foregroundColor(.secondary)
                            Text("\(source.count) 个会话记录 · 最近信号：\(source.lastSignal.map(relative) ?? "暂无")").font(.caption).foregroundColor(.secondary)
                            Text(source.root).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).textSelection(.enabled)
                            if ["Codex", "Claude", "IDE-CatPaw", "CatDesk"].contains(source.id) {
                                HStack {
                                    Button("选择数据目录…") { chooseDirectory(source.id) }
                                    Button("恢复默认目录") {
                                        preferences.value.sourcePaths.removeValue(forKey: pathKey(source.id))
                                        monitor.requestDiscovery(resetSources: true)
                                    }
                                }.controlSize(.small)
                            }
                        }
                    }
                }
                Text("未发现数据不等于没有安装；没有新事件也不等于断连。Hook 增强尚未启用，当前继续使用本地日志兼容监测。")
                    .font(.caption).foregroundColor(.secondary)
                Button("重新扫描") { monitor.requestDiscovery(); monitor.scanAndPoll() }
            }
        }
    }

    private var diagnosticsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                panel {
                    VStack(alignment: .leading, spacing: 10) {
                        diagnostic("最近扫描", center.lastScan.map(Self.time) ?? "尚未扫描")
                        diagnostic("扫描耗时", String(format: "%.0f ms", center.scanMilliseconds))
                        diagnostic("本地任务 / 处理记录", "\(center.tasks.count) / \(center.attentions.count)")
                        diagnostic("通知授权", center.permission)
                        diagnostic("数据保留", "\(preferences.value.retentionDays) 天 · 仅本应用数据")
                        diagnostic("存储状态", center.storageIssue == nil ? "本地持久化正常" : "存在存储提示")
                        HStack {
                            Button("刷新授权状态") { center.inspectPermission() }
                            Button("发送测试通知") { Notify.send(title: "任务中心测试 🐾", body: "这是一条用户主动发送的测试通知", sound: "") }
                            Button("打开通知设置") { openSystemNotificationSettings() }
                        }.controlSize(.small)
                    }
                }
                ForEach(center.sources) { source in
                    panel {
                        VStack(alignment: .leading, spacing: 5) {
                            diagnostic(source.id, source.status)
                            Text(source.detail).font(.caption).foregroundColor(.secondary)
                            Text("检查于 \(Self.time(source.checkedAt))").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
                Text("诊断信息仅保存在本机。Codex / CatDesk 支持会话链接直达，其他来源按当前能力返回。官方 Hook 尚未启用；没有新事件不会被视为来源断连。")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                settingGroup("提醒与声音") {
                    Toggle("待审批 / 待回答时通知", isOn: $preferences.value.notifyWaiting)
                    Toggle("执行失败时通知", isOn: $preferences.value.notifyFailure)
                    Toggle("本轮结束时通知（10 秒内合并，默认静音）", isOn: $preferences.value.notifyCompleted)
                    Toggle("为推测状态发送通知", isOn: $preferences.value.notifyInferred)
                    Toggle("重要提醒使用系统声音", isOn: $preferences.value.sound)
                    Toggle("在通知中显示任务标题（默认隐藏）", isOn: $preferences.value.revealTitles)
                    Toggle("启用每日静音时段", isOn: $preferences.value.quietEnabled)
                    if preferences.value.quietEnabled {
                        HStack {
                            Picker("开始", selection: $preferences.value.quietStart) { ForEach(0..<24) { Text(String(format: "%02d:00", $0)).tag($0 * 60) } }
                            Picker("结束", selection: $preferences.value.quietEnd) { ForEach(0..<24) { Text(String(format: "%02d:00", $0)).tag($0 * 60) } }
                        }.frame(maxWidth: 400)
                    }
                    HStack {
                        DatePicker("临时静音至", selection: $defaultMuteDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        Button("应用") { preferences.value.muteUntil = defaultMuteDate }
                        Button("恢复提醒") { preferences.value.muteUntil = nil }
                    }
                    Text("静音不会丢失待处理事项；声音通过系统通知投递，不自行播放绕过静音。").font(.caption).foregroundColor(.secondary)
                }
                settingGroup("按来源控制提醒") {
                    ForEach(SourceGroup.allCases) { group in
                        Toggle(group.rawValue, isOn: Binding(get: { !preferences.value.mutedSources.contains(group.rawValue) }, set: { on in
                            if on { preferences.value.mutedSources.remove(group.rawValue) } else { preferences.value.mutedSources.insert(group.rawValue) }
                        }))
                    }
                }
                settingGroup("网络与隐私") {
                    Toggle("联网获取 Credit 额度", isOn: $preferences.value.creditEnabled)
                    Toggle("同步 CatDesk 服务端标题", isOn: $preferences.value.titlesEnabled)
                    Toggle("自动检查应用更新", isOn: $preferences.value.updatesEnabled)
                    Toggle("允许从 Chrome 复用所需域的登录态", isOn: $preferences.value.chromeImport)
                    Text("仅额度登录失败时读取所需 SSO 域；关闭后不再导入，现有登录态保留。").font(.caption).foregroundColor(.secondary)
                    Toggle("发送可选匿名启动统计（默认关闭）", isOn: $preferences.value.telemetry)
                    Text("统计使用随机安装 ID，不发送账号、用户名、会话、路径或对话。").font(.caption).foregroundColor(.secondary)
                    Button("刷新 Credit 额度") { credit.refresh() }.disabled(!preferences.value.creditEnabled)
                }
                settingGroup("外观与启动") {
                    Picker("外观", selection: $theme) { Text("明亮").tag("light"); Text("暗黑").tag("dark") }.pickerStyle(.segmented).frame(width: 220)
                    Toggle("鼠标悬浮菜单栏时展开", isOn: $preferences.value.hoverMenu)
                    Toggle("显示桌宠", isOn: Binding(get: { PetController.shared.isEnabled }, set: { PetController.shared.setEnabled($0) }))
                    Toggle("开机启动", isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { want in
                        do { if want { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { center.navigationMessage = "开机启动设置失败：\(error.localizedDescription)" }
                    }))
                    Picker("保留本地记录", selection: $preferences.value.retentionDays) { Text("7 天").tag(7); Text("30 天").tag(30); Text("90 天").tag(90) }.frame(width: 240)
                    Text("仅清理已结束的本应用记录；未解决事项保留，不删除 Agent 来源文件。").font(.caption).foregroundColor(.secondary)
                    HStack {
                        Button("检查更新") { updater.check(manual: true) }.disabled(updater.checking)
                        if let version = updater.latestVersion {
                            Button("下载并安装 v\(version)") { updater.performUpdate() }.disabled(updater.updating)
                        }
                        Button("重新查看引导") { showOnboarding = true }
                    }
                    if let tip = updater.tip { Text(tip).font(.caption).foregroundColor(.secondary) }
                    Text("下载产物须通过签名身份与版本校验；本地临时签名构建无法自动替换为未验证的远端版本。").font(.caption).foregroundColor(.secondary)
                }
            }.font(.system(size: 12)).toggleStyle(.switch).controlSize(.small)
        }
    }

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                BrandMascotView(size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Agent哮天犬").font(.title3.bold())
                    Text("你的 Agent 任务监测伙伴").font(.callout).foregroundColor(.secondary)
                }
            }
            Text("让需要你处理的任务先被看见").font(.title2.bold())
            Text("自动读取本机会话，集中展示等待、失败和结果。已查看不等于已解决，打开窗口不会清空其他任务。").foregroundColor(.secondary)
            ForEach(center.sources.prefix(4)) { source in
                HStack { Text(source.id); Spacer(); Text(source.status).foregroundColor(source.healthy ? .green : .secondary) }
            }
            Divider()
            Button("允许系统通知") {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in center.inspectPermission() }
            }
            Text("可以跳过；应用内队列照常工作。额度登录、Hook 和终端权限都不阻塞基础监测。").font(.caption).foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("开始使用") { onboarded = true; showOnboarding = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(30).frame(width: 480)
    }

    private func showDetail(_ task: TaskRecord, item: AttentionRecord?) {
        detailAttentionID = item?.id
        center.see(task.id, attentionID: item?.id)
        center.selectedTaskID = task.id
        detailID = task.id
    }
    private func sourceBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { preferences.enabled(name) }, set: { on in
            if on { preferences.value.disabledSources.remove(name) } else { preferences.value.disabledSources.insert(name) }
            monitor.requestDiscovery()
        })
    }
    private func pathKey(_ source: String) -> String { ["IDE-CatPaw", "CatDesk"].contains(source) ? "CatPaw" : source }
    private func chooseDirectory(_ source: String) {
        let dialog = NSOpenPanel()
        dialog.canChooseDirectories = true
        dialog.canChooseFiles = false
        dialog.canCreateDirectories = false
        dialog.allowsMultipleSelection = false
        dialog.showsHiddenFiles = true
        dialog.message = pathKey(source) == "CatPaw" ? "选择 CatPaw 数据根目录（包含 projects 和 logs），插件与 CatDesk 共用此设置。" : "选择 \(source) 会话数据目录；只读取，不修改来源文件。"
        guard dialog.runModal() == .OK, let url = dialog.url else { return }
        preferences.value.sourcePaths[pathKey(source)] = url.path
        monitor.requestDiscovery(resetSources: true)
    }
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }
    private func settingGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox { VStack(alignment: .leading, spacing: 12, content: content).frame(maxWidth: .infinity, alignment: .leading).padding(10) } label: { Text(title).font(.headline) }
    }
    private func notice(_ text: String, icon: String, color: Color = .orange) -> some View {
        Label(text, systemImage: icon).font(.caption).foregroundColor(color).padding(10)
            .frame(maxWidth: .infinity, alignment: .leading).background(color.opacity(0.08)).cornerRadius(8)
    }
    private func diagnostic(_ title: String, _ value: String) -> some View { HStack { Text(title).foregroundColor(.secondary); Spacer(); Text(value).textSelection(.enabled) }.font(.caption) }
    private func metric(_ label: String, value: Int, color: Color) -> some View {
        HStack { Text("\(value)").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundColor(color); Text(label).font(.system(size: 11)).foregroundColor(.secondary); Spacer(minLength: 0) }
            .padding(12).frame(maxWidth: .infinity).background(color.opacity(0.07)).cornerRadius(9)
    }
    private func sectionTitle(_ title: String, count: Int) -> some View { HStack { Text(title).font(.system(size: 13, weight: .semibold)); Text("\(count)").font(.caption).foregroundColor(.secondary); Spacer() }.padding(.top, 8) }
    private func empty(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 12) { Image(systemName: icon).font(.title2).foregroundColor(.secondary); VStack(alignment: .leading, spacing: 5) { Text(title).font(.callout); Text(detail).font(.caption).foregroundColor(.secondary) }; Spacer() }
            .padding(18).frame(maxWidth: .infinity).background(Color.primary.opacity(0.025)).cornerRadius(10)
    }
    static func projectName(_ value: String) -> String { value.hasPrefix("/") ? URL(fileURLWithPath: value).lastPathComponent : value }
    private func projectLabel(_ value: String) -> String {
        let base = Self.projectName(value)
        let sameName = Set(center.tasks.map(\.project)).filter { Self.projectName($0) == base }
        guard sameName.count > 1, value.hasPrefix("/") else { return base }
        return base + " · " + URL(fileURLWithPath: value).deletingLastPathComponent().path
    }
    static func time(_ date: Date) -> String { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f.string(from: date) }
}

func relative(_ date: Date) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    if seconds < 60 { return "\(seconds) 秒前" }
    if seconds < 3600 { return "\(seconds / 60) 分钟前" }
    if seconds < 86400 { return "\(seconds / 3600) 小时前" }
    return "\(seconds / 86400) 天前"
}
private struct ClipboardFeedback {
    let succeeded: Bool
    let message: String

    @MainActor
    init(text: String, label: String) {
        succeeded = AppClipboard.write(text)
        message = succeeded ? "\(label) 已复制，可到其他应用粘贴。" : "复制失败，请重试。"
    }
}

private struct ClipboardFeedbackView: View {
    let feedback: ClipboardFeedback
    var body: some View {
        Label(feedback.message, systemImage: feedback.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundColor(feedback.succeeded ? .green : .red)
    }
}

struct TaskDetailView: View {
    @ObservedObject var center: TaskCenterStore
    let taskID: String
    let attentionID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var snoozeDate = Date().addingTimeInterval(900)
    @State private var clipboardFeedback: ClipboardFeedback?
    @State private var navigationFeedback: String?
    @State private var tab = "workflow"
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("任务详情").font(.title2.bold()); Spacer(); Button("完成") { center.selectedTaskID = nil; dismiss() }.keyboardShortcut(.cancelAction) }
            if let task = center.task(taskID) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(task.title).font(.headline).lineLimit(2).textSelection(.enabled)
                        Text("\(task.source) · \(TaskCenterView.projectName(task.project))").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Label(task.phase.label, systemImage: task.phase.symbol).font(.caption).foregroundColor(task.phase.color)
                }
                Picker("详情内容", selection: $tab) {
                    Text("执行工作流").tag("workflow")
                    Text("任务信息").tag("info")
                }.pickerStyle(.segmented).frame(width: 260)
                ScrollView {
                    if tab == "workflow" {
                        WorkflowDetailView(task: task, attentionRunID: center.attentions.first(where: { $0.id == attentionID })?.runID)
                    } else { taskInformation(task) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack {
                    Button("回到任务") {
                        center.recordReturn(task.id, attentionID: attentionID)
                        navigationFeedback = "正在打开来源…"
                        TaskNavigator.open(task) { message in
                            center.navigationMessage = message
                            navigationFeedback = message
                        }
                    }.help(TaskNavigator.returnDescription(for: task))
                    Button("复制会话 ID") { clipboardFeedback = ClipboardFeedback(text: task.sessionID, label: "会话 ID") }
                    if task.source == "Claude" {
                        Button("复制恢复命令") { clipboardFeedback = ClipboardFeedback(text: TaskNavigator.resumeCommand(task), label: "恢复命令") }
                    }
                }.buttonStyle(.bordered)
                if let clipboardFeedback { ClipboardFeedbackView(feedback: clipboardFeedback) }
                if let navigationFeedback { Text(navigationFeedback).font(.caption).foregroundColor(.secondary).textSelection(.enabled) }
                Text(TaskNavigator.returnDescription(for: task)).font(.caption).foregroundColor(.secondary)
            } else { Text("该任务的来源数据暂不可用。") }
        }.padding(24).frame(width: 880, height: 760)
    }

    private func taskInformation(_ task: TaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            info("来源", task.source)
            info("项目", task.project)
            info("会话", task.sessionID)
            info("回合边界", task.runIDInferred == true ? "本地推定；来源开始边界超出尾部读取范围" : task.runID)
            info("最近活动", TaskCenterView.time(task.activity))
            info("状态依据", task.evidence)
            if let item = center.attentions.first(where: { $0.id == attentionID }) {
                info("事项所属回合", item.runID)
                info("事项类型", item.phase.label)
                if let evidence = item.evidence { info("事项产生依据", evidence) }
                info("处理进度", item.resolvedAt != nil ? item.resolution ?? "已解决" : item.snoozedUntil != nil ? "已延后，尚未解决" : item.seenAt != nil ? "已查看，尚未解决" : "未查看")
                if item.resolvedAt == nil {
                    HStack {
                        DatePicker("稍后提醒", selection: $snoozeDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        Button("应用") { center.snoozeUntil(item.id, until: snoozeDate) }
                    }
                }
            }
            Text("回合结束只代表 Agent 结束了本轮响应；没有测试或人工验收证据时，不显示任务已验收。").font(.caption).foregroundColor(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(label).foregroundColor(.secondary).frame(width: 72, alignment: .leading); Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.font(.system(size: 12))
    }
}

struct CodexSnapshotView: View {
    let quota: CodexRateLimits?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Label("Codex 额度", systemImage: "bolt").font(.caption).foregroundColor(.secondary); Spacer(); Text(quota?.planType ?? "本地快照").font(.caption2).foregroundColor(.secondary) }
            if let q = quota {
                window(CodexRateLimits.windowLabel(minutes: q.primaryWindowMinutes), used: q.primaryUsedPercent, resets: q.primaryResetsAt, snapshot: q.snapshotAt)
                window(CodexRateLimits.windowLabel(minutes: q.secondaryWindowMinutes), used: q.secondaryUsedPercent, resets: q.secondaryResetsAt, snapshot: q.snapshotAt)
                Text(q.snapshotAt.map { "\(q.isStale(at: Date()) ? "数据可能已变化 · " : "")\(TaskCenterView.time($0))" } ?? "数据时间未知")
                    .font(.system(size: 9)).foregroundColor(q.isStale(at: Date()) ? .orange : .secondary)
            } else { Text("暂无快照 · 等待来源写入额度事件").font(.caption).foregroundColor(.secondary) }
            Text("账号范围未确认 · 不合并不同额度单位").font(.system(size: 9)).foregroundColor(.secondary)
        }
    }
    private func window(_ label: String, used: Double?, resets: Date?, snapshot: Date?) -> some View {
        let remaining = CodexRateLimits.remaining(used: used, resetsAt: resets, snapshotAt: snapshot, now: Date())
        return HStack {
            Text(label).font(.system(size: 10)).foregroundColor(.secondary).frame(width: 40, alignment: .leading)
            ProgressView(value: remaining ?? 0, total: 100).tint((remaining ?? 100) < 15 ? .orange : .blue)
            Text(remaining.map { "剩 \(Int($0))%" } ?? (used == nil ? "未知" : "待新快照"))
                .font(.system(size: 10, weight: .medium, design: .monospaced)).frame(width: 70, alignment: .trailing)
        }.help(resets.map { "重置时间：\(TaskCenterView.time($0))" } ?? "来源未提供重置时间")
    }
}
