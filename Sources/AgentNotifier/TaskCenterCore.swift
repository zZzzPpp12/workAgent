import Foundation
import AppKit
import SwiftUI
import UserNotifications
import CryptoKit

func stableKey(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

enum TaskPhase: String, Codable, CaseIterable {
    case unknown, idle, running, approval, input, suspected, stalled, completed, failed, stopped
    var label: String {
        switch self {
        case .unknown: return "状态待核实"
        case .idle: return "空闲"
        case .running: return "执行中"
        case .approval: return "待审批"
        case .input: return "待回答"
        case .suspected: return "疑似待确认"
        case .stalled: return "疑似停滞"
        case .completed: return "本轮已结束"
        case .failed: return "执行失败"
        case .stopped: return "已停止"
        }
    }
    var symbol: String {
        switch self {
        case .running: return "circle.dotted"
        case .approval: return "hand.raised.fill"
        case .input: return "text.bubble.fill"
        case .failed: return "exclamationmark.octagon.fill"
        case .completed: return "checkmark.circle.fill"
        case .stopped: return "stop.circle"
        case .suspected, .stalled: return "questionmark.circle"
        case .unknown, .idle: return "circle.dashed"
        }
    }
    var color: Color {
        switch self {
        case .running: return .green
        case .approval, .input: return .orange
        case .failed: return .red
        case .completed: return .blue
        case .suspected, .stalled: return .purple
        default: return .secondary
        }
    }
    var terminal: Bool { [.completed, .failed, .stopped].contains(self) }
    var actionable: Bool { [.approval, .input, .failed].contains(self) }
    var inferred: Bool { [.suspected, .stalled].contains(self) }
    var attention: Bool { actionable || inferred || self == .completed }
    var priority: Int {
        switch self {
        case .approval, .input: return 0
        case .failed: return 1
        case .suspected, .stalled: return 2
        case .completed: return 3
        default: return 4
        }
    }
}

struct MonitorSettings: Codable, Equatable {
    var sourcePaths: [String: String] = [:]
    var disabledSources: Set<String> = []
    var mutedSources: Set<String> = []
    var notifyWaiting = true
    var notifyFailure = true
    var notifyCompleted = true
    var notifyInferred = false
    var sound = true
    var revealTitles = false
    var muteUntil: Date?
    var quietEnabled = false
    var quietStart = 22 * 60
    var quietEnd = 9 * 60
    var creditEnabled = true
    var titlesEnabled = true
    var updatesEnabled = true
    var chromeImport = false
    var telemetry = false
    var hoverMenu = false
    var retentionDays = 30

    func isQuiet(at now: Date, calendar: Calendar = .current) -> Bool {
        if let until = muteUntil, until > now { return true }
        guard quietEnabled else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: now)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if quietStart == quietEnd { return true }
        return quietStart < quietEnd
            ? minute >= quietStart && minute < quietEnd
            : minute >= quietStart || minute < quietEnd
    }

    func permits(_ phase: TaskPhase, source: String, now: Date) -> Bool {
        guard !disabledSources.contains(source), !mutedSources.contains(source), !isQuiet(at: now) else { return false }
        switch phase {
        case .approval, .input: return notifyWaiting
        case .failed: return notifyFailure
        case .completed: return notifyCompleted
        case .suspected, .stalled: return notifyInferred
        default: return false
        }
    }
}

final class MonitorPreferences: ObservableObject {
    static let shared = MonitorPreferences()
    @Published var value: MonitorSettings { didSet { persist() } }
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var saved = MonitorSettings()
    var snapshot: MonitorSettings { lock.lock(); defer { lock.unlock() }; return saved }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        value = defaults.data(forKey: "r1.settings").flatMap { try? JSONDecoder().decode(MonitorSettings.self, from: $0) } ?? MonitorSettings()
        saved = value
    }
    private func persist() {
        lock.lock(); saved = value; lock.unlock()
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "r1.settings") }
    }
    func enabled(_ source: String) -> Bool { !snapshot.disabledSources.contains(source) }
}

