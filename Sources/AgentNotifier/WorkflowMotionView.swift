import SwiftUI

struct WorkflowMotionNode {
    let id: String
    let frame: CGRect
    let state: WorkflowMotionState
}

struct WorkflowMotionEdge {
    let targetID: String
    let start: CGPoint
    let end: CGPoint
}

/// 独立绘制装饰层：一份可见流程只使用一个动画时钟，不反复布局节点或读取日志。
struct WorkflowMotionLayer: View {
    let nodes: [WorkflowMotionNode]
    let edges: [WorkflowMotionEdge]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    private var enabled: Bool {
        visible && !reduceMotion && nodes.contains { $0.state != .still }
    }

    var body: some View {
        Color.clear.overlay {
            if enabled {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
                    Canvas { context, _ in
                        draw(in: &context, at: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
            }
        }
        .background(WorkflowMotionVisibilityProbe(visible: $visible))
        .onDisappear { visible = false }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, at time: TimeInterval) {
        let states = Dictionary(nodes.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        for node in nodes where node.state != .still {
            let waiting = node.state == .waiting
            let color: Color = waiting ? .orange : .blue
            let period: Double = waiting ? 3.2 : 1.5
            let pulse = (sin(time * 2 * .pi / period) + 1) / 2
            let rect = node.frame.insetBy(dx: 1.5, dy: 1.5)
            let outline = RoundedRectangle(cornerRadius: 12).path(in: rect)
            context.stroke(outline, with: .color(color.opacity(0.10 + pulse * 0.16)), lineWidth: 11)
            context.stroke(outline, with: .color(color.opacity(0.5 + pulse * 0.35)), lineWidth: waiting ? 2 : 2.4)

            // 运行中用短弧旋转，等待交互仅保留慢呼吸，不把等待画成正在推进。
            if !waiting {
                // 转圈位于卡片状态行的独立槽位内，不再画在 Canvas 边界外。
                let indicator = WorkflowGraphMetrics.indicatorFrame(in: node.frame)
                let center = CGPoint(x: indicator.midX, y: indicator.midY)
                let angle = time.truncatingRemainder(dividingBy: 1.1) / 1.1 * 360
                var arc = Path()
                arc.addArc(center: center, radius: 6.5, startAngle: .degrees(angle), endAngle: .degrees(angle + 260), clockwise: false)
                context.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))

                // 让高亮沿整张卡片边框移动，放大运行感但不遮住文字。
                let start = time.truncatingRemainder(dividingBy: 2.4) / 2.4
                var sweep = outline.trimmedPath(from: start, to: min(1, start + 0.24))
                if start + 0.24 > 1 { sweep.addPath(outline.trimmedPath(from: 0, to: start + 0.24 - 1)) }
                context.stroke(sweep, with: .color(.cyan.opacity(0.3)), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                context.stroke(sweep, with: .color(.cyan.opacity(0.95)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        }
        for edge in edges where states[edge.targetID] == .executing {
            var connection = Path()
            connection.move(to: edge.start); connection.addLine(to: edge.end)
            context.stroke(connection, with: .color(.cyan.opacity(0.85)),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [7, 7], dashPhase: -time.truncatingRemainder(dividingBy: 1) * 28))
            let progress = time.truncatingRemainder(dividingBy: 1.1) / 1.1
            let point = CGPoint(x: edge.start.x + (edge.end.x - edge.start.x) * progress,
                                y: edge.start.y + (edge.end.y - edge.start.y) * progress)
            let glow = Path(ellipseIn: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14))
            let core = Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
            context.fill(glow, with: .color(.blue.opacity(0.25)))
            context.fill(core, with: .color(.cyan))
        }
    }
}

/// 应用使用 AppKit 窗口，直接观察所属窗口的可见性，不依赖 SwiftUI Scene 生命周期。
private struct WorkflowMotionVisibilityProbe: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> VisibilityView { VisibilityView() }
    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onChange = { visible = $0 }
        view.refresh()
    }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            if let window {
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        self?.refresh()
                    })
                }
            }
            refresh()
        }

        func refresh() {
            let shown = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
            // AppKit 可能在 SwiftUI 更新过程中挂载探针，下一轮主线程再更新绑定。
            DispatchQueue.main.async { [weak self] in self?.onChange?(shown) }
        }

        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    }
}
