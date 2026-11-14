import XCTest
import CoreGraphics
import SwiftUI
import AppKit
@testable import AgentNotifier

final class IslandGeometryTests: XCTestCase {
    func testContentHeightForSingleAndMultipleRows() {
        XCTAssertEqual(IslandGeometry.contentHeight(itemCount: 0), 64)
        XCTAssertEqual(IslandGeometry.contentHeight(itemCount: 1), 64)
        XCTAssertEqual(IslandGeometry.contentHeight(itemCount: 1, toastCount: 1), 150)
        XCTAssertEqual(IslandGeometry.contentHeight(itemCount: 2), 150)
        XCTAssertEqual(IslandGeometry.contentHeight(itemCount: 10), IslandGeometry.contentHeight(itemCount: 4))
        // 4 条待办 + 1 条通知必须留出第 5 行，不能按 4 行截断。
        XCTAssertGreaterThan(
            IslandGeometry.contentHeight(itemCount: 4, toastCount: 1),
            IslandGeometry.contentHeight(itemCount: 4)
        )
    }

    func testPillFrameSitsBelowMenuBar() {
        let metrics = IslandScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875),
            safeAreaTop: 0
        )
        let frame = IslandGeometry.frame(metrics: metrics, notch: false, contentHeight: 64)
        XCTAssertEqual(frame.width, 440)
        XCTAssertEqual(frame.midX, 720)
        XCTAssertEqual(frame.maxY, 869, accuracy: 0.5)
    }

    func testNotchFrameIncludesSafeAreaAndTouchesTop() {
        let metrics = IslandScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 957),
            safeAreaTop: 32
        )
        let frame = IslandGeometry.frame(metrics: metrics, notch: true, contentHeight: 64)
        XCTAssertEqual(frame.height, 96)
        XCTAssertEqual(frame.maxY, 982)
        XCTAssertEqual(frame.midX, 756)
    }

    func testNotchRequiresPreferenceAndHardware() {
        let noNotch = IslandScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875),
            safeAreaTop: 0
        )
        XCTAssertFalse(IslandGeometry.usesNotch(metrics: noNotch, preference: true))

        let notch = IslandScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 957),
            safeAreaTop: 32
        )
        XCTAssertTrue(IslandGeometry.usesNotch(metrics: notch, preference: true))
        XCTAssertFalse(IslandGeometry.usesNotch(metrics: notch, preference: false))
    }

    func testNarrowScreenClampsWidth() {
        let metrics = IslandScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 320, height: 600),
            visibleFrame: CGRect(x: 0, y: 0, width: 320, height: 575),
            safeAreaTop: 0
        )
        let frame = IslandGeometry.frame(metrics: metrics, notch: false, contentHeight: 64)
        XCTAssertLessThanOrEqual(frame.width, 320)
        XCTAssertGreaterThanOrEqual(frame.width, 280)
    }
}

@MainActor
final class IslandStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func task(id: String, source: String) -> TaskRecord {
        TaskRecord(
            id: id, source: source, path: "", title: "标题", project: "", phase: .running,
            runID: "run", activity: now, observedAt: now, changedAt: now,
            evidence: "", readable: true, precise: true
        )
    }

    private func attention(id: String = UUID().uuidString, taskID: String, phase: TaskPhase) -> AttentionRecord {
        AttentionRecord(
            id: id, taskID: taskID, runID: "run", phase: phase,
            createdAt: now, deliveryAfter: now
        )
    }

    func testItemsDeduplicateByTaskAndHideTitles() {
        let tasks = [task(id: "Codex:a", source: "Codex"), task(id: "Claude:b", source: "Claude")]
        let attentions = [
            attention(taskID: "Codex:a", phase: .approval),
            attention(taskID: "Codex:a", phase: .input),
            attention(taskID: "Claude:b", phase: .failed)
        ]
        let items = IslandController.makeItems(from: attentions, tasks: tasks, revealTitles: false)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.taskID), ["Codex:a", "Claude:b"])
        XCTAssertTrue(items.allSatisfy { $0.title == "有任务需要处理" })
        XCTAssertEqual(items.last?.phase, .failed)
    }

    func testItemsShowTitleWhenEnabled() {
        let tasks = [task(id: "Codex:a", source: "Codex")]
        let items = IslandController.makeItems(
            from: [attention(taskID: "Codex:a", phase: .approval)],
            tasks: tasks,
            revealTitles: true
        )
        XCTAssertEqual(items.first?.title, "标题")
    }

    func testMissingTaskIsSkipped() {
        let items = IslandController.makeItems(
            from: [attention(taskID: "Codex:missing", phase: .failed)],
            tasks: [],
            revealTitles: true
        )
        XCTAssertTrue(items.isEmpty)
    }

    func testSignatureChangesWithToast() {
        let tasks = [task(id: "Codex:a", source: "Codex")]
        let items = IslandController.makeItems(
            from: [attention(taskID: "Codex:a", phase: .approval)],
            tasks: tasks,
            revealTitles: false
        )
        let toast = IslandToast(id: "toast-1", title: "标题", body: "内容", createdAt: now)
        XCTAssertEqual(IslandController.signature(items: items, toast: toast),
                       IslandController.signature(items: items, toast: toast))
        XCTAssertNotEqual(IslandController.signature(items: items, toast: nil),
                          IslandController.signature(items: items, toast: toast))
    }

    func testIslandViewRendersAtExpectedHeight() {
        let tasks = [task(id: "Codex:a", source: "Codex")]
        let items = IslandController.makeItems(
            from: [attention(taskID: "Codex:a", phase: .approval)],
            tasks: tasks,
            revealTitles: true
        )
        let view = IslandView(
            items: items, toast: nil, notch: false, topInset: 0,
            onOpen: { _ in }, onSnooze: { _, _ in }, onSeen: { _ in }, onHandled: { _ in },
            onDismissToast: {}, onDismiss: {}
        )
        let height = IslandGeometry.contentHeight(itemCount: items.count)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: IslandGeometry.width, height: height)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(host.fittingSize.height, height, accuracy: 4)
        let image = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        XCTAssertNotNil(image)
        if let image {
            host.cacheDisplay(in: host.bounds, to: image)
            XCTAssertGreaterThan(image.pixelsWide, 0)
        }
    }
}
