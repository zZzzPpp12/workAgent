import SwiftUI

struct WorkflowGraphView: View {
    let snapshot: WorkflowSnapshot
    let phase: TaskPhase
    @State private var selectedID: String?
    @State private var inspectedID: String?
    @State private var zoom: CGFloat = 1
    @State private var followsCurrent = true

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
            }.buttonStyle(.bordered).controlSize(.small)
            HStack {
                Label(snapshot.isPartial || !snapshot.hasExplicitStart ? "日志片段 · 连线按观测顺序" : "按观测顺序连接 · 不代表工具依赖", systemImage: "arrow.triangle.swap")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Spacer(minLength: 4)
                Toggle("跟随当前", isOn: $followsCurrent).toggleStyle(.checkbox).font(.system(size: 10))
            }
            GeometryReader { geometry in
                let layout = WorkflowGraphLayout(steps: snapshot.steps, width: geometry.size.width)
                ScrollViewReader { reader in
                    ScrollView([.horizontal, .vertical]) {
                        ZStack(alignment: .topLeading) {
                            graphBackground(layout)
                            VStack(spacing: 46) {
                                ForEach(0..<layout.rowCount, id: \.self) { row in
                                    HStack(spacing: 36) {
                                        ForEach(0..<layout.columns, id: \.self) { column in
                                            if let node = layout.node(row: row, column: column) {
                                                graphNode(node)
                                            } else {
                                                Color.clear.frame(width: layout.nodeSize.width, height: layout.nodeSize.height)
                                            }
                                        }
                                    }
                                }
                            }.padding(26)
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
                    .overlay(alignment: .bottomTrailing) {
                        Button {
                            selectedID = nil
                            followsCurrent = true
                            locateCurrent(reader)
                        } label: { Label("定位当前", systemImage: "scope") }
                        .buttonStyle(.bordered).controlSize(.small)
                        .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9)).padding(8)
                    }
                }
            }
            .frame(height: 310)
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
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                Image(systemName: step.kind.symbol).foregroundColor(color)
                Text(step.kind.label).foregroundColor(.secondary)
                Spacer(minLength: 0)
                Text(current ? "\(step.displayStatus(for: phase).pending ? "当前" : "最近") · \(number)" : String(format: "%02d", number))
                    .foregroundColor(current ? color : .secondary)
            }.font(.system(size: 10, weight: .medium))
            Text(step.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(step.statusLabel(for: phase)).foregroundColor(color)
                Spacer(minLength: 0)
                Text(WorkflowFormatting.time(step.startedAt ?? step.endedAt)).foregroundColor(.secondary).monospacedDigit()
            }.font(.system(size: 9))
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : current ? color.opacity(0.6) : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1))
        .shadow(color: selected ? Color.accentColor.opacity(0.1) : .black.opacity(0.025), radius: selected ? 7 : 3, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .help(step.title)
    }
}

struct WorkflowMiniGraphView: View {
    let snapshot: WorkflowSnapshot
    let phase: TaskPhase
    var body: some View {
        let steps = Array(snapshot.steps.suffix(3))
        HStack(spacing: 0) {
            ForEach(steps) { step in
                VStack(alignment: .leading, spacing: 6) {
                    Label(step.kind.label, systemImage: step.kind.symbol)
                        .font(.system(size: 10)).foregroundColor(.secondary)
                    Text(step.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Text(step.statusLabel(for: phase)).font(.system(size: 9)).foregroundColor(step.displayStatus(for: phase).color)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(10).frame(height: 72)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(step.displayStatus(for: phase).color.opacity(0.22)))
                if step.id != steps.last?.id {
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary).frame(width: 28)
                }
            }
        }
        .frame(height: 72)
        .overlay {
            GeometryReader { geometry in
                let count = steps.count
                let width = count > 0 ? (geometry.size.width - CGFloat(count - 1) * 28) / CGFloat(count) : 0
                let nodes = steps.enumerated().map { index, step in
                    WorkflowMotionNode(id: step.id,
                        frame: CGRect(x: CGFloat(index) * (width + 28), y: 0, width: width, height: geometry.size.height),
                        state: WorkflowMotionState(step: step, phase: phase))
                }
                WorkflowMotionLayer(nodes: nodes, edges: zip(nodes, nodes.dropFirst()).map { a, b in
                    WorkflowMotionEdge(targetID: b.id,
                        start: CGPoint(x: a.frame.maxX, y: a.frame.midY), end: CGPoint(x: b.frame.minX, y: b.frame.midY))
                })
            }
        }
        .accessibilityElement(children: .combine)
    }
}
