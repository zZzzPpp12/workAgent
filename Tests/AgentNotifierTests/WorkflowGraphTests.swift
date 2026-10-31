import XCTest
@testable import AgentNotifier

final class WorkflowGraphTests: XCTestCase {
    private func steps(_ count: Int) -> [WorkflowStep] {
        (0..<count).map {
            WorkflowStep(id: "step-\($0)", kind: .tool, title: "工具 \($0)", status: .returned,
                         startedAt: Date(timeIntervalSince1970: Double(count - $0)))
        }
    }

    func testBoundedLongFlowsFitCanvasWithoutOverlappingCards() {
        for width in [240.0, 420, 620, 832, 1400] {
            let layout = WorkflowGraphLayout(steps: steps(96), width: width)
            let canvas = CGRect(origin: .zero, size: layout.size)
            XCTAssertEqual(layout.nodes.count, 96)
            let rendered = (0..<layout.rowCount).flatMap { row in
                (0..<layout.columns).compactMap { layout.node(row: row, column: $0) }
            }
            XCTAssertEqual(rendered.count, 96)
            XCTAssertEqual(Set(rendered.map(\.id)), Set(layout.nodes.map(\.id)))
            for (i, node) in layout.nodes.enumerated() {
                XCTAssertTrue(canvas.contains(node.frame), "节点超出画布，宽度 \(width)")
                for other in layout.nodes.dropFirst(i + 1) {
                    XCTAssertFalse(node.frame.intersects(other.frame), "节点重叠")
                }
            }
        }
    }

    func testArrowsReachTargetBoundaryAndNeverCrossUnrelatedCards() throws {
        for width in [240.0, 620, 832] {
            let layout = WorkflowGraphLayout(steps: steps(16), width: width)
            XCTAssertEqual(layout.edges.count, 15)
            for edge in layout.edges {
                let target = try XCTUnwrap(layout.nodes.first { $0.id == edge.targetID })
                XCTAssertTrue(target.frame.insetBy(dx: -0.5, dy: -0.5).contains(edge.end))
                XCTAssertFalse(target.frame.insetBy(dx: 1, dy: 1).contains(edge.end))
                let others = layout.nodes.filter { $0.id != edge.sourceID && $0.id != edge.targetID }
                for fraction in stride(from: 0.0, through: 1.0, by: 0.1) {
                    let point = CGPoint(x: edge.start.x + (edge.end.x - edge.start.x) * fraction,
                                        y: edge.start.y + (edge.end.y - edge.start.y) * fraction)
                    XCTAssertFalse(others.contains { $0.frame.contains(point) }, "连线穿过无关节点")
                }
            }
        }
    }

    func testSpinnerAndGlowFitInsideBothPreviewAndFullCanvas() {
        for width in [240.0, 420, 620, 832, 1400] {
            let full = WorkflowGraphLayout(steps: steps(96), width: width)
            let preview = WorkflowMiniGraphLayout(stepCount: 96, width: width)
            let canvases = [(full.nodes.map(\.frame), full.size),
                            (preview.frames, CGSize(width: width, height: WorkflowMiniGraphLayout.height))]
            for (frames, size) in canvases {
                let canvas = CGRect(origin: .zero, size: size)
                for frame in frames {
                    XCTAssertTrue(frame.contains(WorkflowGraphMetrics.indicatorFrame(in: frame)), "转圈应位于卡片内部")
                    XCTAssertTrue(canvas.contains(frame.insetBy(dx: -WorkflowGraphMetrics.haloOutset, dy: -WorkflowGraphMetrics.haloOutset)), "光晕应保留在画布范围内")
                }
            }
        }
    }

    func testPreviewAdaptsNodeCountWithoutSquashingCards() {
        for width in [240.0, 420, 620, 832, 1400] {
            for count in [1, 2, 3, 96] {
                let layout = WorkflowMiniGraphLayout(stepCount: count, width: width)
                XCTAssertFalse(layout.frames.isEmpty)
                XCTAssertLessThanOrEqual(layout.frames.count, min(3, count))
                for (index, frame) in layout.frames.enumerated() {
                    XCTAssertGreaterThanOrEqual(frame.width, 200)
                    for other in layout.frames.dropFirst(index + 1) {
                        XCTAssertFalse(frame.insetBy(dx: -7, dy: -7).intersects(other.insetBy(dx: -7, dy: -7)))
                    }
                }
            }
        }
        XCTAssertLessThan(WorkflowMiniGraphLayout(stepCount: 96, width: 420).frames.count,
                          WorkflowMiniGraphLayout(stepCount: 96, width: 832).frames.count)
    }

