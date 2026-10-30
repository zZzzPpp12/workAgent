import XCTest
@testable import AgentNotifier

final class TaskCenterTests: XCTestCase {
    private let t = Date(timeIntervalSince1970: 1_800_000_000)
    private func observation(_ phase: TaskPhase, id: String = "Codex:s1", run: String = "r1", at: Date? = nil, request: String? = nil) -> TaskObservation {
        TaskObservation(id: id, source: "Codex", path: "/tmp/session.jsonl", title: "修复导出", project: "/tmp/project",
            phase: phase, runID: run, activity: at ?? t, evidence: "来源事件", interactionID: request)
    }

    func testViewingWaitDoesNotResolveIt() {
        let store = TaskCenterStore(stateURL: nil, now: t)
        store.reconcile([observation(.approval, request: "a")], settings: .init(), at: t)
        store.see("Codex:s1", at: t)
        XCTAssertEqual(store.visibleItems(at: t).count, 1)
        XCTAssertNotNil(store.attentions[0].seenAt)
        XCTAssertNil(store.attentions[0].resolvedAt)
        XCTAssertEqual(store.tasks[0].phase, .approval)
    }

    func testSnoozeIsCancelledByActualRecovery() {
        let store = TaskCenterStore(stateURL: nil, now: t)
        store.reconcile([observation(.input)], settings: .init(), at: t)
        store.snooze(store.attentions[0].id, minutes: 15, at: t)
        store.reconcile([observation(.running, at: t.addingTimeInterval(2))], settings: .init(), at: t.addingTimeInterval(2))
        var delivered = 0
        store.deliver = { _, _, _, _ in delivered += 1 }
        store.flushNotifications(settings: .init(), at: t.addingTimeInterval(901))
        XCTAssertEqual(delivered, 0)
        XCTAssertNotNil(store.attentions[0].resolvedAt)
        XCTAssertNil(store.attentions[0].snoozedUntil)
    }

    func testSnoozeRemindsExactlyOnceAtExpiry() {
        let store = TaskCenterStore(stateURL: nil, now: t)
        store.reconcile([observation(.approval)], settings: .init(), at: t)
        store.snooze(store.attentions[0].id, minutes: 5, at: t)
        var delivered = 0
        store.deliver = { _, _, _, _ in delivered += 1 }
        store.flushNotifications(settings: .init(), at: t.addingTimeInterval(301))
        store.flushNotifications(settings: .init(), at: t.addingTimeInterval(305))
        XCTAssertEqual(delivered, 1)
    }

    func testOldUnresolvedRequestRequiresVerification() {
        let store = TaskCenterStore(stateURL: nil, now: t)
        store.reconcile([observation(.approval, at: t.addingTimeInterval(-18000))], settings: .init(), at: t)
        XCTAssertEqual(store.tasks.first?.phase, .unknown)
        XCTAssertTrue(store.attentions.isEmpty)
    }

    func testStartupNeverReplaysCompletionOrWaitNotification() {
        let store = TaskCenterStore(stateURL: nil, now: t)
        var delivered = 0
        store.deliver = { _, _, _, _ in delivered += 1 }
        store.reconcile([observation(.completed), observation(.approval, id: "Codex:s2")], settings: .init(), at: t)
        XCTAssertEqual(store.attentions.count, 1)
        XCTAssertEqual(delivered, 0)
        XCTAssertTrue(store.attentions[0].recovered)
    }

    func testCompletionBatchContainsIndependentReviewItems() {
        let store = TaskCenterStore(stateURL: nil, now: t)
        store.reconcile([observation(.running), observation(.running, id: "Codex:s2")], settings: .init(), at: t)
        var titles: [String] = []
        store.deliver = { title, _, audible, _ in titles.append(title); XCTAssertFalse(audible) }
        store.reconcile([observation(.completed, at: t.addingTimeInterval(1)), observation(.running, id: "Codex:s2")], settings: .init(), at: t.addingTimeInterval(1))
        store.reconcile([observation(.completed, at: t.addingTimeInterval(1)), observation(.completed, id: "Codex:s2", at: t.addingTimeInterval(5))], settings: .init(), at: t.addingTimeInterval(5))
        store.flushNotifications(settings: .init(), at: t.addingTimeInterval(12))
        XCTAssertEqual(titles, ["2 个回合已结束 ✅"])
        let first = store.attentions.first!
        store.see(first.taskID, attentionID: first.id, at: t.addingTimeInterval(13))
        XCTAssertEqual(store.visibleItems(at: t.addingTimeInterval(13)).count, 1)
    }

