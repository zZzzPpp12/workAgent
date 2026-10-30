import Foundation

enum WorkflowKind: String, Codable, CaseIterable {
    case start, model, tool, interaction, end
    var label: String {
        switch self {
        case .start: return "开始"
        case .model: return "模型处理"
        case .tool: return "工具执行"
        case .interaction: return "交互"
        case .end: return "结束"
        }
    }
    var symbol: String {
        switch self {
        case .start: return "play.circle"
        case .model: return "sparkles"
        case .tool: return "wrench.and.screwdriver"
        case .interaction: return "person.crop.circle.badge.questionmark"
        case .end: return "flag.checkered"
        }
    }
}

enum WorkflowStepStatus: String, Codable {
    case active, returned, waiting, failed, interrupted, unconfirmed
    var pending: Bool { self == .active || self == .waiting }
    var label: String {
        switch self {
        case .active: return "进行中"
        case .returned: return "已返回"
        case .waiting: return "等待回答"
        case .failed: return "失败"
        case .interrupted: return "已中断"
        case .unconfirmed: return "结果未观察到"
        }
    }
}

struct WorkflowStep: Codable, Equatable, Identifiable {
    var id: String
    var kind: WorkflowKind
    var title: String
    var tool: String?
    var status: WorkflowStepStatus
    var startedAt: Date?
    var endedAt: Date?
    var duration: TimeInterval? {
        // 模型事件只有观测时刻，不把相邻信号间隔冒充模型计算耗时。
        guard kind == .tool || kind == .interaction else { return nil }
        guard let startedAt, let endedAt, endedAt >= startedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }
}

struct WorkflowPlanStep: Codable, Equatable, Identifiable {
    enum Status: String, Codable { case pending, inProgress, completed }
    var id: String
    var title: String
    var status: Status
}

/// 只保存有界的执行元数据与显式计划，不保存推理、工具参数或工具输出。
struct WorkflowSnapshot: Codable, Equatable {
    var runID: String?
    var steps: [WorkflowStep]
    var plan: [WorkflowPlanStep]
    var isPartial: Bool
    var hasExplicitStart: Bool
    var roundStartedAt: Date?
    var toolCount: Int
    var returnedTools: Int
    var failedTools: Int

    var currentStep: WorkflowStep? {
        steps.last(where: { $0.status.pending }) ?? steps.last
    }
    var startedAt: Date? { roundStartedAt }
    var endedAt: Date? { steps.last(where: { $0.kind == .end })?.endedAt }

    func activity(for phase: TaskPhase) -> String {
        if ![.running, .approval, .input, .suspected, .stalled].contains(phase) { return phase.label }
        if phase == .approval || phase == .input { return phase.label }
        if let step = currentStep, step.status.pending { return step.title }
        return phase == .running ? "等待下一条执行事件" : phase.label
    }
}

/// 单个有界日志窗口内重建，扫描重放不累加副本。
struct WorkflowBuilder {
    var runID: String?
    var steps: [WorkflowStep] = []
    var plan: [WorkflowPlanStep] = []
    var hasExplicitStart = false
    var partial = false

    mutating func begin(_ id: String?, at date: Date?, explicit: Bool) {
        if explicit && hasExplicitStart && id != nil && id == runID { return }
        runID = id; steps = []; plan = []; hasExplicitStart = explicit
        if explicit { partial = false }
        if explicit { add(kind: .start, id: "start:" + (id ?? "visible"), title: "本轮开始", at: date, status: .returned) }
    }

    mutating func settleModel(at date: Date?) {
        for i in steps.indices where steps[i].kind == .model && steps[i].status == .active {
            steps[i].status = .returned; steps[i].endedAt = date
        }
    }

    mutating func add(kind: WorkflowKind, id: String, title: String, at date: Date?, status: WorkflowStepStatus = .active, tool: String? = nil) {
        guard !steps.contains(where: { $0.id == id }) else { return }
        settleModel(at: date)
        // 连续的模型处理信号合并，不逐 token 展开。
        if kind == .model, steps.last?.kind == .model {
            steps[steps.count - 1].status = .active
            steps[steps.count - 1].endedAt = nil
            return
        }
        steps.append(WorkflowStep(id: id, kind: kind, title: String(title.prefix(120)), tool: tool.map { String($0.prefix(100)) }, status: status, startedAt: date))
    }

    mutating func tool(_ id: String, name: String, at date: Date?, waiting: Bool) {
        add(kind: waiting ? .interaction : .tool, id: "tool:" + id, title: waiting ? "等待用户回答" : "执行 " + name,
            at: date, status: waiting ? .waiting : .active, tool: name)
    }

    mutating func result(_ id: String, name: String? = nil, at date: Date?, failed: Bool, answered: Bool = true, startedAt: Date? = nil) {
        if let i = steps.firstIndex(where: { $0.id == "tool:" + id }) {
            if steps[i].kind == .interaction && !answered && !failed { return }
            if steps[i].status != .failed { steps[i].status = failed ? .failed : .returned }
            steps[i].endedAt = date
            if let startedAt { steps[i].startedAt = startedAt }
        } else if let name {
            if startedAt == nil { partial = true }
            tool(id, name: name, at: startedAt, waiting: false)
            result(id, at: date, failed: failed)
        }
    }

    mutating func finish(at date: Date?, status: WorkflowStepStatus) {
        guard steps.last?.kind != .end else { return }
        settleModel(at: date)
        for i in steps.indices where steps[i].status.pending {
            steps[i].status = status == .interrupted ? .interrupted : .unconfirmed
            // 没有工具结果事件，不补造工具结束时间或成功结果。
        }
        add(kind: .end, id: "end:" + (runID ?? "visible"), title: status == .failed ? "本轮执行失败" : status == .interrupted ? "本轮已停止" : "本轮结束",
            at: date, status: status)
        steps[steps.count - 1].endedAt = date
    }

    func snapshot() -> WorkflowSnapshot {
        let toolSteps = steps.filter { $0.tool != nil }
        let pending = steps.filter { $0.status.pending }
        let tail = Array(steps.suffix(80))
        let extra = pending.filter { p in !tail.contains(where: { $0.id == p.id }) }.suffix(16)
        return WorkflowSnapshot(runID: runID, steps: Array(extra) + tail, plan: plan,
            isPartial: partial || steps.count > 80, hasExplicitStart: hasExplicitStart,
            roundStartedAt: steps.first(where: { $0.kind == .start })?.startedAt,
            toolCount: toolSteps.count, returnedTools: toolSteps.filter { $0.status == .returned }.count,
            failedTools: toolSteps.filter { $0.status == .failed }.count)
    }
}
