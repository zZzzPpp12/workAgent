import XCTest
@testable import AgentNotifier

final class WorkflowTests: XCTestCase {
    private func event(_ type: String, _ fields: [String: Any] = [:], second: Int = 0) -> [String: Any] {
        var payload = fields; payload["type"] = type
        return ["type": "event_msg", "timestamp": String(format: "2026-10-30T00:00:%02dZ", second), "payload": payload]
    }
    private func parse(_ records: [[String: Any]], partial: Bool = false) -> WorkflowSnapshot {
        WorkflowParser.parse(records, source: "Codex", partial: partial)
    }
    private var start: [String: Any] { event("task_started", ["turn_id": "r1"]) }
    private func call(_ id: String, name: String = "read_file", second: Int = 1) -> [String: Any] {
        event("function_call", ["call_id": id, "name": name], second: second)
    }
    private func result(_ id: String, output: Any = "{}", second: Int = 5) -> [String: Any] {
        event("function_call_output", ["call_id": id, "output": output], second: second)
    }

    func testCodexPairsToolWithResultAndCalculatesDuration() throws {
        let flow = parse([start, call("a"), result("a"), event("task_complete", ["turn_id": "r1"], second: 8)])
        XCTAssertEqual(flow.steps.map(\.kind), [.start, .tool, .end])
        XCTAssertEqual(flow.toolCount, 1)
        XCTAssertEqual(flow.returnedTools, 1)
        XCTAssertEqual(flow.steps[1].duration, 4)
        XCTAssertEqual(flow.endedAt?.timeIntervalSince(flow.startedAt!), 8)
    }

    func testParallelToolResultsDoNotResolveOtherCalls() {
        let flow = parse([start, call("a"), call("b"), result("a")])
        XCTAssertEqual(flow.steps.first { $0.id == "tool:a" }?.status, .returned)
        XCTAssertEqual(flow.steps.first { $0.id == "tool:b" }?.status, .active)
        XCTAssertEqual(flow.currentStep?.id, "tool:b")
    }

    func testReplayedCallAndResultDoNotDuplicateNodes() {
        let flow = parse([start, call("a"), call("a"), result("a"), result("a")])
        XCTAssertEqual(flow.toolCount, 1)
        XCTAssertEqual(flow.returnedTools, 1)
    }

    func testNewRoundClearsOldToolsAndIgnoresLateOldEnd() {
        let flow = parse([start, call("a"), event("task_started", ["turn_id": "r2"], second: 10),
                          call("b", second: 11), event("task_complete", ["turn_id": "r1"], second: 12)])
        XCTAssertEqual(flow.runID, "r2")
        XCTAssertEqual(flow.toolCount, 1)
        XCTAssertNil(flow.endedAt)
        XCTAssertEqual(flow.currentStep?.id, "tool:b")
    }