    func testMultipleReviewRoundsOfSameSessionAreNotClearedTogether() {
        let store = TaskCenterStore(stateURL: nil, now: t)
        store.reconcile([observation(.running)], settings: .init(), at: t)
        store.reconcile([observation(.completed, at: t.addingTimeInterval(1))], settings: .init(), at: t.addingTimeInterval(1))
        store.reconcile([observation(.running, run: "r2", at: t.addingTimeInterval(2))], settings: .init(), at: t.addingTimeInterval(2))
        store.reconcile([observation(.completed, run: "r2", at: t.addingTimeInterval(3))], settings: .init(), at: t.addingTimeInterval(3))
        XCTAssertEqual(store.attentions.count, 2)
        store.see("Codex:s1", attentionID: store.attentions[0].id, at: t)
        XCTAssertNil(store.attentions[1].resolvedAt)
    }

    func testFailureCanBeHandledWithoutChangingFailureState() {
        let store = TaskCenterStore(stateURL: nil, now: t)
        store.reconcile([observation(.failed)], settings: .init(), at: t)
        store.handleFailure(store.attentions[0].id, at: t)
        XCTAssertEqual(store.tasks[0].phase, .failed)
        XCTAssertTrue(store.visibleItems(at: t).isEmpty)
    }

    func testFailureHandlerCannotDismissApproval() {
        let store = TaskCenterStore(stateURL: nil, now: t)
        store.reconcile([observation(.approval)], settings: .init(), at: t)
        store.handleFailure(store.attentions[0].id, at: t)
        XCTAssertNil(store.attentions[0].resolvedAt)
    }

    func testIdenticalSignalDoesNotCreateNewItems() {
        let store = TaskCenterStore(stateURL: nil, now: t)
        for index in 0..<20 { store.reconcile([observation(.approval)], settings: .init(), at: t.addingTimeInterval(Double(index))) }
        XCTAssertEqual(store.attentions.count, 1)
    }

    func testNewRequestInSameRunIsIndependent() {
        let store = TaskCenterStore(stateURL: nil, now: t)
        store.reconcile([observation(.approval, request: "a")], settings: .init(), at: t)
        store.reconcile([observation(.approval, at: t.addingTimeInterval(1), request: "b")], settings: .init(), at: t.addingTimeInterval(1))
        XCTAssertEqual(store.attentions.count, 2)
        XCTAssertNotNil(store.attentions[0].resolvedAt)
        XCTAssertNil(store.attentions[1].resolvedAt)
    }

    func testMissingFileDoesNotTurnTaskIntoSuccessOrFailure() {
        let store = TaskCenterStore(stateURL: nil, now: t)
        store.reconcile([observation(.approval)], settings: .init(), at: t)
        store.reconcile([], settings: .init(), at: t.addingTimeInterval(1))
        XCTAssertEqual(store.tasks[0].phase, .unknown)
        XCTAssertNil(store.attentions[0].resolvedAt)
        XCTAssertTrue(store.visibleItems(at: t).isEmpty)
    }

    func testQuietWindowAcrossMidnight() {
        var settings = MonitorSettings()
        settings.quietEnabled = true
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = calendar.startOfDay(for: t)
        XCTAssertTrue(settings.isQuiet(at: midnight.addingTimeInterval(23 * 3600), calendar: calendar))
        XCTAssertTrue(settings.isQuiet(at: midnight.addingTimeInterval(8 * 3600), calendar: calendar))
        XCTAssertFalse(settings.isQuiet(at: midnight.addingTimeInterval(12 * 3600), calendar: calendar))
    }

    func testMutedSignalsDoNotReplayAfterUnmuting() {
        let store = TaskCenterStore(stateURL: nil, now: t)
        store.reconcile([observation(.running)], settings: .init(), at: t)
        var quiet = MonitorSettings(); quiet.muteUntil = t.addingTimeInterval(60)
        var count = 0
        store.deliver = { _, _, _, _ in count += 1 }
        store.reconcile([observation(.approval, at: t.addingTimeInterval(1))], settings: quiet, at: t.addingTimeInterval(1))
        store.flushNotifications(settings: .init(), at: t.addingTimeInterval(61))
        XCTAssertEqual(count, 0)
        XCTAssertNil(store.attentions[0].resolvedAt)
    }

