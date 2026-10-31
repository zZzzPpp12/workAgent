import SwiftUI

struct WorkflowGraphView: View {
    let snapshot: WorkflowSnapshot
    let phase: TaskPhase
    var fillsAvailableSpace = false
    var onExpand: (() -> Void)? = nil
    @State private var selectedID: String?
    @State private var inspectedID: String?
    @State private var zoom: CGFloat = 1
    @State private var followsCurrent = true
    @State private var locationRequest = 0

    private var selected: WorkflowStep? {
        snapshot.steps.first { $0.id == selectedID } ?? snapshot.currentStep
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("执行流程图").font(.system(size: 13, weight: .semibold))
                Text("\(snapshot.steps.count) 个节点").font(.caption).foregroundColor(.secondary)
                Spacer(minLength: 4)
                Button { zoom = max(0.65, zoom - 0.15) } label: { Image(systemName: "minus.magnifyingglass") }
                    .disabled(zoom <= 0.65).accessibilityLabel("缩小流程图")
                Text("\(Int((zoom * 100).rounded()))%").font(.system(size: 10, design: .monospaced)).frame(width: 36)
                Button { zoom = min(1.75, zoom + 0.15) } label: { Image(systemName: "plus.magnifyingglass") }
                    .disabled(zoom >= 1.75).accessibilityLabel("放大流程图")
                Button("适合宽度") { zoom = 1 }
                if let onExpand {
                    Button(action: onExpand) { Label("放大查看", systemImage: "arrow.up.left.and.arrow.down.right") }
                }
            }.buttonStyle(.bordered).controlSize(.small)
            HStack {
                Label(snapshot.isPartial || !snapshot.hasExplicitStart ? "日志片段 · 连线按观测顺序" : "按观测顺序连接 · 不代表工具依赖", systemImage: "arrow.triangle.swap")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Spacer(minLength: 4)
                Toggle("跟随当前", isOn: $followsCurrent).toggleStyle(.checkbox).font(.system(size: 10))
                Button {
                    selectedID = nil
                    followsCurrent = true
                    locationRequest += 1
                } label: { Label("定位当前", systemImage: "scope") }
                .buttonStyle(.bordered).controlSize(.small)
            }
            GeometryReader { geometry in
                let layout = WorkflowGraphLayout(steps: snapshot.steps, width: geometry.size.width)
                ScrollViewReader { reader in
                    ScrollView([.horizontal, .vertical]) {
                        ZStack(alignment: .topLeading) {
                            graphBackground(layout)
                            VStack(spacing: WorkflowGraphMetrics.rowGap) {
                                ForEach(0..<layout.rowCount, id: \.self) { row in
                                    HStack(spacing: WorkflowGraphMetrics.columnGap) {
                                        ForEach(0..<layout.columns, id: \.self) { column in
                                            if let node = layout.node(row: row, column: column) {
                                                graphNode(node)
                                            } else {
                                                Color.clear.frame(width: layout.nodeSize.width, height: layout.nodeSize.height)
                                            }
                                        }
                                    }
                                }
                            }.padding(WorkflowGraphMetrics.canvasInset)
                        }
                        .frame(width: layout.size.width, height: layout.size.height)
                        .overlay {
                            WorkflowMotionLayer(
                                nodes: layout.nodes.map { node in
                                    WorkflowMotionNode(id: node.id, frame: node.frame,
                                        state: WorkflowMotionState(step: snapshot.steps[node.index], phase: phase))
                                },
                                edges: layout.edges.map { WorkflowMotionEdge(targetID: $0.targetID, start: $0.start, end: $0.end) })
                        }
                        .scaleEffect(zoom, anchor: .topLeading)
                        .frame(width: layout.size.width * zoom, height: layout.size.height * zoom, alignment: .topLeading)
                    }
                    .onAppear { locateCurrent(reader) }
                    .onChange(of: snapshot.currentStep?.id) { _ in if followsCurrent { locateCurrent(reader) } }
                    .onChange(of: followsCurrent) { follow in
                        if follow { selectedID = nil; locateCurrent(reader) }
                    }
                    .onChange(of: snapshot.runID) { _ in selectedID = nil; inspectedID = nil; followsCurrent = true; locateCurrent(reader) }
                    .onChange(of: zoom) { _ in if followsCurrent { locateCurrent(reader) } }
                    .onChange(of: geometry.size.width) { _ in if followsCurrent { locateCurrent(reader) } }
                    .onChange(of: locationRequest) { _ in locateCurrent(reader) }
                }
            }
            .frame(minHeight: fillsAvailableSpace ? 280 : 440, idealHeight: 440,
                   maxHeight: fillsAvailableSpace ? .infinity : 440)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.08)))
            Text("点击节点查看详情；滚动浏览长流程，放大后可横向移动。虚线表示当前日志可能存在缺失。")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private func graphNode(_ node: WorkflowGraphLayout.Node) -> some View {
        let step = snapshot.steps[node.index]
        return Button {
            selectedID = step.id
            inspectedID = step.id
            followsCurrent = false
        } label: {
            WorkflowGraphNodeView(step: step, phase: phase, number: node.index + 1,
                selected: selected?.id == step.id, current: snapshot.currentStep?.id == step.id)
                .frame(width: node.frame.width, height: node.frame.height)
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(get: { inspectedID == step.id }, set: { if !$0 { inspectedID = nil } })) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("节点 \(node.index + 1) · \(step.kind.label)").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button("关闭") { inspectedID = nil }.controlSize(.small)
                }
                WorkflowStepView(step: step, taskPhase: phase)
            }.padding(16).frame(width: 380)
        }
        .frame(width: node.frame.width, height: node.frame.height)
        .id(node.id)
        .accessibilityLabel("节点 \(node.index + 1)，\(step.title)，\(step.statusLabel(for: phase))")
    }

    private func locateCurrent(_ reader: ScrollViewProxy) {
        guard let id = snapshot.currentStep?.id else { return }
        // 等待新节点参与布局，避免日志追加后定位到上一次的坐标。
        DispatchQueue.main.async { reader.scrollTo(id, anchor: .center) }
    }

    private func graphBackground(_ layout: WorkflowGraphLayout) -> some View {
        Canvas { context, size in
            var dots = Path()
            for x in stride(from: CGFloat(10), to: size.width, by: 20) {
                for y in stride(from: CGFloat(10), to: size.height, by: 20) {
                    dots.addEllipse(in: CGRect(x: x, y: y, width: 1.5, height: 1.5))
                }
            }
            context.fill(dots, with: .color(.secondary.opacity(0.14)))
            for edge in layout.edges {
                let target = snapshot.steps.first { $0.id == edge.targetID }
                let status = target?.displayStatus(for: phase)
                let highlighted = status?.pending == true || status == .failed
                let color: Color = highlighted ? (status?.color ?? .secondary) : .secondary.opacity(0.5)
                var line = Path(); line.move(to: edge.start); line.addLine(to: edge.end)
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: highlighted ? 2 : 1.5, lineCap: .round, dash: snapshot.isPartial || !snapshot.hasExplicitStart ? [4, 4] : []))
                let angle = atan2(edge.end.y - edge.start.y, edge.end.x - edge.start.x)
                var arrow = Path(); arrow.move(to: edge.end)
                arrow.addLine(to: CGPoint(x: edge.end.x - 7 * cos(angle - .pi / 6), y: edge.end.y - 7 * sin(angle - .pi / 6)))
                arrow.addLine(to: CGPoint(x: edge.end.x - 7 * cos(angle + .pi / 6), y: edge.end.y - 7 * sin(angle + .pi / 6)))
                arrow.closeSubpath(); context.fill(arrow, with: .color(color))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct WorkflowGraphNodeView: View {
    let step: WorkflowStep
    let phase: TaskPhase
    let number: Int
    let selected: Bool
    let current: Bool
    private var color: Color { step.displayStatus(for: phase).color }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: step.kind.symbol).foregroundColor(color)
                Text(step.kind.label).foregroundColor(.secondary)
                Spacer(minLength: 0)
                Text(current ? "\(step.displayStatus(for: phase).pending ? "当前" : "最近") · \(number)" : String(format: "%02d", number))
                    .foregroundColor(current ? color : .secondary)
            }.font(.system(size: 11, weight: .medium))
            Text(step.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                WorkflowActivityIndicator(state: WorkflowMotionState(step: step, phase: phase), color: color)
                Text(step.statusLabel(for: phase)).foregroundColor(color)
                Spacer(minLength: 0)
                Text(WorkflowFormatting.time(step.startedAt ?? step.endedAt)).foregroundColor(.secondary).monospacedDigit()
            }.font(.system(size: 10, weight: .medium)).frame(height: WorkflowGraphMetrics.indicatorSize)
        }
        .padding(WorkflowGraphMetrics.contentInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 10).fill(color.opacity(current ? 0.06 : 0))
        }
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : current ? color.opacity(0.6) : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1))
        .shadow(color: selected ? Color.accentColor.opacity(0.1) : .black.opacity(0.025), radius: selected ? 7 : 3, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .help(step.title)
    }
}