    func testAsyncQuestionReceiptDoesNotPretendUserAnswered() {
        let question = call("q", name: "functions.request_user_input_async")
        var flow = parse([start, question, result("q", output: #"{"request_id":"q","status":"pending"}"#)])
        XCTAssertEqual(flow.currentStep?.status, .waiting)
        flow = parse([start, question, result("q", output: #"{"answers":{"choice":"yes"}}"#)])
        XCTAssertEqual(flow.steps.last?.status, .returned)
    }

    func testOnlyExplicitToolErrorsAreMarkedFailed() {
        let flow = parse([start, call("a"), result("a", output: #"{"exit_code":2}"#),
                          call("b"), result("b", output: "test fixture contains error and failed")])
        XCTAssertEqual(flow.failedTools, 1)
        XCTAssertEqual(flow.returnedTools, 1)
    }

    func testRoundEndDoesNotInventMissingToolResult() {
        let flow = parse([start, call("a"), event("task_complete", ["turn_id": "r1"], second: 10)])
        XCTAssertEqual(flow.steps[1].status, .unconfirmed)
        XCTAssertNil(flow.steps[1].endedAt)
        XCTAssertEqual(flow.returnedTools, 0)
    }

    func testAbortInterruptsOutstandingTools() {
        let flow = parse([start, call("a"), event("turn_aborted", ["turn_id": "r1"], second: 8)])
        XCTAssertEqual(flow.steps.last?.status, .interrupted)
        XCTAssertEqual(flow.steps[1].status, .interrupted)
    }

    func testExplicitPlanPreservesModelStatusesAtRoundEnd() {
        let plan = event("function_call", ["call_id": "p", "name": "functions.update_plan",
            "arguments": #"{"plan":[{"step":"读取项目","status":"completed"},{"step":"实现功能","status":"in_progress"},{"step":"验收","status":"pending"}]}"#])
        let flow = parse([start, plan, event("task_complete", ["turn_id": "r1"], second: 10)])
        XCTAssertEqual(flow.plan.map(\.status), [.completed, .inProgress, .pending])
        XCTAssertEqual(flow.plan.count, 3)
    }

    func testSnapshotDoesNotStoreReasoningArgumentsCommandsOrOutputs() throws {
        let flow = parse([start,
            event("reasoning", ["summary": "PRIVATE_REASONING_SECRET", "encrypted_content": "ENCRYPTED_SECRET"]),
            event("function_call", ["call_id": "a", "name": "exec_command", "arguments": #"{"cmd":"COMMAND_SECRET"}"#]),
            result("a", output: #"{"stdout":"OUTPUT_SECRET","exit_code":0}"#),
            event("message", ["role": "assistant", "channel": "analysis", "content": "ANALYSIS_SECRET"])])
        let encoded = String(decoding: try JSONEncoder().encode(flow), as: UTF8.self)
        for value in ["PRIVATE_REASONING_SECRET", "ENCRYPTED_SECRET", "COMMAND_SECRET", "OUTPUT_SECRET", "ANALYSIS_SECRET"] {
            XCTAssertFalse(encoded.contains(value))
        }
        XCTAssertTrue(encoded.contains("exec_command"))
        XCTAssertNil(flow.steps.first(where: { $0.kind == .model })?.duration)
    }

    func testCurrentNativeCodexItemFormatProvidesExplicitFailureAndDuration() {
        let item: [String: Any] = ["id": "c1", "type": "CommandExecution", "command": "PRIVATE_COMMAND", "exit_code": 1, "status": "completed"]
        let flow = parse([start, event("item_completed", ["turn_id": "r1", "item": item,
            "started_at_ms": 1_793_318_401_000.0, "completed_at_ms": 1_793_318_405_000.0])])
        XCTAssertEqual(flow.toolCount, 1)
        XCTAssertEqual(flow.failedTools, 1)
        XCTAssertEqual(flow.steps.last?.duration, 4)
    }

    func testCompletedItemAndRawResultShareOneNode() {
        let item: [String: Any] = ["id": "a", "type": "CommandExecution", "exit_code": 0]
        let flow = parse([start, call("a"), event("item_completed", ["item": item]), result("a")])
        XCTAssertEqual(flow.toolCount, 1)
    }

    func testTailWithResultOnlyShowsGapWithoutInventedStartTime() {
        let flow = parse([result("a")], partial: true)
        XCTAssertTrue(flow.isPartial)
        XCTAssertFalse(flow.hasExplicitStart)
        XCTAssertNil(flow.steps.first?.startedAt)
        XCTAssertNotNil(flow.steps.first?.endedAt)
    }

    func testCompleteCurrentRoundInsideTruncatedFileIsNotMarkedPartial() {
        let flow = parse([start, call("a")], partial: true)
        XCTAssertFalse(flow.isPartial)
        XCTAssertTrue(flow.hasExplicitStart)
    }

    func testSnapshotIsBoundedAndKeepsOutstandingOldCall() {
        var rows = [start, call("pending")]
        for i in 0..<150 { rows += [call("\(i)"), result("\(i)")] }
        let flow = parse(rows)
        XCTAssertLessThanOrEqual(flow.steps.count, 96)
        XCTAssertTrue(flow.isPartial)
        XCTAssertEqual(flow.toolCount, 151)
        XCTAssertTrue(flow.steps.contains { $0.id == "tool:pending" })
        XCTAssertNotNil(flow.startedAt)
    }

    func testClaudePairsToolErrorAndIgnoresSidechain() {
        let rows: [[String: Any]] = [
            ["type": "user", "uuid": "r1", "timestamp": "2026-10-30T00:00:00Z", "message": ["content": "hello"]],
            ["type": "assistant", "uuid": "m1", "message": ["content": [["type": "tool_use", "id": "a", "name": "Bash"]]]],
            ["type": "user", "uuid": "result", "message": ["content": [["type": "tool_result", "tool_use_id": "a", "is_error": true]]]],
            ["type": "user", "uuid": "side", "isSidechain": true, "message": ["content": "side"]]
        ]
        let flow = WorkflowParser.parse(rows, source: "Claude")
        XCTAssertEqual(flow.runID, "r1")
        XCTAssertEqual(flow.failedTools, 1)
    }

    func testCatDeskUsesToolCallIDAndDoesNotEndAtAssistantToolMessage() {
        let rows: [[String: Any]] = [
            ["type": "user", "messageId": "r1", "message": ["content": [["type": "text", "text": "go"]]]],
            ["type": "assistant", "messageId": "a1", "message": ["finished": true, "content": [["type": "tool_use", "toolCallId": "a", "toolName": "read_file", "toolParams": ["path": "PRIVATE"]]]]],
            ["type": "tool", "message": ["content": [["type": "tool_result", "toolCallId": "a", "toolName": "read_file", "toolResult": ["status": "success"]]]]]
        ]
        let flow = WorkflowParser.parse(rows, source: "CatDesk")
        XCTAssertNil(flow.endedAt)
        XCTAssertEqual(flow.returnedTools, 1)
        XCTAssertEqual(flow.steps.last?.kind, .tool)
    }

    func testTranscriptShowsOnlyMarkersAndNoInventedTimes() throws {
        let flow = WorkflowParser.transcript("user:\nPRIVATE_USER\n[Thinking] PRIVATE_REASONING\n[Tool call] read_file\n path: PRIVATE_PATH\n[Tool result] read_file\nPRIVATE_RESULT\n")
        XCTAssertEqual(flow.returnedTools, 1)
        XCTAssertNil(flow.steps.last?.startedAt)
        XCTAssertTrue(flow.isPartial)
        let encoded = String(decoding: try JSONEncoder().encode(flow), as: UTF8.self)
        XCTAssertFalse(encoded.contains("PRIVATE"))
    }

    func testLegacyDocumentWithoutWorkflowStillLoads() throws {
        let data = Data(#"{"version":1,"tasks":[],"attentions":[]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(CenterDocument.self, from: data).version, 1)
        let record = TaskRecord(id: "Codex:s1", source: "Codex", path: "/tmp/x", title: "x", project: "x", phase: .running,
            runID: "r1", activity: .distantPast, observedAt: .distantPast, changedAt: .distantPast, evidence: "x", readable: true, precise: true)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object.removeValue(forKey: "workflow")
        XCTAssertNil(try JSONDecoder().decode(TaskRecord.self, from: JSONSerialization.data(withJSONObject: object)).workflow)
    }

    func testReconciliationPersistsAndRetainsWorkflowWhenSourceBecomesUnreadable() throws {
        let now = Date()
        let store = TaskCenterStore(stateURL: nil, now: now)
        let flow = parse([start, call("a")])
        var observation = TaskObservation(id: "Codex:s1", source: "Codex", path: "/tmp/x", title: "x", project: "x", phase: .running,
            runID: "r1", activity: now, evidence: "source", workflow: flow)
        store.reconcile([observation], settings: .init(), at: now)
        XCTAssertEqual(store.tasks.first?.workflow, flow)
        observation.workflow = nil; observation.readable = false
        store.reconcile([observation], settings: .init(), at: now.addingTimeInterval(3))
        XCTAssertEqual(store.tasks.first?.workflow, flow)
        XCTAssertEqual(store.tasks.first?.phase, .unknown)
        let encoded = try JSONEncoder().encode(store.tasks[0])
        XCTAssertEqual(try JSONDecoder().decode(TaskRecord.self, from: encoded).workflow, flow)
    }

    func testReturningFromCurrentWorkflowDoesNotAcknowledgeOlderRound() {
        let now = Date()
        let store = TaskCenterStore(stateURL: nil, now: now)
        var observation = TaskObservation(id: "Codex:s1", source: "Codex", path: "/tmp/x", title: "x", project: "x", phase: .running,
            runID: "old", activity: now, evidence: "source")
        store.reconcile([observation], settings: .init(), at: now)
        observation.phase = .completed; observation.activity = now.addingTimeInterval(1)
        store.reconcile([observation], settings: .init(), at: now.addingTimeInterval(1))
        observation.phase = .running; observation.runID = "current"; observation.activity = now.addingTimeInterval(2)
        store.reconcile([observation], settings: .init(), at: now.addingTimeInterval(2))
        store.recordReturn(observation.id, at: now.addingTimeInterval(3))
        XCTAssertEqual(store.attentions.count, 1)
        XCTAssertNil(store.attentions[0].seenAt)
        XCTAssertNil(store.attentions[0].resolvedAt)
    }
}