struct TaskObservation: Equatable {
    var id: String
    var source: String
    var path: String
    var title: String
    var project: String
    var phase: TaskPhase
    var runID: String?
    var activity: Date
    var evidence: String
    var readable = true
    var precise = true
    var interactionID: String?
    var identityIsFallback = false
    var workflow: WorkflowSnapshot?
}

struct TaskRecord: Codable, Identifiable, Equatable {
    var id: String
    var source: String
    var path: String
    var title: String
    var project: String
    var phase: TaskPhase
    var runID: String
    var activity: Date
    var observedAt: Date
    var changedAt: Date
    var evidence: String
    var readable: Bool
    var precise: Bool
    var requestKey: String?
    var runIDInferred: Bool?
    var identityIsFallback: Bool?
    var workflow: WorkflowSnapshot?

    /// 存储键带来源命名空间；对外复制时使用来源自身的会话标识。
    var sessionID: String {
        let prefix = source + ":"
        return id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id
    }
}

struct SnoozeInterval: Codable, Equatable {
    var startedAt: Date
    var scheduledUntil: Date
    var endedAt: Date?
    var invalidClock: Bool = false
}

struct AttentionRecord: Codable, Identifiable, Equatable {
    var id: String
    var taskID: String
    var runID: String
    var phase: TaskPhase
    var createdAt: Date
    var seenAt: Date?
    var snoozedUntil: Date?
    var resolvedAt: Date?
    var resolution: String?
    var notifiedAt: Date?
    var deliveryAfter: Date
    var recovered = false
    var evidence: String?
    var requestKey: String?
    /// 与处理项一起原子保存；旧记录为空时，不能推断过去没有延后。
    var snoozeHistory: [SnoozeInterval]? = nil
    var snoozeHistoryComplete: Bool? = nil
    func visible(at now: Date) -> Bool { resolvedAt == nil && (snoozedUntil == nil || snoozedUntil! <= now) }

    mutating func closeSnooze(at now: Date) {
        guard var intervals = snoozeHistory, let index = intervals.lastIndex(where: { $0.endedAt == nil && !$0.invalidClock }) else { return }
        if now < intervals[index].startedAt {
            intervals[index].invalidClock = true
            snoozeHistoryComplete = false
        } else {
            intervals[index].endedAt = min(now, intervals[index].scheduledUntil)
        }
        snoozeHistory = intervals
    }

    mutating func beginSnooze(at now: Date, until: Date) {
        closeSnooze(at: now)
        if snoozeHistory == nil { snoozeHistory = []; snoozeHistoryComplete = false }
        snoozeHistory?.append(SnoozeInterval(startedAt: now, scheduledUntil: until))
        snoozedUntil = until
        seenAt = now
    }
}

struct SourceStatus: Identifiable, Equatable {
    var id: String
    var root: String
    var status: String
    var detail: String
    var checkedAt: Date
    var lastSignal: Date?
    var count: Int
    var healthy: Bool
}

struct CenterDocument: Codable {
    var version = 2
    var tasks: [TaskRecord] = []
    var attentions: [AttentionRecord] = []
}

/// Durable queue: a view acknowledgement never mutates the source lifecycle.
final class TaskCenterStore: ObservableObject {
    @Published private(set) var tasks: [TaskRecord] = []
    @Published private(set) var attentions: [AttentionRecord] = []
    @Published var sources: [SourceStatus] = []
    @Published var storageIssue: String?
    @Published var navigationMessage: String?
    @Published var selectedTaskID: String?
    @Published var requestedTaskID: String?
    @Published var requestedAttentionID: String?
    @Published var lastScan: Date?
    @Published var scanMilliseconds: Double = 0
    @Published var permission: String = "尚未检查"
    @Published var sourceProblems: [String: String] = [:]
    let startedAt: Date
    private let stateURL: URL?
    private let io = DispatchQueue(label: "AgentNotifier.state", qos: .utility)
    private var readOnly = false
    private var lastEncoded: Data?
    private var initialized = false
    private var notificationBaseline: Date
    var deliver: ((String, String, Bool, [String: String]) -> Void)?
    var now: Date { Date() }

