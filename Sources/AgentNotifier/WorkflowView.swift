import SwiftUI

extension WorkflowStepStatus {
    var color: Color {
        switch self {
        case .active: return .blue
        case .returned: return .green
        case .waiting: return .orange
        case .failed: return .red
        case .interrupted, .unconfirmed: return .secondary
        }
    }
}

enum WorkflowFormatting {
    static func duration(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        if seconds < 1 { return String(format: "%.1f 秒", seconds) }
        if seconds < 60 { return "\(Int(seconds)) 秒" }
        if seconds < 3600 { return "\(Int(seconds) / 60) 分 \(Int(seconds) % 60) 秒" }
        return "\(Int(seconds) / 3600) 小时 \(Int(seconds) % 3600 / 60) 分"
    }
    static func time(_ date: Date?) -> String {
        guard let date else { return "时间未提供" }
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

struct WorkflowCardView: View {
    let task: TaskRecord
    var onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text("\(task.source) · \(TaskCenterView.projectName(task.project))").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Label(task.phase.label, systemImage: task.phase.symbol).font(.caption).foregroundColor(task.phase.color)
            }
            if let flow = task.workflow, !flow.steps.isEmpty {
                WorkflowMiniGraphView(snapshot: flow, phase: task.phase)
                HStack {
                    Label(flow.activity(for: task.phase), systemImage: flow.currentStep?.kind.symbol ?? "waveform.path")
                        .font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text("已观测 \(flow.toolCount) 次工具 · \(flow.returnedTools) 次返回")
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                }
                if let current = flow.plan.first(where: { $0.status == .inProgress }) {
                    Label(current.title, systemImage: "list.bullet.clipboard").font(.caption).foregroundColor(.secondary).lineLimit(1)
                }

            } else {
                Text(task.readable ? "等待来源写入可识别的步骤事件。" : "来源暂不可读，保留最近状态。")
                    .font(.caption).foregroundColor(.secondary)
            }
            HStack {
                Text(task.workflow?.isPartial == true ? "最近节点预览 · 日志可能有缺失" : "最近节点预览 · 连线表示观测顺序").font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                Button("展开流程图", action: onOpen).buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(task.phase.color.opacity(0.18), lineWidth: 1))
    }
}

struct WorkflowDetailView: View {
    let task: TaskRecord
    let attentionRunID: String?
    var onExpandGraph: (() -> Void)? = nil
    @State private var newestFirst = true
    @State private var displayMode = "graph"
    @State private var planExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let flow = task.workflow, !flow.steps.isEmpty {
                if let expected = attentionRunID, let actual = flow.runID, expected != actual {
                    Label("当前展示最新回合；所选处理项属于其他回合，历史步骤尚未保留。", systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundColor(.orange)
                }
                if !task.readable {
                    Label("来源暂不可读，以下为上次观察到的工作流。", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundColor(.orange)
                }
                HStack(spacing: 22) {
                    summary(flow.isPartial ? "窗口内工具" : "工具调用", value: "\(flow.toolCount)")
                    summary("已返回", value: "\(flow.returnedTools)")
                    summary("明确失败", value: "\(flow.failedTools)")
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let end = flow.endedAt ?? (task.phase == .running ? context.date : nil)
                        summary("本轮耗时", value: flow.startedAt.flatMap { start in end.map { WorkflowFormatting.duration($0.timeIntervalSince(start)) } } ?? "—")
                    }
                }.padding(14).background(Color.primary.opacity(0.035)).cornerRadius(9)
                HStack {
                    Text("工作流视图").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Picker("工作流展示", selection: $displayMode) {
                        Text("流程图").tag("graph")
                        Text("时间线").tag("timeline")
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
                }
                if displayMode == "graph" {
                    WorkflowGraphView(snapshot: flow, phase: task.phase, onExpand: onExpandGraph)
                } else {
                    HStack {
                        Text("执行时间线").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Toggle("最近步骤优先", isOn: $newestFirst).toggleStyle(.checkbox).font(.system(size: 10))
                    }
                    Text(flow.isPartial || !flow.hasExplicitStart ? "可见日志片段 · 边界或步骤可能不完整" : "本轮可见步骤")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                    VStack(spacing: 0) {
                        let ordered = newestFirst ? Array(flow.steps.reversed()) : flow.steps
                        ForEach(ordered) { step in
                            WorkflowStepView(step: step, taskPhase: task.phase)
                            if step.id != ordered.last?.id { Divider().padding(.leading, 30) }
                        }
                    }
                }
                if !flow.plan.isEmpty {
                    DisclosureGroup(isExpanded: $planExpanded) {
                        plan(flow.plan).padding(.top, 8)
                    } label: {
                        Text("模型显式计划 · \(flow.plan.filter { $0.status == .completed }.count) / \(flow.plan.count) 步已标记完成")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                Text("只展示来源已记录的步骤；无时间戳时不补造耗时。工具已返回不代表任务已验收。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "point.topleft.down.curvedto.point.bottomright.up").font(.system(size: 34)).foregroundColor(.secondary)
                    Text("尚无可展示的工作流").font(.headline)
                    Text("来源写入回合与工具事件后会自动出现；可在任务信息中查看当前状态和判断依据。")
                        .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 65)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summary(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10)).foregroundColor(.secondary)
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }
    private func plan(_ steps: [WorkflowPlanStep]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("模型显式计划").font(.system(size: 13, weight: .semibold)); Spacer(); Text("\(steps.filter { $0.status == .completed }.count) / \(steps.count) 步已标记完成").font(.caption).foregroundColor(.secondary) }
            ForEach(steps) { step in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: step.status == .completed ? "checkmark.circle.fill" : step.status == .inProgress ? "circle.inset.filled" : "circle")
                        .foregroundColor(step.status == .completed ? .green : step.status == .inProgress ? .blue : .secondary)
                    Text(step.title).font(.system(size: 12)).textSelection(.enabled)
                    Spacer(minLength: 0)
                    if step.status == .inProgress { Text("当前步骤").font(.system(size: 10)).foregroundColor(.blue) }
                }
            }
        }.padding(14).background(Color.blue.opacity(0.045)).cornerRadius(9)
    }
}

struct WorkflowStepView: View {
    let step: WorkflowStep
    let taskPhase: TaskPhase

    private var label: String { step.statusLabel(for: taskPhase) }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: step.kind.symbol).font(.system(size: 12)).foregroundColor(step.displayStatus(for: taskPhase).color)
                .frame(width: 20, height: 24)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top) {
                    Text(step.title).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                    Spacer(minLength: 10)
                    Text(label).font(.system(size: 10)).foregroundColor(step.displayStatus(for: taskPhase).color)
                }
                HStack(spacing: 12) {
                    Text((step.startedAt == nil && step.endedAt != nil ? "返回于 " : "") + WorkflowFormatting.time(step.startedAt ?? step.endedAt)).monospacedDigit()
                    if let tool = step.tool { Text(tool).font(.system(size: 10, design: .monospaced)).lineLimit(1) }
                    Spacer(minLength: 0)
                    if let duration = step.duration {
                        Text(WorkflowFormatting.duration(duration)).monospacedDigit()
                    } else if step.status.pending, taskPhase == .running, let start = step.startedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text((step.kind == .model ? "距上次信号 " : "已等待 ") + WorkflowFormatting.duration(context.date.timeIntervalSince(start))).monospacedDigit()
                        }
                    }
                }.font(.system(size: 10)).foregroundColor(.secondary)
            }
        }.padding(.vertical, 12)
    }
}
