import Foundation
import SQLite3

/// 历史仅保存工作流元数据；绝不保存源文件中的对话、命令参数或工具输出。
struct HistoricalRun: Codable, Identifiable, Equatable {
    var id: String
    var taskID: String
    var source: String
    var project: String
    var title: String
    var snapshot: WorkflowSnapshot
    var observedAt: Date
    var imported: Bool

    var status: TaskPhase {
        guard let end = snapshot.steps.last(where: { $0.kind == .end }) else { return .running }
        guard snapshot.hasExplicitStart,
              !snapshot.steps.contains(where: { $0.kind == .interaction && $0.status == .unconfirmed }) else { return .unknown }
        switch end.status {
        case .returned: return .completed
        case .failed: return .failed
        case .interrupted: return .stopped
        default: return .unknown
        }
    }
}

private struct HistoryCursor: Codable {
    var identity: String
    var offset: UInt64
    var runStartOffset: UInt64
    var currentID: String?
    var taskID: String? = nil
    var discardingLongLine = false
    var cleared = false
    var flow = WorkflowBuilder(partial: true)
}

private enum HistorySQLValue {
    case text(String), number(Double), integer(Int64), null
}

enum HistoryStoreError: LocalizedError {
    case database(String)
    case newerVersion
    case storageFull
    var errorDescription: String? {
        switch self {
        case .database(let message): return "历史记录不可用：\(message)"
        case .newerVersion: return "历史记录来自更新的版本，已停止写入。"
        case .storageFull: return "历史记录已达到容量上限，已暂停采集。"
        }
    }
}

/// 所有方法由调用方的串行队列使用。每批步骤与文件检查点处于同一事务。
final class HistoryStore {
    private var db: OpaquePointer?
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private(set) var enabledAt: Date
    static let maximumBytes: UInt64 = 200_000_000
    static let batchBytes = 262_144