    func testEmptyOrUnmeasuredPreviewDoesNotInventGeometry() {
        XCTAssertTrue(WorkflowMiniGraphLayout(stepCount: 0, width: 832).frames.isEmpty)
        for width in [0.0, 10, 24, 55] {
            XCTAssertTrue(WorkflowMiniGraphLayout(stepCount: 96, width: width).frames.isEmpty)
        }
    }

    func testGraphKeepsObservedOrderWhenTimestampsGoBackwardOrAreMissing() {
        var events = steps(7)
        events[2].startedAt = nil
        let layout = WorkflowGraphLayout(steps: events, width: 832)
        XCTAssertEqual(layout.nodes.map(\.id), events.map(\.id))
        XCTAssertEqual(layout.edges.map(\.sourceID), Array(events.dropLast()).map(\.id))
        XCTAssertEqual(layout.edges.map(\.targetID), Array(events.dropFirst()).map(\.id))
    }

    func testEmptyAndSingleNodeFlowNeverInventEdges() {
        for count in [0, 1] {
            let layout = WorkflowGraphLayout(steps: steps(count), width: 0)
            XCTAssertEqual(layout.nodes.count, count)
            XCTAssertTrue(layout.edges.isEmpty)
            XCTAssertGreaterThan(layout.size.height, 0)
        }
    }

    func testUnreadableOrEndedTaskDoesNotShowPendingToolAsStillRunning() {
        let step = WorkflowStep(id: "a", kind: .tool, title: "工具", status: .active)
        for phase in [TaskPhase.unknown, .idle, .completed, .failed, .stalled] {
            XCTAssertEqual(step.displayStatus(for: phase), .unconfirmed)
            XCTAssertEqual(step.statusLabel(for: phase), "待核实")
        }
        XCTAssertEqual(step.displayStatus(for: .running), .active)
        let question = WorkflowStep(id: "q", kind: .interaction, title: "问题", status: .waiting)
        XCTAssertEqual(question.displayStatus(for: .input), .waiting)
        XCTAssertEqual(question.displayStatus(for: .approval), .waiting)
    }

    func testObservedModelSignalAndToolReturnHaveDistinctLabels() {
        let model = WorkflowStep(id: "m", kind: .model, title: "模型处理", status: .returned)
        let tool = WorkflowStep(id: "t", kind: .tool, title: "工具", status: .returned)
        XCTAssertEqual(model.statusLabel(for: .running), "已观测")
        XCTAssertEqual(tool.statusLabel(for: .completed), "已返回")
        XCTAssertNil(model.duration)
    }

    func testExecutionMotionStopsForStaleUnreadableAndTerminalTasks() {
        let step = WorkflowStep(id: "active", kind: .tool, title: "工具", status: .active)
        XCTAssertEqual(WorkflowMotionState(step: step, phase: .running), .executing)
        for phase in [TaskPhase.unknown, .idle, .completed, .failed, .stopped, .stalled, .suspected] {
            XCTAssertEqual(WorkflowMotionState(step: step, phase: phase), .still)
        }
    }

    func testWaitingForUserNeverUsesForwardExecutionMotion() {
        let question = WorkflowStep(id: "q", kind: .interaction, title: "问题", status: .waiting)
        for phase in [TaskPhase.running, .approval, .input] {
            XCTAssertEqual(WorkflowMotionState(step: question, phase: phase), .waiting)
        }
        let pendingTool = WorkflowStep(id: "tool", kind: .tool, title: "工具", status: .active)
        XCTAssertEqual(WorkflowMotionState(step: pendingTool, phase: .approval), .waiting)
        XCTAssertEqual(WorkflowMotionState(step: pendingTool, phase: .input), .waiting)
        XCTAssertEqual(pendingTool.statusLabel(for: .approval), "等待审批")
        XCTAssertEqual(pendingTool.statusLabel(for: .input), "等待回答")
        XCTAssertEqual(pendingTool.displayStatus(for: .approval), .waiting)
        XCTAssertEqual(WorkflowMotionState(step: question, phase: .unknown), .still)
    }

    func testSettledNodesStayStaticWhileOtherStepsContinueRunning() {
        for status in [WorkflowStepStatus.returned, .failed, .interrupted, .unconfirmed] {
            let step = WorkflowStep(id: "settled", kind: .tool, title: "工具", status: status)
            for phase in [TaskPhase.running, .approval, .input] {
                XCTAssertEqual(WorkflowMotionState(step: step, phase: phase), .still)
            }
        }
    }

}
