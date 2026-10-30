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
            let period: Double = waiting ? 3.2 : 1.8
            let pulse = (sin(time * 2 * .pi / period) + 1) / 2
            let rect = node.frame.insetBy(dx: -2, dy: -2)
            let outline = RoundedRectangle(cornerRadius: 12).path(in: rect)
            context.stroke(outline, with: .color(color.opacity(0.04 + pulse * 0.1)), lineWidth: 8)
            context.stroke(outline, with: .color(color.opacity(0.25 + pulse * 0.5)), lineWidth: 1.7)

            // 运行中用短弧旋转，等待交互仅保留慢呼吸，不把等待画成正在推进。
            if !waiting {
                let center = CGPoint(x: node.frame.minX - 3, y: node.frame.minY - 3)
                let angle = time.truncatingRemainder(dividingBy: 1.8) / 1.8 * 360
                var arc = Path()
                arc.addArc(center: center, radius: 5, startAngle: .degrees(angle), endAngle: .degrees(angle + 235), clockwise: false)
                // 弧线沿节点左上角外侧绘制，不遮挡节点文字和图标。
                context.stroke(arc, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
        for edge in edges where states[edge.targetID] == .executing {
            let progress = time.truncatingRemainder(dividingBy: 1.35) / 1.35
            let point = CGPoint(x: edge.start.x + (edge.end.x - edge.start.x) * progress,
                                y: edge.start.y + (edge.end.y - edge.start.y) * progress)
            let glow = Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
            let core = Path(ellipseIn: CGRect(x: point.x - 2.4, y: point.y - 2.4, width: 4.8, height: 4.8))
            context.fill(glow, with: .color(.blue.opacity(0.16)))
            context.fill(core, with: .color(.blue.opacity(0.95)))
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
