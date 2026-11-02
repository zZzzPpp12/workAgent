import XCTest
@testable import AgentNotifier

final class HistoryStoreTests: XCTestCase {
    private var directory: URL!
    private var file: URL!
    private var store: HistoryStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HakimiHistory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("session.jsonl")
        try Data().write(to: file)
        store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"), now: Date().addingTimeInterval(60))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func observation() -> TaskObservation {
        TaskObservation(id: "Codex:s1", source: "Codex", path: file.path, title: "会话", project: "/tmp/p",
                        phase: .running, runID: nil, activity: Date(), evidence: "测试")
    }

    private func append(_ lines: [String]) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private func event(_ type: String, _ turn: String, _ second: String) -> String {
        #"{"type":"event_msg","timestamp":"2026-11-02T00:00:"# + second + #"Z","payload":{"type":""# + type + #"","turn_id":""# + turn + #""}}"#
    }

    func testOnlyNewRoundsAreCollectedAndSeveralRoundsInOneBatchAreKept() throws {
        try append([event("task_started", "old", "00"), event("task_complete", "old", "01")])
        _ = try store.collect(observation()) // existing file is baselined, not imported
        XCTAssertTrue(try store.records().runs.isEmpty)
        try append([event("task_started", "r1", "02"), event("task_complete", "r1", "03"),
                    event("task_started", "r2", "04"), event("task_complete", "r2", "05")])
        _ = try store.collect(observation())
        let rows = try store.records().runs
        XCTAssertEqual(Set(rows.compactMap { $0.snapshot.runID }), Set(["r1", "r2"]))
        XCTAssertTrue(rows.allSatisfy { $0.status == .completed })
        _ = try store.collect(observation())
        XCTAssertEqual(try store.records().runs.count, 2)
    }

    func testExplicitBackfillUsesIndependentCursorAndDoesNotDuplicateReplays() throws {
        try append([event("task_started", "old", "00"), event("task_complete", "old", "01")])
        _ = try store.collect(observation())
        _ = try store.collect(observation(), backfill: true)
        XCTAssertEqual(try store.records().runs.map { $0.snapshot.runID }, ["old"])
        try store.resetBackfill(for: [observation()])
        _ = try store.collect(observation(), backfill: true)
        XCTAssertEqual(try store.records().runs.count, 1)
    }

    func testHistoryNeverPersistsRawArgumentsOrPlanText() throws {
        _ = try store.collect(observation())
        try append([event("task_started", "r1", "00"),
            #"{"timestamp":"2026-11-02T00:00:01Z","payload":{"type":"function_call","call_id":"a","name":"exec","arguments":"PRIVATE_COMMAND"}}"#,
            #"{"timestamp":"2026-11-02T00:00:02Z","payload":{"type":"function_call","call_id":"p","name":"update_plan","arguments":"{\"plan\":[{\"step\":\"PRIVATE_PLAN\",\"status\":\"pending\"}]}"}}"#,
            #"{"timestamp":"2026-11-02T00:00:03Z","payload":{"type":"function_call_output","call_id":"a","output":"PRIVATE_OUTPUT"}}"#])
        _ = try store.collect(observation())
        let database = try Data(contentsOf: directory.appendingPathComponent("history.sqlite"))
        for secret in ["PRIVATE_COMMAND", "PRIVATE_PLAN", "PRIVATE_OUTPUT"] {
            XCTAssertNil(database.range(of: Data(secret.utf8)))
        }
    }

    func testIncompleteLineIsReadOnlyAfterItIsFinished() throws {
        _ = try store.collect(observation())
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        let line = event("task_started", "r1", "01")
        let bytes = Array(line.utf8)
        try handle.write(contentsOf: Data(bytes.prefix(bytes.count / 2)))
        _ = try store.collect(observation())
        XCTAssertTrue(try store.records().runs.isEmpty)
        try handle.write(contentsOf: Data(bytes.dropFirst(bytes.count / 2)) + Data("\n".utf8))
        try handle.close()
        _ = try store.collect(observation())
        XCTAssertEqual(try store.records().runs.first?.snapshot.runID, "r1")
    }

    func testLateEventUpdatesItsOwnRoundWithoutEndingTheNewRound() throws {
        _ = try store.collect(observation())
        try append([event("task_started", "r1", "01"), event("task_started", "r2", "02"),
                    event("task_complete", "r1", "03")])
        _ = try store.collect(observation())
        let rows = try store.records().runs
        XCTAssertEqual(rows.first { $0.snapshot.runID == "r1" }?.status, .completed)
        XCTAssertEqual(rows.first { $0.snapshot.runID == "r2" }?.status, .running)
    }

    func testClearDoesNotReimportTruncatedSource() throws {
        _ = try store.collect(observation())
        try append([event("task_started", "r1", "01"), event("task_complete", "r1", "02")])
        _ = try store.collect(observation())
        try store.clear()
        try Data((event("task_started", "old", "01") + "\n").utf8).write(to: file)
        _ = try store.collect(observation())
        XCTAssertTrue(try store.records().runs.isEmpty)
        try append([event("task_started", "new", "03"), event("task_complete", "new", "04")])
        _ = try store.collect(observation())
        XCTAssertEqual(try store.records().runs.map { $0.snapshot.runID }, ["new"])
    }
}
