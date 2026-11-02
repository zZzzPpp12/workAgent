import Foundation
import Combine

/// 历史库与来源读取在独立串行队列运行；失败不阻塞现有监测和提醒队列。
final class HistoryModel: ObservableObject {
    @Published private(set) var runs: [HistoricalRun] = []
    @Published private(set) var sources: [String] = []
    @Published private(set) var projects: [String] = []
    @Published private(set) var enabledAt: Date?
    @Published private(set) var issue: String?
    @Published private(set) var truncated = false
    @Published private(set) var importStatus: String?
    @Published private(set) var importing = false
    @Published private(set) var loading = true
    @Published private(set) var sessionRuns: [HistoricalRun] = []
    @Published private(set) var sessionTaskID: String?
    @Published private(set) var sessionTruncated = false

    private let queue = DispatchQueue(label: "AgentNotifier.history", qos: .utility)
    private let databaseURL: URL
    private var store: HistoryStore?
    private var started = false
    private var scanning = false
    private var observations: [TaskObservation] = []
    private var stamps: [String: String] = [:]
    private var unfinished = Set<String>()
    private var pendingImport: [TaskObservation] = []
    private var importTotal = 0
    private var importFailures = 0
    private var lastPrune = Date.distantPast
    private var lastChanges = -1
    private var trackedSessionID: String?
    private var filter: HistoryFilter

    init(databaseURL: URL = TaskCenterStore.dataDirectory.appendingPathComponent("history-v1.sqlite3"), now: Date = Date()) {
        self.databaseURL = databaseURL
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(86400)
        filter = HistoryFilter(interval: DateInterval(start: start, end: end))
    }

    /// 只由实际应用启动调用，测试不会因此访问用户历史库。
    func start() {
        guard !started else { return }
        started = true
        let url = databaseURL
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let opened = try HistoryStore(url: url)
                self.store = opened
                self.publish(opened, force: true)
            } catch {
                DispatchQueue.main.async { self.loading = false; self.issue = error.localizedDescription }
            }
        }
    }

    /// 在主线程提交快照，单次处理仍在后台执行；慢扫描期间跳过重复调度。
    func observe(_ incoming: [TaskObservation], attentions: [AttentionRecord], retentionDays: Int, at now: Date) {
        guard started, !scanning else { return }
        scanning = true
        let input = incoming.filter { ["Codex", "Claude", "CatDesk"].contains($0.source) && $0.readable }
            .sorted { $0.activity > $1.activity }
        let protected = Set(attentions.filter { $0.resolvedAt == nil }.map(\.taskID))
            .union(incoming.filter { $0.phase == .running }.map(\.id))
        queue.async { [weak self] in
            guard let self else { return }
            defer { DispatchQueue.main.async { self.scanning = false } }
            guard let store = self.store else { return }
            self.observations = input
            var failures = 0
            for observation in input {
                do {
                    let attrs = try FileManager.default.attributesOfItem(atPath: observation.path)
                    let size = (attrs[.size] as? NSNumber)?.stringValue ?? "0"
                    let modification = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    let stamp = size + ":" + String(modification) + ":" + observation.id
                    if self.stamps[observation.path] == stamp && !self.unfinished.contains(observation.path) { continue }
                    let done = try store.collect(observation, now: now)
                    self.stamps[observation.path] = stamp
                    if done { self.unfinished.remove(observation.path) } else { self.unfinished.insert(observation.path) }
                } catch { failures += 1 }
            }
            if now.timeIntervalSince(self.lastPrune) >= 3600 {
                do {
                    try store.prune(before: now.addingTimeInterval(-Double(retentionDays) * 86400), protecting: protected)
                    self.lastPrune = now
                } catch { failures += 1 }
            }
            if !self.pendingImport.isEmpty {
                // 最多处理 16 个文件块，避免一次回填占满后台工作队列。
                for _ in 0..<min(16, self.pendingImport.count) {
                    let item = self.pendingImport.removeFirst()
                    do {
                        if try !store.collect(item, backfill: true, now: now) { self.pendingImport.append(item) }
                    } catch { self.importFailures += 1 }
                }
                let remaining = self.pendingImport.count
                let done = self.importTotal - remaining
                let failures = self.importFailures
                DispatchQueue.main.async {
                    self.importing = remaining > 0
                    self.importStatus = remaining > 0 ? "回填中：\(done) / \(self.importTotal) 个会话"
                        : "回填结束：\(done - failures) 个会话，\(failures) 个未能读取"
                }
            }
            if failures > 0 {
                DispatchQueue.main.async { self.issue = "部分历史来源暂不可读取或已达到容量上限；实时监测继续运行。" }
            }
            self.publish(store, force: false)
        }
    }

    func setFilter(_ newFilter: HistoryFilter) {
        queue.async { [weak self] in
            guard let self else { return }
            self.filter = newFilter
            if let store = self.store { self.publish(store, force: true) }
        }
    }

    func beginBackfill() {
        guard started, !importing else { return }
        importing = true
        importStatus = "正在准备回填…"
        queue.async { [weak self] in
            guard let self else { return }
            guard let store = self.store else {
                DispatchQueue.main.async { self.importing = false; self.importStatus = "历史记录暂不可用。" }
                return
            }
            do {
                guard !self.observations.isEmpty else {
                    DispatchQueue.main.async { self.importing = false; self.importStatus = "暂无可回填的已发现会话。" }
                    return
                }
                try store.resetBackfill(for: self.observations)
                self.pendingImport = self.observations
                self.importTotal = self.pendingImport.count
                self.importFailures = 0
                DispatchQueue.main.async { self.importStatus = "已准备 \(self.importTotal) 个会话，等待后台处理。" }
            } catch {
                DispatchQueue.main.async { self.importing = false; self.issue = error.localizedDescription }
            }
        }
    }

    func loadSession(_ taskID: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.trackedSessionID = taskID
            guard let store = self.store else { return }
            self.publish(store, force: true)
        }
    }

    func clearHistory() {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            do {
                self.pendingImport.removeAll()
                try store.clear()
                self.stamps.removeAll()
                self.unfinished.removeAll()
                DispatchQueue.main.async { self.importing = false; self.importStatus = "本应用历史已清除，来源会话与待处理事项保留。" }
                self.publish(store, force: true)
            } catch {
                DispatchQueue.main.async { self.issue = error.localizedDescription }
            }
        }
    }

    private func publish(_ store: HistoryStore, force: Bool) {
        guard force || store.changeCount != lastChanges else { return }
        do {
            let result = try store.records(filter: filter)
            let dimensions = try store.dimensions()
            let session = try trackedSessionID.map { try store.records(limit: 500, taskID: $0) }
            let sessionID = trackedSessionID
            lastChanges = store.changeCount
            let enabledAt = store.enabledAt
            DispatchQueue.main.async {
                self.runs = result.runs
                self.truncated = result.truncated
                self.sources = Array(Set(dimensions.map(\.source))).sorted()
                self.projects = Array(Set(dimensions.map(\.project).filter { !$0.isEmpty })).sorted()
                self.enabledAt = enabledAt
                if let session {
                    self.sessionTaskID = sessionID
                    self.sessionRuns = session.runs
                    self.sessionTruncated = session.truncated
                }
                self.loading = false
            }
        } catch {
            DispatchQueue.main.async { self.loading = false; self.issue = error.localizedDescription }
        }
    }
}