    init(url: URL, now: Date = Date()) throws {
        self.url = url
        self.enabledAt = now
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            if let db { sqlite3_close(db) }
            db = nil
            throw HistoryStoreError.database(message)
        }
        do {
            sqlite3_busy_timeout(db, 1000)
            let version = try scalar("PRAGMA user_version") ?? 0
            guard version <= 1 else { throw HistoryStoreError.newerVersion }
            try execute("PRAGMA journal_mode=DELETE")
            try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS cursors (file_key TEXT NOT NULL, mode TEXT NOT NULL, state TEXT NOT NULL, PRIMARY KEY(file_key, mode))")
            try execute("CREATE TABLE IF NOT EXISTS runs (id TEXT PRIMARY KEY, task_id TEXT NOT NULL, source TEXT NOT NULL, project TEXT NOT NULL, started REAL, ended REAL, observed REAL NOT NULL, file_key TEXT NOT NULL, first_offset INTEGER NOT NULL, last_offset INTEGER NOT NULL, partial INTEGER NOT NULL, record TEXT NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS runs_task ON runs(task_id, observed DESC)")
            try execute("CREATE INDEX IF NOT EXISTS runs_time ON runs(ended, source, project)")
            try execute("PRAGMA user_version=1")
            if let stored = try string("SELECT value FROM metadata WHERE key='enabled_at'"), let seconds = Double(stored) {
                enabledAt = Date(timeIntervalSince1970: seconds)
            } else {
                try execute("INSERT INTO metadata(key,value) VALUES('enabled_at',?)", [.text(String(now.timeIntervalSince1970))])
            }
        } catch {
            if let db { sqlite3_close(db) }
            db = nil
            throw error
        }
    }

    deinit { if let db { sqlite3_close(db) } }

    private func prepare(_ sql: String, _ values: [HistorySQLValue] = []) throws -> OpaquePointer {
        guard let db else { throw HistoryStoreError.database("数据库未打开") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw HistoryStoreError.database(String(cString: sqlite3_errmsg(db)))
        }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let code: Int32
            switch value {
            case .text(let text): code = sqlite3_bind_text(statement, position, text, -1, transient)
            case .number(let number): code = sqlite3_bind_double(statement, position, number)
            case .integer(let number): code = sqlite3_bind_int64(statement, position, number)
            case .null: code = sqlite3_bind_null(statement, position)
            }
            if code != SQLITE_OK { sqlite3_finalize(statement); throw HistoryStoreError.database(String(cString: sqlite3_errmsg(db))) }
        }
        return statement
    }

    private func execute(_ sql: String, _ values: [HistorySQLValue] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw HistoryStoreError.database(db.map { String(cString: sqlite3_errmsg($0)) } ?? "写入失败")
        }
    }

    private func string(_ sql: String, _ values: [HistorySQLValue] = []) throws -> String? {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            if result == SQLITE_DONE { return nil }
            throw HistoryStoreError.database(db.map { String(cString: sqlite3_errmsg($0)) } ?? "读取失败")
        }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }

    private func scalar(_ sql: String) throws -> Int64? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : nil
    }

    private func encoded<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func decoded<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        try decoder.decode(type, from: Data(text.utf8))
    }

    private func cursor(fileKey: String, mode: String) throws -> HistoryCursor? {
        guard let text = try string("SELECT state FROM cursors WHERE file_key=? AND mode=?", [.text(fileKey), .text(mode)]) else { return nil }
        return try decoded(HistoryCursor.self, text)
    }

    private func save(_ cursor: HistoryCursor, fileKey: String, mode: String) throws {
        try execute("INSERT INTO cursors(file_key,mode,state) VALUES(?,?,?) ON CONFLICT(file_key,mode) DO UPDATE SET state=excluded.state",
                    [.text(fileKey), .text(mode), .text(try encoded(cursor))])
    }

    /// 对已发现的结构化日志进行增量采集；历史回填使用独立游标，不倒退实时检查点。
    @discardableResult
    func collect(_ observation: TaskObservation, backfill: Bool = false, now: Date = Date()) throws -> Bool {
        guard ["Codex", "Claude", "CatDesk"].contains(observation.source), observation.readable else { return true }
        let fileURL = URL(fileURLWithPath: observation.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let device = (attributes[.systemNumber] as? NSNumber)?.stringValue ?? "?"
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? "?"
        let identity = device + ":" + inode
        let key = stableKey(observation.source + ":" + observation.path)
        let mode = backfill ? "import" : "live"
        let pages = UInt64(max(0, try scalar("PRAGMA page_count") ?? 0))
        let freePages = UInt64(max(0, try scalar("PRAGMA freelist_count") ?? 0))
        let pageSize = UInt64(max(0, try scalar("PRAGMA page_size") ?? 0))
        let databaseBytes = (pages - min(pages, freePages)) * pageSize
        let journalBytes = (try? FileManager.default.attributesOfItem(atPath: url.path + "-journal")[.size] as? NSNumber)?.uint64Value ?? 0
        guard databaseBytes + journalBytes < Self.maximumBytes else { throw HistoryStoreError.storageFull }
        var state = try cursor(fileKey: key, mode: mode)
        var cursorNeedsSave = state == nil
        if state == nil {
            let created = attributes[.creationDate] as? Date
            let start: UInt64 = backfill || (created.map { $0 >= enabledAt } ?? false) ? 0 : size
            state = HistoryCursor(identity: identity, offset: start, runStartOffset: start)
        }
        guard var current = state else { return true }
        if current.taskID != observation.id {
            try updateTaskIdentity(fileKey: key, observation: observation)
            current.taskID = observation.id
            try save(current, fileKey: key, mode: mode)
            cursorNeedsSave = false
        }
        if current.identity != identity || current.offset > size {
            // 文件重建或截断无法证明旧内容是否重复；重建片段不冒充完整回合。
            let start = !backfill && current.cleared ? size : 0
            current = HistoryCursor(identity: identity, offset: start, runStartOffset: start)
            current.cleared = start > 0
            current.taskID = observation.id
            cursorNeedsSave = true
        }
        guard current.offset < size else {
            if cursorNeedsSave { try save(current, fileKey: key, mode: mode) }
            return true
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: current.offset)
        let bytes = try handle.read(upToCount: Self.batchBytes) ?? Data()
        guard !bytes.isEmpty else { return true }
        let isFullBatch = bytes.count == Self.batchBytes
        let consumed: Int
        if let newline = bytes.lastIndex(of: 10) {
            consumed = bytes.distance(from: bytes.startIndex, to: newline) + 1
        } else if isFullBatch {
            // 超长单行不能无限占用内存；跳过并保留缺口标记。
            consumed = bytes.count
            current.discardingLongLine = true
            current.flow.partial = true
        } else {
            // 末行尚未写完整，下次从相同位置重读。
            return true
        }
        let initialOffset = current.offset
        let content = bytes.prefix(consumed)
        try execute("BEGIN IMMEDIATE")
        do {
            var position = initialOffset
            for part in content.split(separator: 10, omittingEmptySubsequences: false).dropLast() {
                let offset = position
                position += UInt64(part.count + 1)
                if current.discardingLongLine {
                    current.discardingLongLine = false
                    current.flow.partial = true
                    continue
                }
                if part.isEmpty { continue }
                guard let object = (try? JSONSerialization.jsonObject(with: Data(part))) as? [String: Any] else {
                    current.flow.partial = true
                    continue
                }
                let date = eventDate(object["timestamp"])
                let stable = object["uuid"] as? String ?? object["messageId"] as? String
                    ?? object["ordinal"].map { String(describing: $0) } ?? stableKey(key + ":\(offset)")
                let payload = object["payload"] as? [String: Any] ?? object
                if observation.source == "Codex", let turn = payload["turn_id"] as? String,
                   let active = current.flow.runID, turn != active,
                   payload["type"] as? String != "task_started", object["type"] as? String != "turn_context" {
                    let lateID = stableKey(key + ":" + turn)
                    let saved = try string("SELECT record FROM runs WHERE id=?", [.text(lateID)])
                        .flatMap { try? decoded(HistoricalRun.self, $0) }
                    var late = WorkflowBuilder(runID: turn, steps: saved?.snapshot.steps ?? [],
                                               hasExplicitStart: saved?.snapshot.hasExplicitStart ?? false,
                                               partial: saved?.snapshot.isPartial ?? true)
                    WorkflowParser.advance(object, source: observation.source, id: stable, at: date, flow: &late)
                    late.plan = []
                    if !late.steps.isEmpty {
                        let first = try string("SELECT CAST(first_offset AS TEXT) FROM runs WHERE id=?", [.text(lateID)]).flatMap(UInt64.init) ?? offset
                        try saveRun(late, id: lateID, observation: observation, fileKey: key,
                                    first: first, last: position, imported: backfill, now: now, replaceFragments: false)
                    }
                    continue
                }
                let old = current.flow
                let oldID = current.currentID
                WorkflowParser.advance(object, source: observation.source, id: stable, at: date, flow: &current.flow)
                // 历史不保存模型显式计划文本，避免将潜在敏感内容写入新库。
                current.flow.plan = []
                if old.runID != current.flow.runID {
                    if let oldID, !old.steps.isEmpty {
                        try saveRun(old, id: oldID, observation: observation, fileKey: key,
                                    first: current.runStartOffset, last: offset, imported: backfill, now: now)
                    }
                    current.runStartOffset = offset
                    current.currentID = nil
                }
                if current.currentID == nil && !current.flow.steps.isEmpty {
                    let identity = current.flow.runID ?? "fragment:\(current.runStartOffset)"
                    current.currentID = stableKey(key + ":" + identity)
                }
                if current.flow.steps.count > 192 {
                    let start = current.flow.steps.first { $0.kind == .start }
                    let pending = current.flow.steps.filter { $0.status.pending }.suffix(16)
                    let tail = current.flow.steps.suffix(80)
                    var seen = Set<String>()
                    current.flow.steps = ([start].compactMap { $0 } + pending + tail).filter { seen.insert($0.id).inserted }
                    current.flow.partial = true
                }
            }
            current.offset += UInt64(consumed)
            if let id = current.currentID, !current.flow.steps.isEmpty {
                try saveRun(current.flow, id: id, observation: observation, fileKey: key,
                            first: current.runStartOffset, last: current.offset, imported: backfill, now: now)
            }
            try save(current, fileKey: key, mode: mode)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        return current.offset >= size
    }

    private func updateTaskIdentity(fileKey: String, observation: TaskObservation) throws {
        let statement = try prepare("SELECT record FROM runs WHERE file_key=? AND task_id<>?", [.text(fileKey), .text(observation.id)])
        var changed: [HistoricalRun] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0),
                  var run = try? decoded(HistoricalRun.self, String(cString: text)) else { continue }
            run.taskID = observation.id
            changed.append(run)
        }
        sqlite3_finalize(statement)
        for run in changed {
            try execute("UPDATE runs SET task_id=?,record=? WHERE id=?", [.text(run.taskID), .text(try encoded(run)), .text(run.id)])
        }
    }

    private func saveRun(_ flow: WorkflowBuilder, id: String, observation: TaskObservation, fileKey: String,
                         first: UInt64, last: UInt64, imported: Bool, now: Date, replaceFragments: Bool = true) throws {
        let snapshot = flow.snapshot()
        let record = HistoricalRun(id: id, taskID: observation.id, source: observation.source,
                                   project: observation.project, title: observation.title, snapshot: snapshot,
                                   observedAt: now, imported: imported)
        let started: HistorySQLValue = snapshot.startedAt.map { .number($0.timeIntervalSince1970) } ?? .null
        let ended: HistorySQLValue = snapshot.endedAt.map { .number($0.timeIntervalSince1970) } ?? .null
        try execute("""
            INSERT INTO runs(id,task_id,source,project,started,ended,observed,file_key,first_offset,last_offset,partial,record)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET task_id=excluded.task_id, source=excluded.source, project=excluded.project,
              started=excluded.started, ended=excluded.ended, observed=excluded.observed, first_offset=MIN(first_offset,excluded.first_offset),
              last_offset=excluded.last_offset, partial=excluded.partial, record=excluded.record
            WHERE excluded.last_offset >= runs.last_offset
            """, [.text(id), .text(observation.id), .text(observation.source), .text(observation.project), started, ended,
                   .number(now.timeIntervalSince1970), .text(fileKey), .integer(Int64(first)), .integer(Int64(last)),
                   .integer(snapshot.hasExplicitStart ? 0 : 1), .text(try encoded(record))])
        if snapshot.hasExplicitStart && replaceFragments {
            // 手动回填追上实时片段时，只替换被该完整回合完全覆盖的片段。
            try execute("DELETE FROM runs WHERE file_key=? AND id<>? AND partial=1 AND first_offset>=? AND last_offset<=?",
                        [.text(fileKey), .text(id), .integer(Int64(first)), .integer(Int64(last))])
        }
    }

    func resetBackfill(for observations: [TaskObservation]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for observation in observations where ["Codex", "Claude", "CatDesk"].contains(observation.source) {
                let key = stableKey(observation.source + ":" + observation.path)
                try execute("DELETE FROM cursors WHERE file_key=? AND mode='import'", [.text(key)])
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func records(limit: Int = 5000, filter: HistoryFilter? = nil, taskID: String? = nil) throws -> (runs: [HistoricalRun], truncated: Bool) {
        var sql = "SELECT record FROM runs"
        var values: [HistorySQLValue] = []
        if let filter {
            sql += " WHERE COALESCE(started,ended,observed) < ? AND (ended IS NULL OR ended >= ?)"
            values += [.number(filter.interval.end.timeIntervalSince1970), .number(filter.interval.start.timeIntervalSince1970)]
            if let source = filter.source { sql += " AND source=?"; values.append(.text(source)) }
            if let project = filter.project { sql += " AND project=?"; values.append(.text(project)) }
        }
        if let taskID {
            sql += filter == nil ? " WHERE task_id=?" : " AND task_id=?"
            values.append(.text(taskID))
        }
        sql += " ORDER BY COALESCE(ended,started,observed) DESC LIMIT ?"
        values.append(.integer(Int64(limit + 1)))
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var result: [HistoricalRun] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw HistoryStoreError.database(db.map { String(cString: sqlite3_errmsg($0)) } ?? "读取失败") }
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            result.append(try decoded(HistoricalRun.self, String(cString: text)))
        }
        return (Array(result.prefix(limit)), result.count > limit)
    }

    var changeCount: Int { db.map { Int(sqlite3_total_changes($0)) } ?? 0 }

    func dimensions() throws -> [(source: String, project: String)] {
        let statement = try prepare("SELECT DISTINCT source,project FROM runs ORDER BY source,project")
        defer { sqlite3_finalize(statement) }
        var result: [(source: String, project: String)] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw HistoryStoreError.database("读取来源筛选失败") }
            guard let source = sqlite3_column_text(statement, 0), let project = sqlite3_column_text(statement, 1) else { continue }
            result.append((String(cString: source), String(cString: project)))
        }
        return result
    }

    /// 只清理超期记录；活跃任务与未解决事项的记录不在此处删除。
    func prune(before cutoff: Date, protecting taskIDs: Set<String>) throws {
        let statement = try prepare("SELECT id,task_id FROM runs WHERE COALESCE(ended,started,observed) < ? LIMIT 5000", [.number(cutoff.timeIntervalSince1970)])
        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0), let task = sqlite3_column_text(statement, 1),
                  !taskIDs.contains(String(cString: task)) else { continue }
            ids.append(String(cString: id))
        }
        sqlite3_finalize(statement)
        guard !ids.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            for id in ids { try execute("DELETE FROM runs WHERE id=?", [.text(id)]) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    /// 清空本应用的历史，不触碰来源会话或处理队列；保留实时字节水位。
    func clear(now: Date = Date()) throws {
        let statement = try prepare("SELECT file_key,state FROM cursors WHERE mode='live'")
        var cursors: [(String, HistoryCursor)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = sqlite3_column_text(statement, 0), let state = sqlite3_column_text(statement, 1) else { continue }
            var current = try decoded(HistoryCursor.self, String(cString: state))
            current.flow = WorkflowBuilder(partial: true)
            current.currentID = nil
            current.runStartOffset = current.offset
            current.cleared = true
            cursors.append((String(cString: key), current))
        }
        sqlite3_finalize(statement)
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM runs")
            try execute("DELETE FROM cursors WHERE mode='import'")
            for (key, current) in cursors { try save(current, fileKey: key, mode: "live") }
            try execute("UPDATE metadata SET value=? WHERE key='enabled_at'", [.text(String(now.timeIntervalSince1970))])
            try execute("COMMIT")
            enabledAt = now
        } catch { try? execute("ROLLBACK"); throw error }
    }
}