    static var dataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentNotifier")
    }

    init(stateURL: URL? = TaskCenterStore.dataDirectory.appendingPathComponent("task-center-v1.json"), now: Date = Date()) {
        self.stateURL = stateURL
        self.startedAt = now
        self.notificationBaseline = now
        guard let url = stateURL, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let doc = try JSONDecoder().decode(CenterDocument.self, from: data)
            guard (1...2).contains(doc.version) else {
                readOnly = true
                storageIssue = "记录来自更新的数据版本，已停止覆盖；请使用匹配版本打开。"
                return
            }
            tasks = doc.tasks
            attentions = doc.attentions
            lastEncoded = data
        } catch {
            let backup = url.appendingPathExtension("previous")
            if let data = try? Data(contentsOf: backup), let doc = try? JSONDecoder().decode(CenterDocument.self, from: data), (1...2).contains(doc.version) {
                tasks = doc.tasks
                attentions = doc.attentions
                do {
                    try FileManager.default.copyItem(at: url, to: url.appendingPathExtension("unreadable-\(Int(now.timeIntervalSince1970))"))
                    storageIssue = "已从有效备份恢复；原文件已另存为 unreadable 副本。"
                } catch {
                    readOnly = true
                    storageIssue = "已读出备份，但无法保存原文件副本；为保护原数据，暂停覆盖。"
                }
            } else {
                readOnly = true
                storageIssue = "处理记录无法读取，已保留原文件并停止覆盖。当前可继续监测；请备份数据后检查存储。"
            }
        }
    }

    func reconcile(_ observations: [TaskObservation], settings: MonitorSettings, at now: Date) {
        var records = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        var items = attentions
        for observation in observations where !settings.disabledSources.contains(observation.source) {
            // Upgrade a path fallback to a discovered stable source ID without duplicating tasks.
            if !observation.identityIsFallback, records[observation.id] == nil, let alias = records.values.first(where: {
                $0.path == observation.path && $0.source == observation.source && ($0.identityIsFallback == true || $0.id.hasPrefix("Codex:rollout-"))
            }) {
                records.removeValue(forKey: alias.id)
                var migrated = alias
                migrated.id = observation.id
                records[observation.id] = migrated
                for index in items.indices where items[index].taskID == alias.id { items[index].taskID = observation.id }
            }
            let old = records[observation.id]
            var phase = observation.phase
            let fresh = observation.activity >= startedAt.addingTimeInterval(-3)
            // Historical unresolved logs cannot prove a still-live request.
            if [.approval, .input].contains(phase) && now.timeIntervalSince(observation.activity) > Config.tabTurnEvalWindow {
                phase = .unknown
            }
            if !observation.readable { phase = .unknown }
            var run = observation.runID ?? old?.runID ?? stableKey(observation.id + ":baseline")
            if observation.runID == nil, let old, old.phase.terminal, phase == .running, observation.activity > old.activity {
                run = stableKey(observation.id + ":" + String(observation.activity.timeIntervalSince1970))
            }
            let changed = old?.phase != phase || old?.runID != run
            let record = TaskRecord(id: observation.id, source: observation.source, path: observation.path,
                title: observation.title, project: observation.project, phase: phase, runID: run,
                activity: observation.activity, observedAt: changed || old?.activity != observation.activity ? now : old!.observedAt, changedAt: changed ? now : old!.changedAt,
                evidence: observation.evidence, readable: observation.readable, precise: observation.precise, requestKey: observation.interactionID,
                runIDInferred: observation.runID == nil, identityIsFallback: observation.identityIsFallback,
                workflow: observation.workflow ?? (old?.runID == run ? old?.workflow : nil))
            records[record.id] = record
            let id = stableKey(record.id + ":" + run + ":" + phase.rawValue + ":" + (observation.interactionID ?? "state"))

            for index in items.indices where items[index].taskID == record.id && items[index].resolvedAt == nil {
                let item = items[index]
                let newRun = item.runID != run
                let recovered = (item.phase.actionable || item.phase.inferred) && phase != .unknown && phase != item.phase
                let newRequest = observation.interactionID != nil && item.phase == phase && item.requestKey != observation.interactionID
                if (newRun && item.phase != .completed) || recovered || newRequest {
                    items[index].resolvedAt = now
                    items[index].resolution = newRun ? "新回合已开始" : "来源状态已恢复或终止"
                    items[index].closeSnooze(at: now)
                    items[index].snoozedUntil = nil
                }
            }

            guard phase.attention, record.precise || phase.inferred, observation.readable else { continue }
            if !items.contains(where: { $0.id == id || ($0.taskID == record.id && $0.runID == run && $0.phase == phase && $0.requestKey == observation.interactionID) }) {
                // Already-finished history does not become a new unread queue on first launch.
                guard phase != .completed || (initialized && fresh && changed) else { continue }
                if phase == .failed && !fresh { continue }
                if phase.inferred && !fresh { continue }
                let restored = !initialized || observation.activity < notificationBaseline.addingTimeInterval(-3)
                let batchDeadline = items.filter { $0.phase == .completed && $0.notifiedAt == nil && $0.resolvedAt == nil }.map(\.deliveryAfter).min()
                items.append(AttentionRecord(id: id, taskID: record.id, runID: run, phase: phase,
                    createdAt: restored ? observation.activity : now,
                    notifiedAt: restored ? now : nil,
                    deliveryAfter: phase == .completed ? max(now, batchDeadline ?? now.addingTimeInterval(10)) : now, recovered: restored,
                    evidence: observation.evidence, requestKey: observation.interactionID,
                    snoozeHistory: [], snoozeHistoryComplete: !restored))
            }
        }
        // A disappeared file is not proof that an outstanding request was answered.
        let observed = Set(observations.map(\.id))
        for (id, record) in records where !observed.contains(id) && !settings.disabledSources.contains(record.source) {
            if !record.phase.terminal && record.phase != .idle {
                records[id]?.phase = .unknown
                records[id]?.readable = false
                records[id]?.evidence = "本次未能读取来源，保留最后记录；不推断任务结束。"
            }
        }
        let cutoff = now.addingTimeInterval(-Double(settings.retentionDays) * 86400)
        items.removeAll { $0.resolvedAt != nil && $0.resolvedAt! < cutoff }
        let retained = Set(items.filter { $0.resolvedAt == nil }.map(\.taskID))
        records = records.filter { $0.value.activity >= cutoff || retained.contains($0.key) || $0.value.phase == .running }
        tasks = records.values.sorted { $0.activity > $1.activity }
        attentions = items
        initialized = true
        lastScan = now
        flushNotifications(settings: settings, at: now)
        persist()
    }

    func visibleItems(at now: Date = Date()) -> [AttentionRecord] {
        attentions.filter { item in
            guard item.visible(at: now), let task = task(item.taskID), task.readable else { return false }
            return task.phase != .unknown && MonitorPreferences.shared.enabled(task.source)
        }.sorted { a, b in
            if a.phase.priority != b.phase.priority { return a.phase.priority < b.phase.priority }
            return a.createdAt < b.createdAt
        }
    }
    func task(_ id: String) -> TaskRecord? { tasks.first { $0.id == id } }
    var actionableCount: Int { Set(visibleItems().filter { $0.phase.actionable }.map(\.taskID)).count }
    var reviewCount: Int { visibleItems().filter { $0.phase == .completed }.count }
    var runningCount: Int { tasks.filter { $0.phase == .running && $0.precise && $0.readable && MonitorPreferences.shared.enabled($0.source) }.count }
    func item(for taskID: String) -> AttentionRecord? { visibleItems().first { $0.taskID == taskID } }

    func see(_ taskID: String, attentionID: String? = nil, at now: Date = Date()) {
        for index in attentions.indices where attentions[index].taskID == taskID && attentions[index].resolvedAt == nil {
            if let attentionID { guard attentions[index].id == attentionID else { continue } }
            else { guard attentions[index].runID == task(taskID)?.runID else { continue } }
            attentions[index].seenAt = now
            if attentions[index].phase == .completed {
                attentions[index].resolvedAt = now
                attentions[index].resolution = "已查看该回合"
                attentions[index].closeSnooze(at: now)
                attentions[index].snoozedUntil = nil
            }
        }
        persist()
    }
    func handleFailure(_ id: String, at now: Date = Date()) {
        guard let index = attentions.firstIndex(where: { $0.id == id }), attentions[index].phase == .failed else { return }
        attentions[index].resolvedAt = now
        attentions[index].resolution = "用户已处理；原回合仍为失败"
        attentions[index].closeSnooze(at: now)
        attentions[index].snoozedUntil = nil
        persist()
    }
    func recordReturn(_ taskID: String, attentionID: String? = nil, at now: Date = Date()) {
        for index in attentions.indices where attentions[index].taskID == taskID && attentions[index].resolvedAt == nil {
            if let attentionID { guard attentions[index].id == attentionID else { continue } }
            else { guard attentions[index].runID == task(taskID)?.runID else { continue } }
            attentions[index].seenAt = now
        }
        persist()
    }
    func snooze(_ id: String, minutes: Int, at now: Date = Date()) {
        guard let index = attentions.firstIndex(where: { $0.id == id }), attentions[index].resolvedAt == nil else { return }
        attentions[index].beginSnooze(at: now, until: now.addingTimeInterval(Double(minutes) * 60))
        persist()
    }
    func unsnooze(_ id: String, at now: Date = Date()) {
        guard let index = attentions.firstIndex(where: { $0.id == id }) else { return }
        attentions[index].closeSnooze(at: now)
        attentions[index].snoozedUntil = nil
        persist()
    }
    func snoozeUntil(_ id: String, until: Date, at now: Date = Date()) {
        guard until > now, let index = attentions.firstIndex(where: { $0.id == id }), attentions[index].resolvedAt == nil else { return }
        attentions[index].beginSnooze(at: now, until: until)
        persist()
    }

    func flushNotifications(settings: MonitorSettings, at now: Date) {
        var due: [AttentionRecord] = []
        for index in attentions.indices where attentions[index].resolvedAt == nil {
            if let until = attentions[index].snoozedUntil, until <= now {
                attentions[index].closeSnooze(at: until)
                attentions[index].snoozedUntil = nil
                attentions[index].notifiedAt = nil
                attentions[index].deliveryAfter = now
            }
            let item = attentions[index]
            guard item.notifiedAt == nil, item.visible(at: now), item.deliveryAfter <= now,
                  let task = task(item.taskID), task.readable, task.phase != .unknown else { continue }
            // Muted/disabled events are consumed, never replayed as a notification storm.
            attentions[index].notifiedAt = now
            guard settings.permits(item.phase, source: task.source, now: now) else { continue }
            if NSApp != nil && NSApp.isActive && selectedTaskID == task.id { continue }
            due.append(item)
        }
        let completions = due.filter { $0.phase == .completed }
        if completions.count > 1 {
            deliver?("\(completions.count) 个回合已结束 ✅", "结果已加入待查看队列", settings.sound, ["event": "completed-group"])
        }
        for item in due where item.phase != .completed || completions.count == 1 {
            guard let task = task(item.taskID) else { continue }
            let title = item.phase == .completed ? "本轮已结束 ✅" : item.phase == .failed ? "任务执行失败 ⛔️" : item.phase.inferred ? "任务状态需要核实 ⚠️" : "任务\(item.phase.label) 🟡"
            let body = settings.revealTitles ? "\(task.source) · \(task.title)" : "打开任务中心查看详情"
            deliver?(title, body, settings.sound && !item.phase.inferred,
                     ["attentionID": item.id, "taskID": task.id, "kind": task.source, "path": task.path, "event": item.phase.rawValue])
        }
    }

    func persist() {
        guard !readOnly, let url = stateURL else { return }
        let doc = CenterDocument(tasks: tasks, attentions: attentions)
        guard let data = try? JSONEncoder().encode(doc), data != lastEncoded else { return }
        guard data.count <= 200_000_000 else {
            storageIssue = "记录达到 200 MB 上限，已暂停覆盖；请备份后调整保留时长。"
            return
        }
        lastEncoded = data
        io.async { [weak self] in
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let prior = try? Data(contentsOf: url), let old = try? JSONDecoder().decode(CenterDocument.self, from: prior), (1...2).contains(old.version) {
                    if old.version == 1 {
                        let migrationBackup = url.appendingPathExtension("before-history-v1")
                        if !fm.fileExists(atPath: migrationBackup.path) {
                            try fm.copyItem(at: url, to: migrationBackup)
                        }
                    }
                    try prior.write(to: url.appendingPathExtension("previous"), options: .atomic)
                }
                try data.write(to: url, options: .atomic)
            } catch {
                DispatchQueue.main.async { self?.storageIssue = "处理记录保存失败：\(error.localizedDescription)；当前状态仍可查看。" }
            }
        }
    }
    func flushPersistence() { io.sync {} }
    func resume(at now: Date = Date()) {
        notificationBaseline = now
        for index in attentions.indices where attentions[index].notifiedAt == nil && attentions[index].createdAt < now {
            attentions[index].notifiedAt = now
        }
        persist()
    }

    func inspectPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let label: String
            switch settings.authorizationStatus {
            case .authorized, .provisional: label = "已允许"
            case .denied: label = "已拒绝 · 应用内队列仍可使用"
            default: label = "尚未授权 · 可在设置中开启"
            }
            DispatchQueue.main.async { self?.permission = label }
        }
    }

    func probeSources(settings: MonitorSettings, at now: Date) {
        let roots: [(String, URL, String)] = [
            ("IDE-CatPaw", Config.projectsDir, "transcript + 界面状态库 · 项目级返回"),
            ("CatDesk", Config.projectsDir, "会话与流日志 · 会话链接直达"),
            ("Codex", Config.codexSessionsDir, "结构化事件 · 会话链接直达 · Hook 尚未启用"),
            ("Claude", Config.claudeProjectsDir, "回合日志 · 项目级返回 · Hook 尚未启用"),
            ("Trae", Config.traeAppDirs[0].root, "仅工作区活动，不提供回合通知"),
            ("DeepSeek", Config.dshSessionsDir, "当前构建未启用 ZSTD 解码")
        ]
        let fm = FileManager.default
        sources = roots.map { name, root, capability in
            let sourceTasks = tasks.filter { $0.source == name }
            let exists = fm.fileExists(atPath: root.path)
            let enabled = !settings.disabledSources.contains(name)
            let readable = exists && fm.isReadableFile(atPath: root.path)
            var status = !enabled ? "已停用" : !exists ? "未发现数据" : !readable ? "读取受限" : "正常"
            var detail = capability
            if name == "Trae" && enabled && exists { status = "能力受限" }
            if name == "DeepSeek" && enabled { status = "待启用" }
            if let problem = sourceProblems[name], enabled { status = "监测降级"; detail = problem }
            return SourceStatus(id: name, root: root.path, status: status, detail: detail, checkedAt: now,
                lastSignal: sourceTasks.map(\.activity).max(), count: sourceTasks.count,
                healthy: enabled && readable && name != "DeepSeek" && name != "Trae" && sourceProblems[name] == nil)
        }
    }
}
