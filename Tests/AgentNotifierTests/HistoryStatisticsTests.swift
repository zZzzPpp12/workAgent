import XCTest
@testable import AgentNotifier

final class HistoryStatisticsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func run(_ id: String, task: String, from: Date, to: Date, partial: Bool = false) -> HistoricalRun {
        let wait = WorkflowStep(id: "tool:q", kind: .interaction, title: "等待用户回答", status: .returned, startedAt: from, endedAt: to)
        let end = WorkflowStep(id: "end", kind: .end, title: "本轮结束", status: .returned, startedAt: to, endedAt: to)
        let snapshot = WorkflowSnapshot(runID: id, steps: [wait, end], plan: [], isPartial: partial,
                                        hasExplicitStart: true, roundStartedAt: from, toolCount: 1, returnedTools: 1, failedTools: 0)
        return HistoricalRun(id: id, taskID: task, source: "Codex", project: "/tmp/p", title: "任务", snapshot: snapshot, observedAt: to, imported: false)
    }

    private func attention(_ task: String, run: String, snoozes: [SnoozeInterval], complete: Bool = true) -> AttentionRecord {
        AttentionRecord(id: task, taskID: task, runID: run, phase: .input, createdAt: start,
                        deliveryAfter: start, requestKey: "q", snoozeHistory: snoozes, snoozeHistoryComplete: complete)
    }

    func testOverlappingWaitsDistinguishCumulativeCalendarAndDeferredTime() {
        let first = run("r1", task: "Codex:a", from: start, to: start.addingTimeInterval(600))
        let second = run("r2", task: "Codex:b", from: start.addingTimeInterval(300), to: start.addingTimeInterval(900))
        let snooze = SnoozeInterval(startedAt: start.addingTimeInterval(120), scheduledUntil: start.addingTimeInterval(240), endedAt: start.addingTimeInterval(240))
        let filter = HistoryFilter(interval: DateInterval(start: start, duration: 1800))
        let summary = HistoryStatistics.summarize(runs: [first, second], attentions: [attention("Codex:a", run: "r1", snoozes: [snooze]), attention("Codex:b", run: "r2", snoozes: [])], filter: filter)
        XCTAssertEqual(summary.completed, 2)
        XCTAssertEqual(summary.waits, 2)
        XCTAssertEqual(summary.waitSeconds, 1200)
        XCTAssertEqual(summary.calendarWaitSeconds, 900)
        XCTAssertEqual(summary.matchedWaits, 2)
        XCTAssertEqual(summary.deferredSeconds, 120)
        XCTAssertEqual(summary.nonDeferredSeconds, 1080)
    }

    func testPartialOldAttentionDoesNotPretendNoSnoozeHappened() {
        let row = run("r1", task: "Codex:a", from: start, to: start.addingTimeInterval(600), partial: true)
        let filter = HistoryFilter(interval: DateInterval(start: start, duration: 1800))
        let summary = HistoryStatistics.summarize(runs: [row], attentions: [attention("Codex:a", run: "r1", snoozes: [], complete: false)], filter: filter)
        XCTAssertEqual(summary.waitSeconds, 600)
        XCTAssertEqual(summary.matchedWaits, 0)
        XCTAssertEqual(summary.partial, 1)
    }

    func testIntervalsClipAtDateBoundariesAndSourcesFilterIndependently() {
        let row = run("r1", task: "Codex:a", from: start, to: start.addingTimeInterval(600))
        let interval = DateInterval(start: start.addingTimeInterval(300), duration: 120)
        let summary = HistoryStatistics.summarize(runs: [row], attentions: [], filter: HistoryFilter(interval: interval, source: "Codex"))
        XCTAssertEqual(summary.waitSeconds, 120)
        XCTAssertEqual(summary.calendarWaitSeconds, 120)
        XCTAssertEqual(summary.completed, 0)
        XCTAssertEqual(HistoryStatistics.summarize(runs: [row], attentions: [], filter: HistoryFilter(interval: interval, source: "Claude")).waits, 0)
    }
}
