import XCTest
@testable import AgentNotifier

final class TaskNavigatorTests: XCTestCase {
    private let session = "01a16779-78aa-7a73-8b44-2480a215bb7f"

    func testCodexOpensSpecificThreadWithoutSendingPrompt() throws {
        let destination = try XCTUnwrap(TaskNavigator.sessionDestination(for: task("Codex", session)))
        XCTAssertEqual(destination.bundleID, "com.openai.codex")
        XCTAssertEqual(destination.url.absoluteString, "codex://threads/" + session)
        XCTAssertNil(URLComponents(url: destination.url, resolvingAgainstBaseURL: false)?.query)
    }

    func testLegacyRolloutIDStillTargetsItsThread() throws {
        let oldID = "rollout-2026-10-23T08-00-00-" + session
        let destination = try XCTUnwrap(TaskNavigator.sessionDestination(for: task("Codex", oldID)))
        XCTAssertEqual(destination.url.path, "/" + session)
    }

    func testInvalidCodexIDsCannotOpenAnotherRouteOrCreateThread() {
        for id in ["", "new", "../settings", session + "?prompt=run", "rollout-invalid"] {
            XCTAssertNil(TaskNavigator.sessionDestination(for: task("Codex", id)))
        }
    }

    func testCatDeskTargetsConversationWithNoAutoSendParameters() throws {
        let destination = try XCTUnwrap(TaskNavigator.sessionDestination(for: task("CatDesk", session)))
        XCTAssertEqual(destination.bundleID, "com.catpaw.cowork")
        let parts = try XCTUnwrap(URLComponents(url: destination.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.scheme, "catdesk")
        XCTAssertEqual(parts.host, "session")
        XCTAssertEqual(parts.path, "/open")
        XCTAssertEqual(parts.queryItems, [URLQueryItem(name: "conversationId", value: session)])
    }

    func testCatDeskIDIsOneEncodedParameterEvenWithReservedCharacters() throws {
        let id = "会话+part&prompt=hello?#/end"
        let destination = try XCTUnwrap(TaskNavigator.sessionDestination(for: task("CatDesk", id)))
        let parts = try XCTUnwrap(URLComponents(url: destination.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.queryItems, [URLQueryItem(name: "conversationId", value: id)])
        XCTAssertFalse(parts.percentEncodedQuery?.contains("+") ?? true)
        XCTAssertNil(parts.fragment)
    }

    func testInvalidCatDeskIDsAndUnsupportedSourcesUseFallback() {
        for id in ["", "id\ncontrol", String(repeating: "x", count: 513)] {
            XCTAssertNil(TaskNavigator.sessionDestination(for: task("CatDesk", id)))
        }
        for source in ["Claude", "IDE-CatPaw", "Trae", "DeepSeek", "unknown"] {
            let record = task(source, session)
            XCTAssertNil(TaskNavigator.sessionDestination(for: record))
            XCTAssertTrue(TaskNavigator.returnDescription(for: record).contains("暂不支持"))
        }
    }

    func testMenuPathReadsRealIDAndProjectFromLargeMetadataHead() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("rollout-unknown.jsonl")
        let payload: [String: Any] = ["type": "session_meta", "payload": ["id": session, "cwd": "/tmp/中文 项目", "instructions": String(repeating: "x", count: 20000)]]
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0a)
        try data.write(to: file)
        let record = TaskNavigator.taskForPath(source: "Codex", path: file.path)
        XCTAssertEqual(record.sessionID, session)
        XCTAssertEqual(record.project, "/tmp/中文 项目")
        XCTAssertEqual(TaskNavigator.sessionDestination(for: record)?.url.path, "/" + session)
    }

    func testMissingMenuLogCanRecoverCodexIDFromRolloutFilename() {
        let path = "/unavailable/rollout-2026-10-23T08-00-00-" + session + ".jsonl"
        let record = TaskNavigator.taskForPath(source: "Codex", path: path)
        XCTAssertEqual(TaskNavigator.sessionDestination(for: record)?.url.path, "/" + session)
    }

    func testCatPawTranscriptPathUsesSessionDirectoryInsteadOfTranscriptFilename() {
        let record = TaskNavigator.taskForPath(source: "IDE-CatPaw", path: "/tmp/ide-project/session-123/agent-transcripts/transcript.txt")
        XCTAssertEqual(record.sessionID, "session-123")
    }

    private func task(_ source: String, _ id: String) -> TaskRecord {
        TaskRecord(id: source + ":" + id, source: source, path: "/tmp/session.jsonl", title: "test", project: "/tmp/project", phase: .running,
                   runID: "r1", activity: .distantPast, observedAt: .distantPast, changedAt: .distantPast,
                   evidence: "test", readable: true, precise: true)
    }
}