    func testPersistenceRestoresSeenAndSnoozeIndependently() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        let store = TaskCenterStore(stateURL: url, now: t)
        store.reconcile([observation(.input)], settings: .init(), at: t)
        store.see("Codex:s1", at: t)
        store.snooze(store.attentions[0].id, minutes: 15, at: t)
        store.flushPersistence()
        let restored = TaskCenterStore(stateURL: url, now: t.addingTimeInterval(10))
        XCTAssertNotNil(restored.attentions.first?.seenAt)
        XCTAssertNotNil(restored.attentions.first?.snoozedUntil)
        XCTAssertNil(restored.attentions.first?.resolvedAt)
    }

    func testFutureSchemaIsNeverOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        let original = Data(#"{"version":99,"tasks":[],"attentions":[]}"#.utf8)
        try original.write(to: url)
        let store = TaskCenterStore(stateURL: url, now: t)
        store.reconcile([observation(.running)], settings: .init(), at: t)
        store.flushPersistence()
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertNotNil(store.storageIssue)
    }

    func testCorruptStateRecoversFromBackupAndPreservesOriginal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        try Data("broken".utf8).write(to: url)
        try JSONEncoder().encode(CenterDocument()).write(to: url.appendingPathExtension("previous"))
        let store = TaskCenterStore(stateURL: url, now: t)
        XCTAssertNotNil(store.storageIssue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("unreadable-1800000000").path))
    }

    func testMissingQuotaWindowIsUnknownAndResetDoesNotInventFullBalance() {
        XCTAssertNil(CodexRateLimits.remaining(used: nil, resetsAt: nil, snapshotAt: t, now: t))
        XCTAssertNil(CodexRateLimits.remaining(used: 80, resetsAt: t.addingTimeInterval(10), snapshotAt: t, now: t.addingTimeInterval(11)))
        XCTAssertEqual(CodexRateLimits.remaining(used: 80, resetsAt: nil, snapshotAt: t, now: t), 20)
        XCTAssertNil(CodexRateLimits.remaining(used: .nan, resetsAt: nil, snapshotAt: t, now: t))
    }

    func testCodexIgnoresLateCompletionFromOldRound() {
        let input = #"{"timestamp":"2026-10-23T06:00:00Z","payload":{"type":"task_started","turn_id":"new"}}"# + "\n"
            + #"{"payload":{"type":"task_complete","turn_id":"old"}}"# + "\n"
        let parsed = RunParser.codex(input)
        XCTAssertEqual(parsed.phase, .running)
        XCTAssertEqual(parsed.runID, "new")
    }

    func testParallelToolOutputDoesNotClearAnotherQuestion() {
        let input = #"{"payload":{"type":"task_started","turn_id":"r"}}"# + "\n"
            + #"{"payload":{"type":"function_call","call_id":"q","name":"request_user_input_async"}}"# + "\n"
            + #"{"payload":{"type":"function_call","call_id":"cmd","name":"exec"}}"# + "\n"
            + #"{"payload":{"type":"function_call_output","call_id":"cmd","output":"ok"}}"# + "\n"
            + #"{"payload":{"type":"task_complete","turn_id":"r"}}"# + "\n"
        XCTAssertEqual(RunParser.codex(input).phase, .input)
        XCTAssertEqual(RunParser.codex(input).requestID, "q")
    }

    func testClaudeUnrelatedToolResultDoesNotResolveQuestion() {
        let input = #"{"type":"user","uuid":"u","message":{"content":[{"type":"text","text":"hi"}]}}"# + "\n"
            + #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"q","name":"AskUserQuestion"}]}}"# + "\n"
            + #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"other","content":"ok"}]}}"# + "\n"
        XCTAssertEqual(RunParser.claude(input).phase, .input)
        let answered = input + #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"q","content":"answer"}]}}"# + "\n"
        XCTAssertEqual(RunParser.claude(answered).phase, .running)
    }

    func testFractionalEventTimestampIsParsed() throws {
        let fractional = try XCTUnwrap(eventDate("2026-10-23T06:00:00.123Z"))
        let whole = try XCTUnwrap(eventDate("2026-10-23T06:00:00Z"))
        XCTAssertEqual(fractional.timeIntervalSince1970, whole.timeIntervalSince1970 + 0.123, accuracy: 0.001)
    }

    func testMetadataRefreshDoesNotRequeueHistoricalCompletedRun() {
        let store = TaskCenterStore(stateURL: nil, now: t)
        store.reconcile([observation(.completed, at: t.addingTimeInterval(-100))], settings: .init(), at: t)
        store.reconcile([observation(.completed, at: t.addingTimeInterval(1))], settings: .init(), at: t.addingTimeInterval(1))
        XCTAssertTrue(store.attentions.isEmpty)
    }

    func testResumeCommandQuotesPathsAndIsOnlyReturnedAsText() {
        let task = TaskRecord(id: "Claude:id'quoted", source: "Claude", path: "/tmp/x", title: "x", project: "/tmp/a' b", phase: .completed,
            runID: "r", activity: t, observedAt: t, changedAt: t, evidence: "", readable: true, precise: true)
        let command = TaskNavigator.resumeCommand(task)
        XCTAssertTrue(command.contains("'\\''"))
        XCTAssertTrue(command.contains("claude --resume"))
    }
    func testUpdateTrustRejectsAdHocOrDifferentPublishers() {
        let local = UpdateIdentity.parse("Identifier=com.example.app\nTeamIdentifier=not set\n")
        XCTAssertFalse(local.accepts(local))
        let trusted = UpdateIdentity(team: "TEAM-A", identifier: "com.example.app")
        XCTAssertTrue(trusted.accepts(trusted))
        XCTAssertFalse(trusted.accepts(UpdateIdentity(team: "TEAM-B", identifier: "com.example.app")))
        XCTAssertFalse(trusted.accepts(UpdateIdentity(team: "TEAM-A", identifier: "com.other.app")))
    }
    func testThousandHistoricalSessionsDoNotHideActiveWait() {
        let store = TaskCenterStore(stateURL: nil, now: t)
        var records = (0..<1000).map { observation(.completed, id: "Codex:history-\($0)", at: t.addingTimeInterval(-3600)) }
        records += (0..<20).map { observation(.running, id: "Codex:active-\($0)") }
        store.reconcile(records, settings: .init(), at: t)
        records[1000] = observation(.approval, id: "Codex:active-0", at: t.addingTimeInterval(1))
        store.reconcile(records, settings: .init(), at: t.addingTimeInterval(1))
        XCTAssertEqual(store.tasks.count, 1020)
        XCTAssertEqual(store.visibleItems(at: t.addingTimeInterval(1)).first?.taskID, "Codex:active-0")
        XCTAssertEqual(store.visibleItems(at: t.addingTimeInterval(1)).count, 1)
    }

    func testSourceDirectoryAndPrivacyPreferencesPersist() {
        let suite = "AgentNotifierTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = MonitorPreferences(defaults: defaults)
        preferences.value.sourcePaths["Codex"] = "/tmp/custom-sessions"
        preferences.value.notifyCompleted = false
        let restored = MonitorPreferences(defaults: defaults)
        XCTAssertEqual(restored.snapshot.sourcePaths["Codex"], "/tmp/custom-sessions")
        XCTAssertFalse(restored.snapshot.notifyCompleted)
        XCTAssertFalse(restored.snapshot.chromeImport)
        XCTAssertFalse(restored.snapshot.telemetry)
    }
    func testWakeSuppressesOldOutboxAndKeepsUnreviewedResult() {
        let store = TaskCenterStore(stateURL: nil, now: t)
        store.reconcile([observation(.running)], settings: .init(), at: t)
        store.reconcile([observation(.completed, at: t.addingTimeInterval(1))], settings: .init(), at: t.addingTimeInterval(1))
        var delivered = 0
        store.deliver = { _, _, _, _ in delivered += 1 }
        store.resume(at: t.addingTimeInterval(100))
        store.flushNotifications(settings: .init(), at: t.addingTimeInterval(101))
        XCTAssertEqual(delivered, 0)
        XCTAssertEqual(store.visibleItems(at: t.addingTimeInterval(101)).count, 1)
    }
    func testCompletionDuringSleepIsRecoveredWithoutNotification() {
        let store = TaskCenterStore(stateURL: nil, now: t)
        store.reconcile([observation(.running)], settings: .init(), at: t)
        store.resume(at: t.addingTimeInterval(100))
        var delivered = 0
        store.deliver = { _, _, _, _ in delivered += 1 }
        store.reconcile([observation(.completed, at: t.addingTimeInterval(50))], settings: .init(), at: t.addingTimeInterval(101))
        store.flushNotifications(settings: .init(), at: t.addingTimeInterval(120))
        XCTAssertEqual(delivered, 0)
        XCTAssertTrue(store.attentions.first?.recovered == true)
    }
    func testReturningToAppDoesNotClaimResultWasReviewed() {
        let store = TaskCenterStore(stateURL: nil, now: t)
        store.reconcile([observation(.running)], settings: .init(), at: t)
        store.reconcile([observation(.completed, at: t.addingTimeInterval(1))], settings: .init(), at: t.addingTimeInterval(1))
        store.recordReturn("Codex:s1", at: t.addingTimeInterval(2))
        XCTAssertNotNil(store.attentions.first?.seenAt)
        XCTAssertNil(store.attentions.first?.resolvedAt)
    }
    func testQuotaUsesEventTimeInsteadOfLastPhysicalLine() {
        let newer = #"{"timestamp":"2026-10-23T06:00:00.000Z","payload":{"rate_limits":{"primary":{"used_percent":10}}}}"#
        let older = #"{"timestamp":"2026-10-23T05:00:00.000Z","payload":{"rate_limits":{"primary":{"used_percent":90}}}}"#
        XCTAssertEqual(lastCodexRateLimits(in: newer + "\n" + older)?.primaryUsedPercent, 10)
    }
    func testLargeMetadataHeadKeepsWorkspaceAndStableSessionID() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let header: [String: Any] = ["type": "session_meta", "payload": ["id": "stable-session", "cwd": "/tmp/real-project", "base_instructions": String(repeating: "x", count: 25000)]]
        var data = try JSONSerialization.data(withJSONObject: header)
        data.append(Data("\n".utf8))
        try data.write(to: url)
        let watch = SessionWatch(kind: .codexSession, url: url, label: "fallback")
        let projected = SessionProjector().observation(watch, now: t)
        XCTAssertEqual(projected.id, "Codex:stable-session")
        XCTAssertEqual(projected.project, "/tmp/real-project")
    }
    func testStableIDUpgradePreservesSeenPendingItem() {
        let store = TaskCenterStore(stateURL: nil, now: t)
        var fallback = observation(.approval, id: "Codex:fallback", request: "a")
        fallback.identityIsFallback = true
        store.reconcile([fallback], settings: .init(), at: t)
        store.see("Codex:fallback", at: t)
        store.reconcile([observation(.approval, id: "Codex:stable", request: "a")], settings: .init(), at: t.addingTimeInterval(1))
        XCTAssertEqual(store.tasks.count, 1)
        XCTAssertEqual(store.tasks.first?.id, "Codex:stable")
        XCTAssertEqual(store.attentions.count, 1)
        XCTAssertNotNil(store.attentions.first?.seenAt)
        XCTAssertNil(store.attentions.first?.resolvedAt)
    }
    func testUnattributedIdeaErrorNeverTargetsMostRecentSession() {
        let watch = SessionWatch(kind: .ideaTranscript, url: URL(fileURLWithPath: "/tmp/log"), label: "x", sessionDir: URL(fileURLWithPath: "/tmp/session-unique"))
        watch.lastActivity = t
        XCTAssertNil(ideaErrorTarget([watch], message: "Network request failed"))
        XCTAssertTrue(ideaErrorTarget([watch], message: "session-unique: Network request failed") === watch)
    }
    func testHistoricalFailureKeepsFactWithoutCreatingFreshQueue() {
        let store = TaskCenterStore(stateURL: nil, now: t)
        store.reconcile([observation(.failed, at: t.addingTimeInterval(-18000))], settings: .init(), at: t)
        XCTAssertEqual(store.tasks.first?.phase, .failed)
        XCTAssertTrue(store.attentions.isEmpty)
    }
    func testUnresolvedFailureDoesNotDisappearAfterFourHours() {
        let store = TaskCenterStore(stateURL: nil, now: t)
        store.reconcile([observation(.failed)], settings: .init(), at: t)
        store.reconcile([observation(.failed)], settings: .init(), at: t.addingTimeInterval(18000))
        XCTAssertEqual(store.tasks.first?.phase, .failed)
        XCTAssertEqual(store.visibleItems(at: t.addingTimeInterval(18000)).count, 1)
    }
}
