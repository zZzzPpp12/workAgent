import Foundation

/// 连线仅表达快照中的观测顺序，不从时间戳或工具名称推断依赖与并行关系。
struct WorkflowGraphLayout {
    struct Node: Identifiable {
        let id: String
        let index: Int
        let frame: CGRect
    }
    struct Edge {
        let sourceID: String
        let targetID: String
        let start: CGPoint
        let end: CGPoint
    }
    let columns: Int
    var rowCount: Int { (nodes.count + columns - 1) / columns }
    var nodeSize: CGSize { nodes.first?.frame.size ?? CGSize(width: 190, height: 100) }
    func node(row: Int, column: Int) -> Node? {
        let index = row * columns + (row.isMultiple(of: 2) ? column : columns - 1 - column)
        return nodes.indices.contains(index) ? nodes[index] : nil
    }
    let nodes: [Node]
    let edges: [Edge]
    let size: CGSize

    init(steps: [WorkflowStep], width: CGFloat) {
        let width = max(240, width)
        let inset: CGFloat = 26
        let gap: CGFloat = 36
        let height: CGFloat = 100
        let rowGap: CGFloat = 46
        let columns = max(1, min(3, Int((width - inset * 2 + gap) / (190 + gap))))
        self.columns = columns
        let nodeWidth = (width - inset * 2 - CGFloat(columns - 1) * gap) / CGFloat(columns)
        nodes = steps.enumerated().map { index, step in
            let row = index / columns
            let column = row.isMultiple(of: 2) ? index % columns : columns - 1 - index % columns
            return Node(id: step.id, index: index,
                frame: CGRect(x: inset + CGFloat(column) * (nodeWidth + gap),
                              y: inset + CGFloat(row) * (height + rowGap), width: nodeWidth, height: height))
        }
        edges = zip(nodes, nodes.dropFirst()).map { source, target in
            let a = source.frame, b = target.frame
            if a.minY != b.minY {
                return Edge(sourceID: source.id, targetID: target.id,
                    start: CGPoint(x: a.midX, y: a.maxY), end: CGPoint(x: b.midX, y: b.minY))
            }
            let forward = a.minX < b.minX
            return Edge(sourceID: source.id, targetID: target.id,
                start: CGPoint(x: forward ? a.maxX : a.minX, y: a.midY),
                end: CGPoint(x: forward ? b.minX : b.maxX, y: b.midY))
        }
        let rows = (steps.count + columns - 1) / columns
        size = CGSize(width: width, height: max(160, inset * 2 + CGFloat(rows) * height + CGFloat(max(0, rows - 1)) * rowGap))
    }
}

extension WorkflowStep {
    func displayStatus(for phase: TaskPhase) -> WorkflowStepStatus {
        guard status.pending else { return status }
        if phase == .approval || phase == .input { return .waiting }
        return phase == .running ? status : .unconfirmed
    }

    func statusLabel(for phase: TaskPhase) -> String {
        if status.pending && displayStatus(for: phase) == .unconfirmed { return "待核实" }
        if status.pending && phase == .approval { return "等待审批" }
        if status.pending && phase == .input { return "等待回答" }
        if status == .returned {
            switch kind {
            case .start: return "已开始"
            case .end: return "已结束"
            case .model: return "已观测"
            default: break
            }
        }
        return status.label
    }
}

/// 动效只表达仍能确认的活动状态；等待交互不绘制向前流动的光点。
enum WorkflowMotionState: Equatable {
    case still, executing, waiting

    init(step: WorkflowStep, phase: TaskPhase) {
        guard step.status.pending, [.running, .approval, .input].contains(phase) else {
            self = .still
            return
        }
        self = step.status == .waiting || phase == .approval || phase == .input ? .waiting : .executing
    }
}