private struct WorkflowActivityIndicator: View {
    let state: WorkflowMotionState
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if state == .executing {
                Circle().stroke(color.opacity(0.22), lineWidth: 2).padding(2.5)
                if reduceMotion { Circle().fill(color).frame(width: 5, height: 5) }
            } else if state == .waiting {
                Image(systemName: "pause.fill").font(.system(size: 9, weight: .bold)).foregroundColor(color)
            } else {
                Circle().fill(color).frame(width: 5, height: 5)
            }
        }.frame(width: WorkflowGraphMetrics.indicatorSize, height: WorkflowGraphMetrics.indicatorSize)
    }
}

struct WorkflowMiniGraphView: View {
    let snapshot: WorkflowSnapshot
    let phase: TaskPhase
    var body: some View {
        GeometryReader { geometry in
            let layout = WorkflowMiniGraphLayout(stepCount: snapshot.steps.count, width: geometry.size.width)
            let steps = Array(snapshot.steps.suffix(layout.frames.count))
            let nodes = steps.enumerated().map { index, step in
                WorkflowMotionNode(id: step.id, frame: layout.frames[index],
                    state: WorkflowMotionState(step: step, phase: phase))
            }
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(steps) { step in
                        let index = steps.firstIndex(where: { $0.id == step.id }) ?? 0
                        WorkflowGraphNodeView(step: step, phase: phase,
                            number: snapshot.steps.count - steps.count + index + 1,
                            selected: false, current: snapshot.currentStep?.id == step.id)
                            .frame(width: layout.frames[index].width, height: WorkflowGraphMetrics.nodeHeight)
                        if step.id != steps.last?.id {
                            Image(systemName: "arrow.right").font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.secondary).frame(width: WorkflowGraphMetrics.miniGap)
                        }
                    }
                }.padding(WorkflowGraphMetrics.miniInset)
                WorkflowMotionLayer(nodes: nodes, edges: zip(nodes, nodes.dropFirst()).map { a, b in
                    WorkflowMotionEdge(targetID: b.id,
                        start: CGPoint(x: a.frame.maxX, y: a.frame.midY), end: CGPoint(x: b.frame.minX, y: b.frame.midY))
                })
            }.frame(width: geometry.size.width, height: WorkflowMiniGraphLayout.height)
        }.frame(height: WorkflowMiniGraphLayout.height)
        .accessibilityElement(children: .combine)
    }
}
