import XCTest
@testable import AgentNotifier

final class ProcessObservationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func raw(pid: pid_t, ppid: pid_t = 1, name: String, path: String = "",
                     cwd: String = "/tmp/project", cmd: String = "",
                     rss: UInt64 = 100, cpu: Double = 0, start: Int64 = 1) -> RawProcess {
        RawProcess(pid: pid, ppid: ppid, uid: 501, name: name, path: path, cwd: cwd,
                   cmd: cmd, rss: rss, cpuSeconds: cpu, startSeconds: start)
    }

    private func task(id: String, source: String, project: String,
                      session: String = "session-0001", phase: TaskPhase = .running) -> TaskRecord {
        TaskRecord(
            id: source + ":" + (session.isEmpty ? id : session),
            source: source, path: "", title: "任务", project: project, phase: phase,
            runID: "run-1", activity: now, observedAt: now, changedAt: now,
            evidence: "", readable: true, precise: true
        )
    }

    private func group(kind: AgentKind, root: pid_t, cwd: String, cmd: String = "",
                       pids: [pid_t]? = nil, startedAt: Date? = nil) -> AgentProcessGroup {
        AgentProcessGroup(kind: kind, rootPID: root, pids: pids ?? [root], rss: 1_000,
                          cpuPercent: 1, cwd: cwd, cmd: cmd,
                          startedAt: startedAt ?? now, lastSeen: now)
    }

    // MARK: - 进程树

    func testLiveSampleReadsCurrentProcess() {
        let processes = RawProcessReader.read()
        XCTAssertFalse(processes.isEmpty)
        XCTAssertTrue(processes.contains { $0.pid == getpid() })
        XCTAssertTrue(processes.contains { !$0.name.isEmpty })
    }

    func testLiveSampleDurationStaysBounded() {
        let start = CFAbsoluteTimeGetCurrent()
        let processes = RawProcessReader.read()
        let duration = CFAbsoluteTimeGetCurrent() - start
        print("process sample: \(processes.count) processes, \(String(format: "%.1f", duration * 1000)) ms")
        XCTAssertLessThan(duration, 0.25)
    }

    func testGroupsAggregateTreeAndCPU() {
        let processes = [
            raw(pid: 100, ppid: 1, name: "claude", rss: 1_000, cpu: 10),
            raw(pid: 101, ppid: 100, name: "node", rss: 500, cpu: 2),
            raw(pid: 200, ppid: 1, name: "codex", rss: 800, cpu: 5)
        ]
        let groups = ProcessGrouper.groups(
            raw: processes,
            previousCPU: [
                ProcessKey(pid: 100, startSeconds: 1): 8,
                ProcessKey(pid: 101, startSeconds: 1): 1
            ],
            interval: 2,
            now: now
        )

        XCTAssertEqual(groups.count, 2)
        let claude = groups.first { $0.kind == .claude }
        XCTAssertEqual(claude?.rootPID, 100)
        XCTAssertEqual(claude?.pids, [100, 101])
        XCTAssertEqual(claude?.rss, 1_500)
        XCTAssertEqual(claude?.cpuPercent ?? 0, 150, accuracy: 0.001)
        XCTAssertEqual(groups.first { $0.kind == .codex }?.cpuPercent, 0)
    }

    func testNestedSameKindProcessIsNotADuplicateRoot() {
        let processes = [
            raw(pid: 100, ppid: 1, name: "claude"),
            raw(pid: 101, ppid: 100, name: "claude"),
            raw(pid: 102, ppid: 101, name: "bash")
        ]
        let groups = ProcessGrouper.groups(raw: processes, previousCPU: [:], interval: 0, now: now)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.pids, [100, 101, 102])
    }

    func testNestedDifferentKindAgentIsNotDoubleCounted() {
        let processes = [
            raw(pid: 100, ppid: 1, name: "claude", rss: 1_000),
            raw(pid: 101, ppid: 100, name: "codex", rss: 500),
            raw(pid: 102, ppid: 101, name: "bash", rss: 100)
        ]
        let groups = ProcessGrouper.groups(raw: processes, previousCPU: [:], interval: 0, now: now)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first { $0.kind == .claude }?.pids, [100])
        XCTAssertEqual(groups.first { $0.kind == .codex }?.pids, [101, 102])
        XCTAssertEqual(groups.reduce(UInt64(0)) { $0 + $1.rss }, 1_600)
    }

    func testPIDReuseDoesNotReuseCPUBaseline() {
        let processes = [raw(pid: 100, ppid: 1, name: "claude", cpu: 50, start: 2)]
        let groups = ProcessGrouper.groups(
            raw: processes,
            previousCPU: [ProcessKey(pid: 100, startSeconds: 1): 10],
            interval: 5,
            now: now
        )
        XCTAssertEqual(groups.first?.cpuPercent, 0)
    }

    // MARK: - 会话归属

    func testOnlyReliableAttributionsExposeResourceUsage() {
        XCTAssertTrue(ProcessConfidence.exact.showsResourceUsage)
        XCTAssertTrue(ProcessConfidence.strong.showsResourceUsage)
        XCTAssertFalse(ProcessConfidence.medium.showsResourceUsage)
    }

    func testClaudeRegistryGivesExactAttribution() {
        let task = task(id: "a", source: "Claude", project: "/tmp/project-a", session: "s-1")
        let groups = [group(kind: .claude, root: 100, cwd: "/tmp/elsewhere", cmd: "claude")]
        let result = ProcessAttribution.resolve(
            tasks: [task], groups: groups,
            claudeSessions: [100: ClaudeSessionEntry(sessionID: "s-1", modified: now)])
        XCTAssertEqual(result[task.id]?.confidence, .exact)
    }

    func testClaudeRegistryForAnotherSessionBlocksDirectoryGuess() {
        let task = task(id: "a", source: "Claude", project: "/tmp/project-a", session: "s-1")
        let groups = [group(kind: .claude, root: 100, cwd: "/tmp/project-a", cmd: "claude")]
        let result = ProcessAttribution.resolve(
            tasks: [task], groups: groups,
            claudeSessions: [100: ClaudeSessionEntry(sessionID: "other", modified: now)])
        XCTAssertNil(result[task.id])
    }

    func testStaleClaudeRegistryFileDoesNotClaimExactAttribution() {
        let task = task(id: "a", source: "Claude", project: "/tmp/project-a", session: "s-1")
        let groups = [group(kind: .claude, root: 100, cwd: "/tmp/project-a", cmd: "claude",
                            startedAt: now.addingTimeInterval(60))]
        let result = ProcessAttribution.resolve(
            tasks: [task], groups: groups,
            claudeSessions: [100: ClaudeSessionEntry(sessionID: "s-1", modified: now)])
        XCTAssertNil(result[task.id])
    }

    func testCommandLineSessionIDGivesStrongAttribution() {
        let session = "abcdef12-3456-7890"
        let task = task(id: "b", source: "Codex", project: "/tmp/other", session: session)
        let groups = [group(kind: .codex, root: 200, cwd: "/tmp/other", cmd: "codex exec --session \(session)")]
        let result = ProcessAttribution.resolve(tasks: [task], groups: groups, claudeSessions: [:])
        XCTAssertEqual(result[task.id]?.confidence, .strong)
    }

    func testUniqueWorkingDirectoryGivesMediumAttribution() {
        let task = task(id: "c", source: "Codex", project: "/tmp/project-c", session: "unknown-session")
        let groups = [group(kind: .codex, root: 300, cwd: "/tmp/project-c")]
        let result = ProcessAttribution.resolve(tasks: [task], groups: groups, claudeSessions: [:])
        XCTAssertEqual(result[task.id]?.confidence, .medium)
    }

    func testAmbiguousWorkingDirectoryIsNotAttributed() {
        let task = task(id: "d", source: "Codex", project: "/tmp/project-d", session: "unknown-session")
        let groups = [
            group(kind: .codex, root: 400, cwd: "/tmp/project-d"),
            group(kind: .codex, root: 401, cwd: "/tmp/project-d")
        ]
        let result = ProcessAttribution.resolve(tasks: [task], groups: groups, claudeSessions: [:])
        XCTAssertNil(result[task.id])
    }

    func testNonCLISourceIsIgnored() {
        let task = task(id: "e", source: "IDE-CatPaw", project: "/tmp/project-e")
        let groups = [group(kind: .claude, root: 500, cwd: "/tmp/project-e")]
        let result = ProcessAttribution.resolve(
            tasks: [task], groups: groups,
            claudeSessions: [500: ClaudeSessionEntry(sessionID: "session-0001", modified: now)])
        XCTAssertNil(result[task.id])
    }

    // MARK: - 设置迁移

    func testMonitorSettingsDecodesWithoutNewOptionalKeys() throws {
        let encoded = try JSONEncoder().encode(MonitorSettings())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["observeProcessesRaw", "showProcessUsageRaw", "islandEnabledRaw",
                    "islandNotchModeRaw", "islandOverFullScreenRaw"] {
            object.removeValue(forKey: key)
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(MonitorSettings.self, from: data)

        XCTAssertTrue(decoded.observeProcesses)
        XCTAssertFalse(decoded.showProcessUsage)
        XCTAssertTrue(decoded.islandEnabled)
        XCTAssertFalse(decoded.islandNotchMode)
        XCTAssertTrue(decoded.islandOverFullScreen)
    }

    func testNewSettingsRoundTrip() throws {
        var settings = MonitorSettings()
        settings.observeProcesses = false
        settings.islandEnabled = false
        settings.islandNotchMode = true
        let decoded = try JSONDecoder().decode(MonitorSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(decoded.observeProcesses)
        XCTAssertFalse(decoded.islandEnabled)
        XCTAssertTrue(decoded.islandNotchMode)
    }
}
