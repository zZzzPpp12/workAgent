import AppKit
import XCTest
@testable import AgentNotifier

final class ClipboardTests: XCTestCase {
    func testSessionIDCopiesToPasteboardWithoutInternalSourcePrefix() async {
        await MainActor.run {
            let id = "01a16779-78aa-7a73-8b44-2480a215bb7f"
            let task = makeTask(id: "Codex:" + id)
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            XCTAssertTrue(AppClipboard.write(task.sessionID, to: board))
            XCTAssertEqual(board.string(forType: .string), id)
        }
    }

    func testRepeatedCopyReplacesOldContentsAndPreservesCommandText() async {
        await MainActor.run {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            XCTAssertTrue(AppClipboard.write("old value", to: board))
            let command = "cd '/tmp/中文项目' && claude --resume 'session:part-2'"
            XCTAssertTrue(AppClipboard.write(command, to: board))
            XCTAssertEqual(board.string(forType: .string), command)
        }
    }

    func testEmptyCopyReportsFailureAndKeepsExistingClipboard() async {
        await MainActor.run {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            XCTAssertTrue(AppClipboard.write("keep this", to: board))
            XCTAssertFalse(AppClipboard.write("", to: board))
            XCTAssertEqual(board.string(forType: .string), "keep this")
        }
    }

    func testSessionIDOnlyRemovesMatchingNamespaceAndPreservesRemainingColons() {
        XCTAssertEqual(makeTask(id: "Codex:session:part-2").sessionID, "session:part-2")
        XCTAssertEqual(makeTask(id: "session:part-2").sessionID, "session:part-2")
        XCTAssertEqual(makeTask(id: "Other:session").sessionID, "Other:session")
    }

    private func makeTask(id: String) -> TaskRecord {
        TaskRecord(id: id, source: "Codex", path: "/tmp/session.jsonl", title: "test", project: "/tmp/project", phase: .running,
                   runID: "r1", activity: .distantPast, observedAt: .distantPast, changedAt: .distantPast,
                   evidence: "test", readable: true, precise: true)
    }
}
